import { WebSocket } from "ws";
import { hmacHex, newNonce, proofInput, safeEqualHex } from "./auth.js";
import {
	BridgeError,
	ChallengeMessage,
	HANDSHAKE_TIMEOUT_MS,
	MAX_MESSAGE_BYTES,
	PROTOCOL_VERSION,
	ReadyMessage,
	REQUEST_TIMEOUT_MS,
	ResponseMessage,
	type Role,
} from "./protocol.js";

/** Nothing is listening on the port. */
export class BrokerAbsentError extends Error {}

/** Something is listening on the port but did not prove it is our broker. */
export class ForeignListenerError extends Error {}

/** The listener is our broker and refused this client (wrong credential, version and so on). */
export class DeniedError extends Error {
	constructor(readonly code: string) {
		super(`Broker denied the connection: ${code}`);
	}
}

export interface HandshakeResult {
	ws: WebSocket;
	clientNonce: string;
	serverNonce: string;
	credential?: string;
}

export interface HandshakeOptions {
	port: number;
	role: Role;
	keyName: string;
	key: Buffer;
	timeoutMs?: number;
}

/**
 * Connects and runs the mutual handshake. The client sends only a hello before the
 * listener has proved it holds the key, so a foreign program never receives a request.
 */
export function handshake(options: HandshakeOptions): Promise<HandshakeResult> {
	const { port, role, keyName, key } = options;
	return new Promise<HandshakeResult>((resolve, reject) => {
		const ws = new WebSocket(`ws://127.0.0.1:${port}/v1`, { maxPayload: MAX_MESSAGE_BYTES });
		const clientNonce = newNonce();
		let serverNonce: string | undefined;
		let opened = false;
		let settled = false;

		const finish = (error: Error | undefined, credential?: string) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			ws.off("message", onMessage);
			if (error || serverNonce === undefined) {
				ws.terminate();
				reject(error ?? new ForeignListenerError("Handshake ended without a challenge."));
			} else {
				resolve({ ws, clientNonce, serverNonce, credential });
			}
		};

		const timer = setTimeout(
			() => finish(new ForeignListenerError(`No valid handshake from port ${port} in time.`)),
			options.timeoutMs ?? HANDSHAKE_TIMEOUT_MS,
		);

		const onMessage = (data: unknown) => {
			let message: unknown;
			try {
				message = JSON.parse(String(data));
			} catch {
				return finish(new ForeignListenerError("Listener sent something that is not JSON."));
			}
			const type = (message as { t?: unknown } | null)?.t;
			if (type === "denied") {
				return finish(new DeniedError(String((message as { code?: unknown }).code)));
			}
			if (serverNonce === undefined) {
				const challenge = ChallengeMessage.safeParse(message);
				if (!challenge.success) return finish(new ForeignListenerError("Listener sent no valid challenge."));
				const expected = hmacHex(key, proofInput("broker", role, clientNonce, challenge.data.nonce));
				if (!safeEqualHex(challenge.data.proof, expected)) {
					return finish(new ForeignListenerError("Listener failed to prove ownership."));
				}
				serverNonce = challenge.data.nonce;
				ws.send(JSON.stringify({ t: "auth", proof: hmacHex(key, proofInput("client", role, clientNonce, serverNonce)) }));
				return;
			}
			const ready = ReadyMessage.safeParse(message);
			if (!ready.success) return finish(new ForeignListenerError("Listener sent no valid ready message."));
			finish(undefined, ready.data.credential);
		};

		ws.on("open", () => {
			opened = true;
			ws.send(JSON.stringify({ t: "hello", v: PROTOCOL_VERSION, role, key: keyName, nonce: clientNonce }));
		});
		ws.on("message", onMessage);
		ws.on("unexpected-response", () => finish(new ForeignListenerError("Listener refused the WebSocket upgrade.")));
		ws.on("error", (error: NodeJS.ErrnoException) => {
			if (!opened && error.code === "ECONNREFUSED") return finish(new BrokerAbsentError(`Nothing listens on port ${port}.`));
			finish(new ForeignListenerError(`Connection to port ${port} failed: ${error.message}`));
		});
		ws.on("close", () => finish(new ForeignListenerError("Listener closed the connection during the handshake.")));
	});
}

interface Waiter {
	resolve: (value: unknown) => void;
	reject: (error: Error) => void;
	timer: NodeJS.Timeout;
}

/** An authenticated adapter-role connection to the broker. */
export class BrokerClient {
	private readonly waiters = new Map<string, Waiter>();
	private nextId = 1;
	private closed = false;

	constructor(
		private readonly ws: WebSocket,
		readonly port: number,
	) {
		ws.on("message", (data) => this.onMessage(String(data)));
		ws.on("close", () => this.onClose());
		ws.on("error", () => ws.terminate());
	}

	get isOpen(): boolean {
		return !this.closed && this.ws.readyState === WebSocket.OPEN;
	}

	request(method: string, params?: unknown, session?: string, timeoutMs?: number): Promise<unknown> {
		if (!this.isOpen) {
			return Promise.reject(new BridgeError("BROKER_UNAVAILABLE", "The connection to the broker is closed."));
		}
		const id = `c${this.nextId++}`;
		return new Promise<unknown>((resolve, reject) => {
			// The broker enforces the real timeout. This one only covers a broker that vanishes.
			const timer = setTimeout(() => {
				this.waiters.delete(id);
				reject(new BridgeError("TIMEOUT", `No answer to "${method}" from the broker.`));
			}, (timeoutMs ?? REQUEST_TIMEOUT_MS) + 2_000);
			this.waiters.set(id, { resolve, reject, timer });
			this.ws.send(JSON.stringify({ t: "req", id, method, session, params, timeoutMs }));
		});
	}

	close(): void {
		this.ws.close();
	}

	private onMessage(text: string): void {
		let parsed;
		try {
			parsed = ResponseMessage.safeParse(JSON.parse(text));
		} catch {
			return;
		}
		if (!parsed.success) return;
		const waiter = this.waiters.get(parsed.data.id);
		if (!waiter) return;
		clearTimeout(waiter.timer);
		this.waiters.delete(parsed.data.id);
		if (parsed.data.ok) return waiter.resolve(parsed.data.result);
		const error = parsed.data.error ?? { code: "INTERNAL", message: "Unknown error." };
		waiter.reject(new BridgeError(error.code, error.message, error.hint));
	}

	private onClose(): void {
		this.closed = true;
		for (const waiter of this.waiters.values()) {
			clearTimeout(waiter.timer);
			waiter.reject(new BridgeError("BROKER_UNAVAILABLE", "The broker connection closed."));
		}
		this.waiters.clear();
	}
}

export async function connectAdapter(port: number, secret: Buffer, timeoutMs?: number): Promise<BrokerClient> {
	const { ws } = await handshake({ port, role: "adapter", keyName: "user", key: secret, timeoutMs });
	return new BrokerClient(ws, port);
}
