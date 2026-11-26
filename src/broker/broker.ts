import { createHash } from "node:crypto";
import { appendFileSync, statSync, truncateSync } from "node:fs";
import { createServer, type IncomingMessage, type Server } from "node:http";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { WebSocketServer, type RawData, type WebSocket } from "ws";
import {
	deriveCredentialKeyHex,
	hmacHex,
	isValidPairingCode,
	newCredentialId,
	newNonce,
	pairingKey,
	proofInput,
	safeEqualHex,
} from "./auth.js";
import {
	AuthMessage,
	BridgeError,
	CancelMessage,
	HANDSHAKE_TIMEOUT_MS,
	HelloMessage,
	IDLE_EXIT_MS,
	MAX_MESSAGE_BYTES,
	PAIRING_MAX_FAILURES,
	PAIRING_TTL_MS,
	PROTOCOL_VERSION,
	REQUEST_TIMEOUT_MS,
	RequestMessage,
	ResponseMessage,
	SessionMessage,
	type Role,
	type SessionInfo,
	type WireError,
} from "./protocol.js";
import {
	loadCredentials,
	loadOrCreateSecret,
	removeBrokerState,
	saveCredentials,
	writeBrokerState,
	type CredentialStore,
} from "./state.js";
import { VERSION } from "../version.js";

const LOG_LIMIT_BYTES = 1024 * 1024;

export interface BrokerOptions {
	home: string;
	port: number;
	idleExitMs?: number;
	/** Called once when no adapter has been connected for `idleExitMs`. */
	onIdle?: () => void;
	/** Called when an adapter asks the broker to stop. Default: the broker stops itself. */
	onShutdown?: () => void;
	/** The release this broker says it belongs to. Default: this one. Tests give others. */
	version?: string;
}

interface Peer {
	ws: WebSocket;
	phase: "hello" | "auth" | "ready";
	role?: Role;
	clientNonce?: string;
	serverNonce?: string;
	key?: Buffer;
	/** The pairing registration this handshake started under; only it can finish the pairing. */
	pairing?: PendingPairing;
	session?: SessionInfo;
	handshakeTimer?: NodeJS.Timeout;
}

interface PendingRequest {
	adapter: Peer;
	clientId: string;
	sessionId: string;
	/** The one connection the request was sent to. Only it can answer. */
	target: Peer;
	timer: NodeJS.Timeout;
}

interface PendingPairing {
	key: Buffer;
	expiresAt: number;
	failures: number;
}

function isLoopbackHost(host: string | undefined): boolean {
	if (host === undefined) return false;
	const name = host.replace(/:\d+$/, "").toLowerCase();
	return name === "127.0.0.1" || name === "localhost" || name === "[::1]";
}

export class Broker {
	private readonly options: BrokerOptions;
	private readonly secret: Buffer;
	private readonly secretFingerprint: string;
	private credentials: CredentialStore;
	private server?: Server;
	private wss?: WebSocketServer;
	private readonly peers = new Set<Peer>();
	private readonly sessions = new Map<string, Peer>();
	private readonly pending = new Map<string, PendingRequest>();
	private pairing?: PendingPairing;
	private nextRequestId = 1;
	private idleTimer?: NodeJS.Timeout;

	constructor(options: BrokerOptions) {
		this.options = options;
		this.secret = loadOrCreateSecret(options.home);
		this.secretFingerprint = createHash("sha256").update(this.secret).digest("hex").slice(0, 16);
		this.credentials = loadCredentials(options.home, this.secretFingerprint);
	}

	/** Binds the loopback port. Rejects with `EADDRINUSE` when something else holds it. */
	async start(): Promise<void> {
		const server = createServer((_request, response) => {
			response.writeHead(426, { "Content-Type": "text/plain" });
			response.end("Upgrade Required");
		});
		const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
		server.on("upgrade", (request, socket, head) => this.onUpgrade(request, socket, head));
		await new Promise<void>((resolve, reject) => {
			server.once("error", reject);
			server.listen({ port: this.options.port, host: "127.0.0.1", exclusive: true }, () => {
				server.off("error", reject);
				resolve();
			});
		});
		this.server = server;
		this.wss = wss;
		writeBrokerState(this.options.home, {
			port: this.options.port,
			pid: process.pid,
			protocol: PROTOCOL_VERSION,
			version: this.options.version ?? VERSION,
			startedAt: new Date().toISOString(),
		});
		this.log(`listening on 127.0.0.1:${this.options.port} pid=${process.pid}`);
		this.armIdleTimer();
	}

