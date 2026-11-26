import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { WebSocket } from "ws";
import { deriveCredentialKeyHex, pairingKey } from "../src/broker/auth.js";
import { handshake } from "../src/broker/client.js";
import type { SessionInfo, WireError } from "../src/broker/protocol.js";

export const CLI_PATH = fileURLToPath(new URL("../src/cli.js", import.meta.url));

export function tempHome(): { home: string; cleanup: () => void } {
	const home = mkdtempSync(join(tmpdir(), "keywright-test-"));
	return { home, cleanup: () => rmSync(home, { recursive: true, force: true }) };
}

export function freePort(): Promise<number> {
	return new Promise((resolve, reject) => {
		const server = createServer();
		server.once("error", reject);
		server.listen(0, "127.0.0.1", () => {
			const address = server.address();
			const port = typeof address === "object" && address ? address.port : 0;
			server.close(() => resolve(port));
		});
	});
}

export function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function waitFor(condition: () => boolean | Promise<boolean>, timeoutMs = 5_000): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!(await condition())) {
		if (Date.now() > deadline) throw new Error("Condition not met in time.");
		await sleep(25);
	}
}

export function isAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

export type Handler = (method: string, params: unknown) => unknown | Promise<unknown>;

/** Thrown by a fake plugin handler to answer with a structured error. */
export class PluginError extends Error {
	constructor(readonly wire: WireError) {
		super(wire.message);
	}
}

/** Stands in for the Studio plugin: same handshake, same wire messages. */
export class FakePlugin {
	readonly received: Array<{ method: string; params: unknown }> = [];
	/** Ids of requests the broker said were abandoned, and the ids of all requests seen. */
	readonly cancelled: string[] = [];
	readonly requestIds: string[] = [];

	private constructor(
		readonly ws: WebSocket,
		readonly session: SessionInfo,
		readonly credential: { id: string; keyHex: string } | undefined,
		private readonly handler: Handler,
	) {
		ws.on("message", (data) => void this.onMessage(String(data)));
	}

	static async pair(port: number, code: string, sessionId: string, handler: Handler = () => ({})): Promise<FakePlugin> {
		const key = pairingKey(code);
		const result = await handshake({ port, role: "plugin", keyName: "pair", key });
		if (!result.credential) throw new Error("Pairing returned no credential.");
		const keyHex = deriveCredentialKeyHex(key, result.clientNonce, result.serverNonce);
		return FakePlugin.finish(result.ws, sessionId, { id: result.credential, keyHex }, handler);
	}

	static async connect(
		port: number,
		credential: { id: string; keyHex: string },
		sessionId: string,
		handler: Handler = () => ({}),
	): Promise<FakePlugin> {
		const result = await handshake({
			port,
			role: "plugin",
			keyName: `cred:${credential.id}`,
			key: Buffer.from(credential.keyHex, "hex"),
		});
		return FakePlugin.finish(result.ws, sessionId, credential, handler);
	}

	private static async finish(
		ws: WebSocket,
		sessionId: string,
		credential: { id: string; keyHex: string },
		handler: Handler,
	): Promise<FakePlugin> {
		const session: SessionInfo = { id: sessionId, placeName: "Test Place", placeId: 0, pluginVersion: "test" };
		ws.send(JSON.stringify({ t: "session", session }));
		// A request from another connection could otherwise reach the broker before this
		// session does. The broker handles a connection's messages in order, so once it has
		// answered a ping sent after the session, the session is registered.
		await new Promise<void>((resolve) => {
			ws.once("pong", () => resolve());
			ws.ping();
		});
		return new FakePlugin(ws, session, credential, handler);
	}

	close(): void {
		this.ws.close();
	}

	private async onMessage(text: string): Promise<void> {
		const message = JSON.parse(text) as { t: string; id: string; method: string; params: unknown };
		if (message.t === "cancel") this.cancelled.push(message.id);
		if (message.t !== "req") return;
		this.requestIds.push(message.id);
		this.received.push({ method: message.method, params: message.params });
		try {
			const result = await this.handler(message.method, message.params);
			this.ws.send(JSON.stringify({ t: "res", id: message.id, ok: true, result }));
		} catch (error) {
			const wire = error instanceof PluginError ? error.wire : { code: "INTERNAL", message: String(error) };
			this.ws.send(JSON.stringify({ t: "res", id: message.id, ok: false, error: wire }));
		}
	}
}