	async stop(): Promise<void> {
		clearTimeout(this.idleTimer);
		for (const request of this.pending.values()) clearTimeout(request.timer);
		this.pending.clear();
		for (const peer of this.peers) {
			clearTimeout(peer.handshakeTimer);
			peer.ws.terminate();
		}
		this.peers.clear();
		this.sessions.clear();
		this.wss?.close();
		const server = this.server;
		if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
		removeBrokerState(this.options.home, process.pid);
	}

	private log(line: string): void {
		const file = join(this.options.home, "broker.log");
		try {
			const size = statSync(file, { throwIfNoEntry: false })?.size ?? 0;
			if (size > LOG_LIMIT_BYTES) truncateSync(file, 0);
			appendFileSync(file, `${new Date().toISOString()} ${line}\n`, { mode: 0o600 });
		} catch {
			// Logging must never take the broker down.
		}
	}

	private onUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
		const origin = request.headers.origin;
		// Browsers always send Origin on WebSocket requests; our clients never do.
		if (request.url !== "/v1" || !isLoopbackHost(request.headers.host) || origin !== undefined) {
			this.log(`rejected upgrade url=${request.url} host=${request.headers.host} origin=${origin}`);
			socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
			socket.destroy();
			return;
		}
		this.wss?.handleUpgrade(request, socket, head, (ws) => {
			this.onConnection(ws, String(request.headers["user-agent"] ?? ""));
		});
	}

	private onConnection(ws: WebSocket, userAgent: string): void {
		const peer: Peer = { ws, phase: "hello" };
		this.peers.add(peer);
		this.log(`connection user-agent="${userAgent}"`);
		peer.handshakeTimer = setTimeout(() => this.deny(peer, "handshake_timeout"), HANDSHAKE_TIMEOUT_MS);
		ws.on("message", (data, isBinary) => {
			if (isBinary) return this.deny(peer, "binary_not_supported");
			let message: unknown;
			try {
				message = JSON.parse(rawToString(data));
			} catch {
				return this.deny(peer, "malformed");
			}
			try {
				this.onMessage(peer, message);
			} catch (error) {
				this.log(`message handling failed: ${String(error)}`);
				this.deny(peer, "malformed");
			}
		});
		ws.on("close", () => this.onClose(peer));
		ws.on("error", () => ws.terminate());
	}

	private send(peer: Peer, message: object): void {
		if (peer.ws.readyState === peer.ws.OPEN) peer.ws.send(JSON.stringify(message));
	}

	private deny(peer: Peer, code: string): void {
		this.send(peer, { t: "denied", code, v: PROTOCOL_VERSION });
		peer.ws.close();
	}

	private onMessage(peer: Peer, message: unknown): void {
		if (peer.phase === "hello") return this.onHello(peer, message);
		if (peer.phase === "auth") return this.onAuth(peer, message);
		if (peer.role === "adapter") return this.onAdapterMessage(peer, message);
		return this.onPluginMessage(peer, message);
	}

	private onHello(peer: Peer, message: unknown): void {
		const hello = HelloMessage.safeParse(message);
		if (!hello.success) return this.deny(peer, "malformed");
		if (hello.data.v !== PROTOCOL_VERSION) return this.deny(peer, "version");
		const { role, key: keyName, nonce } = hello.data;

		let key: Buffer | undefined;
		if (role === "adapter") {
			if (keyName !== "user") return this.deny(peer, "wrong_key");
			key = this.secret;
		} else if (keyName === "pair") {
			if (!this.pairing || this.pairing.expiresAt < Date.now()) {
				this.pairing = undefined;
				return this.deny(peer, "no_pairing");
			}
			key = this.pairing.key;
			peer.pairing = this.pairing;
		} else if (keyName.startsWith("cred:")) {
			const stored = this.credentials[keyName.slice(5)];
			if (!stored) return this.deny(peer, "unknown_credential");
			key = Buffer.from(stored.key, "hex");
		} else {
			return this.deny(peer, "wrong_key");
		}

		peer.role = role;
		peer.key = key;
		peer.clientNonce = nonce;
		peer.serverNonce = newNonce();
		peer.phase = "auth";
		this.send(peer, {
			t: "challenge",
			v: PROTOCOL_VERSION,
			nonce: peer.serverNonce,
			proof: hmacHex(key, proofInput("broker", role, nonce, peer.serverNonce)),
		});
	}

	private onAuth(peer: Peer, message: unknown): void {
		const auth = AuthMessage.safeParse(message);
		const { role, key, clientNonce, serverNonce } = peer;
		if (!auth.success || !role || !key || !clientNonce || !serverNonce) return this.deny(peer, "malformed");
		const expected = hmacHex(key, proofInput("client", role, clientNonce, serverNonce));
		if (!safeEqualHex(auth.data.proof, expected)) {
			// A failed proof counts against the registration it was made for, and only while
			// that one is still the one waiting.
			if (peer.pairing && this.pairing === peer.pairing) {
				this.pairing.failures += 1;
				if (this.pairing.failures >= PAIRING_MAX_FAILURES) this.pairing = undefined;
			}
			return this.deny(peer, "bad_proof");
		}
		// A registration is used once: of two handshakes begun with one code, only the first
		// to finish gets a credential, and a registration replaced or expired meanwhile gives none.
		if (peer.pairing && (this.pairing !== peer.pairing || peer.pairing.expiresAt < Date.now())) {
			return this.deny(peer, "no_pairing");
		}

		clearTimeout(peer.handshakeTimer);
		peer.phase = "ready";
		if (role === "adapter") {
			clearTimeout(this.idleTimer);
			this.send(peer, { t: "ready" });
			return;
		}
		if (peer.pairing) {
			const id = newCredentialId();
			this.credentials[id] = {
				key: deriveCredentialKeyHex(key, clientNonce, serverNonce),
				createdAt: new Date().toISOString(),
			};
			saveCredentials(this.options.home, this.secretFingerprint, this.credentials);
			this.pairing = undefined;
			this.log(`paired credential ${id}`);
			this.send(peer, { t: "ready", credential: id });
			return;
		}
		this.send(peer, { t: "ready" });
	}

	private onAdapterMessage(peer: Peer, message: unknown): void {
		const abandoned = CancelMessage.safeParse(message);
		if (abandoned.success) {
			// The caller no longer wants an answer. Its request stops waiting and Studio is told.
			for (const [brokerId, pending] of this.pending) {
				if (pending.adapter !== peer || pending.clientId !== abandoned.data.id) continue;
				clearTimeout(pending.timer);
				this.pending.delete(brokerId);
				this.cancel(pending.target, brokerId);
			}
			return;
		}
		const request = RequestMessage.safeParse(message);
		if (!request.success) return this.deny(peer, "malformed");
		const { id, method, session, params, timeoutMs } = request.data;
		const fail = (error: BridgeError) => this.send(peer, { t: "res", id, ok: false, error: error.toWire() });

		if (method.startsWith("broker.")) {
			try {
				this.send(peer, { t: "res", id, ok: true, result: this.handleBrokerMethod(method, params) });
			} catch (error) {
				fail(error instanceof BridgeError ? error : new BridgeError("INTERNAL", String(error)));
			}
			return;
		}

		const target = session === undefined ? undefined : this.sessions.get(session);
		if (!target || session === undefined) {
			return fail(
				new BridgeError(
					"SESSION_NOT_FOUND",
					`No Studio session "${session ?? ""}" is connected.`,
					"Call get_workspace to list sessions. In Studio, check that agent access is on.",
				),
			);
		}
		const brokerId = `b${this.nextRequestId++}`;
		const timer = setTimeout(() => {
			this.pending.delete(brokerId);
			// Nobody is waiting any more, so Studio is told to stop working on it.
			this.cancel(target, brokerId);
			fail(
				new BridgeError(
					"TIMEOUT",
					`Studio did not answer "${method}" in time.`,
					"A mutation that timed out is either fully applied or not applied. Read the revision to find out.",
				),
			);
		}, timeoutMs ?? REQUEST_TIMEOUT_MS);
		this.pending.set(brokerId, { adapter: peer, clientId: id, sessionId: session, target, timer });
		this.send(target, { t: "req", id: brokerId, method, params });
	}

	/** Tells the Studio connection a request was sent to that the request has been abandoned. */
	private cancel(target: Peer, brokerId: string): void {
		if (this.peers.has(target)) this.send(target, { t: "cancel", id: brokerId });
	}

	/** Fails every request still waiting on a Studio connection that can no longer answer it. */
	private failPendingFor(target: Peer, message: string): void {
		for (const [brokerId, request] of this.pending) {
			if (request.target !== target) continue;
			clearTimeout(request.timer);
			this.pending.delete(brokerId);
			this.cancel(target, brokerId);
			this.send(request.adapter, {
				t: "res",
				id: request.clientId,
				ok: false,
				error: new BridgeError("SESSION_NOT_FOUND", message, "Read the revision before retrying a mutation.").toWire(),
			});
		}
	}

	private handleBrokerMethod(method: string, params: unknown): unknown {
		if (method === "broker.status") {
			let adapters = 0;
			for (const peer of this.peers) if (peer.phase === "ready" && peer.role === "adapter") adapters += 1;
			return {
				pid: process.pid,
				port: this.options.port,
				protocol: PROTOCOL_VERSION,
				version: this.options.version ?? VERSION,
				adapters,
				sessions: this.sessions.size,
			};
		}
		if (method === "broker.sessions") {
			return { sessions: [...this.sessions.values()].map((peer) => peer.session) };
		}
		if (method === "broker.pair_register") {
			const code = (params as { code?: unknown } | undefined)?.code;
			if (typeof code !== "string" || !isValidPairingCode(code)) {
				throw new BridgeError("INVALID_ARGUMENT", "A pairing code of 8 to 32 letters and digits is required.");
			}
			// Only one code is pending at a time, so the hello message never has to identify it.
			this.pairing = { key: pairingKey(code), expiresAt: Date.now() + PAIRING_TTL_MS, failures: 0 };
			return { expiresInMs: PAIRING_TTL_MS };
		}
		if (method === "broker.shutdown") {
			// After the answer has gone out, so that the adapter that asked hears it.
			setTimeout(() => (this.options.onShutdown ? this.options.onShutdown() : void this.stop()), 50);
			return { stopping: true };
		}
		throw new BridgeError("INVALID_ARGUMENT", `Unknown broker method "${method}".`);
	}

	private onPluginMessage(peer: Peer, message: unknown): void {
		const type = (message as { t?: unknown } | null)?.t;
		if (type === "session") {
			const parsed = SessionMessage.safeParse(message);
			if (!parsed.success) return this.deny(peer, "malformed");
			const previous = this.sessions.get(parsed.data.session.id);
			if (previous && previous !== peer) {
				// Requests sent to the old connection are not inherited by the new one.
				this.failPendingFor(previous, "The Studio session was replaced by another connection before answering.");
				previous.ws.close();
			}
			if (peer.session) this.sessions.delete(peer.session.id);
			peer.session = parsed.data.session;
			this.sessions.set(peer.session.id, peer);
			this.log(`session ${peer.session.id} registered place="${peer.session.placeName}"`);
			return;
		}
		if (type === "res") {
			const parsed = ResponseMessage.safeParse(message);
			if (!parsed.success) return this.deny(peer, "malformed");
			const request = this.pending.get(parsed.data.id);
			// A response only counts when it comes from the very connection the request was sent to.
			if (!request || request.target !== peer) return;
			clearTimeout(request.timer);
			this.pending.delete(parsed.data.id);
			const error: WireError | undefined = parsed.data.error;
			this.send(request.adapter, {
				t: "res",
				id: request.clientId,
				ok: parsed.data.ok,
				...(parsed.data.ok ? { result: parsed.data.result } : { error }),
			});
			return;
		}
		this.deny(peer, "malformed");
	}

	private onClose(peer: Peer): void {
		clearTimeout(peer.handshakeTimer);
		this.peers.delete(peer);
		if (peer.session && this.sessions.get(peer.session.id) === peer) {
			const sessionId = peer.session.id;
			this.sessions.delete(sessionId);
			this.log(`session ${sessionId} disconnected`);
		}
		if (peer.role === "plugin") this.failPendingFor(peer, "The Studio session disconnected before answering.");
		if (peer.role === "adapter") {
			for (const [brokerId, request] of this.pending) {
				if (request.adapter !== peer) continue;
				clearTimeout(request.timer);
				this.pending.delete(brokerId);
				// The caller is gone; its request must not keep running in Studio.
				this.cancel(request.target, brokerId);
			}
			this.armIdleTimer();
		}
	}

	private armIdleTimer(): void {
		clearTimeout(this.idleTimer);
		for (const peer of this.peers) if (peer.role === "adapter" && peer.phase === "ready") return;
		if (!this.options.onIdle) return;
		this.idleTimer = setTimeout(() => this.options.onIdle?.(), this.options.idleExitMs ?? IDLE_EXIT_MS);
		this.idleTimer.unref();
	}
}

function rawToString(data: RawData): string {
	if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
	if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
	return data.toString("utf8");
}
