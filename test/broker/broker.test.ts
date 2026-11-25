import assert from "node:assert/strict";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { WebSocket } from "ws";
import { hmacHex, newNonce, pairingKey, proofInput } from "../../src/broker/auth.js";
import { Broker } from "../../src/broker/broker.js";
import { connectAdapter, DeniedError, ForeignListenerError, type BrokerClient } from "../../src/broker/client.js";
import { BridgeError, PROTOCOL_VERSION } from "../../src/broker/protocol.js";
import { loadOrCreateSecret } from "../../src/broker/state.js";
import { FakePlugin, freePort, PluginError, sleep, tempHome, waitFor, type Handler } from "../helpers.js";

const SESSION_A = "a".repeat(16);
const SESSION_B = "b".repeat(16);

function rawSocket(port: number, options?: { origin?: string }): Promise<WebSocket> {
	return new Promise((resolve, reject) => {
		const ws = new WebSocket(`ws://127.0.0.1:${port}/v1`, options);
		ws.once("open", () => resolve(ws));
		ws.once("error", reject);
	});
}

function nextMessage(ws: WebSocket): Promise<Record<string, unknown>> {
	return new Promise((resolve, reject) => {
		ws.once("message", (data) => resolve(JSON.parse(String(data)) as Record<string, unknown>));
		ws.once("close", () => reject(new Error("closed")));
	});
}

async function expectBridgeError(promise: Promise<unknown>, code: string): Promise<BridgeError> {
	try {
		await promise;
	} catch (error) {
		assert.ok(error instanceof BridgeError, `expected BridgeError, got ${String(error)}`);
		assert.equal(error.code, code);
		return error;
	}
	assert.fail(`expected ${code}`);
}

describe("broker", () => {
	const temp = tempHome();
	let port = 0;
	let broker: Broker;
	let secret: Buffer;
	let adapter: BrokerClient;

	before(async () => {
		port = await freePort();
		broker = new Broker({ home: temp.home, port });
		await broker.start();
		secret = loadOrCreateSecret(temp.home);
		adapter = await connectAdapter(port, secret);
	});

	after(async () => {
		adapter.close();
		await broker.stop();
		temp.cleanup();
	});

	const pairPlugin = async (sessionId: string, handler?: Handler) => {
		const code = `PAIR${Math.random().toString(36).slice(2, 10).toUpperCase()}`;
		await adapter.request("broker.pair_register", { code });
		return FakePlugin.pair(port, code, sessionId, handler);
	};

	test("an adapter with the user secret is accepted", async () => {
		const status = (await adapter.request("broker.status")) as { pid: number; port: number; adapters: number };
		assert.equal(status.pid, process.pid);
		assert.equal(status.port, port);
		assert.equal(status.adapters, 1);
	});

	test("a client with a different secret treats the broker as foreign", async () => {
		await assert.rejects(connectAdapter(port, Buffer.alloc(32, 7)), ForeignListenerError);
	});

	test("a wrong client proof is denied and nothing is routed", async () => {
		const ws = await rawSocket(port);
		const nonce = newNonce();
		ws.send(JSON.stringify({ t: "hello", v: PROTOCOL_VERSION, role: "adapter", key: "user", nonce }));
		const challenge = await nextMessage(ws);
		assert.equal(challenge.t, "challenge");
		ws.send(JSON.stringify({ t: "auth", proof: "0".repeat(64) }));
		assert.deepEqual(await nextMessage(ws), { t: "denied", code: "bad_proof", v: PROTOCOL_VERSION });
	});

	test("a request sent before authentication is refused", async () => {
		const plugin = await pairPlugin(SESSION_A);
		const ws = await rawSocket(port);
		ws.send(JSON.stringify({ t: "req", id: "x1", method: "edit_animation", session: SESSION_A, params: {} }));
		assert.equal((await nextMessage(ws)).t, "denied");
		await sleep(50);
		assert.equal(plugin.received.length, 0);
		plugin.close();
	});

	test("a protocol version mismatch is denied by name", async () => {
		const ws = await rawSocket(port);
		ws.send(JSON.stringify({ t: "hello", v: 999, role: "adapter", key: "user", nonce: newNonce() }));
		assert.equal((await nextMessage(ws)).code, "version");
	});

	test("web page origins and non-loopback hosts are rejected at upgrade", async () => {
		await assert.rejects(rawSocket(port, { origin: "http://evil.example" }), /403/);
		const response = await fetch(`http://127.0.0.1:${port}/v1`);
		assert.equal(response.status, 426);
		await assert.rejects(
			new Promise((resolve, reject) => {
				const ws = new WebSocket(`ws://127.0.0.1:${port}/v1`, { headers: { Host: "attacker.example" } });
				ws.once("open", resolve);
				ws.once("error", reject);
			}),
			/403/,
		);
	});

	test("pairing issues a credential once, and the credential reconnects", async () => {
		const code = "PAIRCODE23";
		await adapter.request("broker.pair_register", { code });
		const first = await FakePlugin.pair(port, code, SESSION_A);
		assert.ok(first.credential);
		assert.match(first.credential.id, /^[0-9a-f]{16}$/);

		// The code is single use.
		await assert.rejects(FakePlugin.pair(port, code, SESSION_B), (error) => {
			assert.ok(error instanceof DeniedError);
			assert.equal(error.code, "no_pairing");
			return true;
		});

		first.close();
		const again = await FakePlugin.connect(port, first.credential, SESSION_A);
		await waitFor(async () => {
			const { sessions } = (await adapter.request("broker.sessions")) as { sessions: Array<{ id: string }> };
			return sessions.some((session) => session.id === SESSION_A);
		});
		again.close();
	});

	test("a plugin without the code cannot pair, and repeated bad proofs burn the code", async () => {
		await adapter.request("broker.pair_register", { code: "RIGHTCODE2" });
		// A plugin holding the wrong code sees a broker proof it cannot verify and stops.
		await assert.rejects(FakePlugin.pair(port, "WRONGCODE2", SESSION_A), ForeignListenerError);

		for (let attempt = 0; attempt < 5; attempt++) {
			const ws = await rawSocket(port);
			ws.send(JSON.stringify({ t: "hello", v: PROTOCOL_VERSION, role: "plugin", key: "pair", nonce: newNonce() }));
			await nextMessage(ws);
			ws.send(JSON.stringify({ t: "auth", proof: "f".repeat(64) }));
			assert.equal((await nextMessage(ws)).code, "bad_proof");
		}
		await assert.rejects(FakePlugin.pair(port, "RIGHTCODE2", SESSION_A), (error) => {
			assert.ok(error instanceof DeniedError);
			assert.equal(error.code, "no_pairing");
			return true;
		});
	});

	test("an unknown credential is denied", async () => {
		await assert.rejects(
			FakePlugin.connect(port, { id: "0123456789abcdef", keyHex: "11".repeat(32) }, SESSION_A),
			(error) => {
				assert.ok(error instanceof DeniedError);
				assert.equal(error.code, "unknown_credential");
				return true;
			},
		);
	});

	test("a plugin connection cannot issue requests", async () => {
		const plugin = await pairPlugin(SESSION_B);
		const other = await pairPlugin(SESSION_A);
		plugin.ws.send(JSON.stringify({ t: "req", id: "p1", method: "edit_animation", session: SESSION_A, params: {} }));
		await new Promise((resolve) => plugin.ws.once("close", resolve));
		assert.equal(other.received.length, 0);
		other.close();
	});

	test("requests are routed to the named session only", async () => {
		const a = await pairPlugin(SESSION_A, (method: string, params: unknown) => ({ from: "a", method, params }));
		const b = await pairPlugin(SESSION_B, (method: string) => ({ from: "b", method }));

		assert.deepEqual(await adapter.request("inspect_rig", { rig_id: "rig_1" }, SESSION_A), {
			from: "a",
			method: "inspect_rig",
			params: { rig_id: "rig_1" },
		});
		assert.deepEqual(await adapter.request("inspect_rig", {}, SESSION_B), { from: "b", method: "inspect_rig" });
		assert.equal(a.received.length, 1);
		assert.equal(b.received.length, 1);

		const error = await expectBridgeError(adapter.request("inspect_rig", {}, "c".repeat(16)), "SESSION_NOT_FOUND");
		assert.ok(error.hint);
		await expectBridgeError(adapter.request("inspect_rig", {}), "SESSION_NOT_FOUND");
		a.close();
		b.close();
	});

	test("plugin errors keep their code, message and hint", async () => {
		const plugin = await pairPlugin(SESSION_A, () => {
			throw new PluginError({ code: "REVISION_CONFLICT", message: "Expected r1, clip is at r2.", hint: "Read again." });
		});
		const error = await expectBridgeError(adapter.request("edit_animation", {}, SESSION_A), "REVISION_CONFLICT");
		assert.equal(error.message, "Expected r1, clip is at r2.");
		assert.equal(error.hint, "Read again.");
		plugin.close();
	});

	test("a slow session times out, and a late answer is dropped", async () => {
		const plugin = await pairPlugin(SESSION_A, async () => {
			await sleep(400);
			return { late: true };
		});
		await expectBridgeError(adapter.request("preview_animation", {}, SESSION_A, 100), "TIMEOUT");
		// The session is told at once that nobody is waiting, so it can stop the work.
		await sleep(50);
		assert.deepEqual(plugin.cancelled, plugin.requestIds);
		assert.equal(plugin.cancelled.length, 1);
		await sleep(400);
		assert.deepEqual(await adapter.request("broker.status").then(() => "alive"), "alive");
		plugin.close();
	});

	test("a request whose caller disconnects is cancelled in the session", async () => {
		const plugin = await pairPlugin(SESSION_A, async () => {
			await sleep(300);
			return {};
		});
		const caller = await connectAdapter(port, secret);
		const pending = caller.request("preview_animation", { capture: true }, SESSION_A, 5000).catch(() => "gone");
		await sleep(50);
		assert.equal(plugin.requestIds.length, 1);
		assert.deepEqual(plugin.cancelled, []);
		caller.close();
		await sleep(50);
		assert.deepEqual(plugin.cancelled, plugin.requestIds);
		await pending;
		// A request that was answered in time is never reported as abandoned.
		const quick = await pairPlugin(SESSION_B, () => ({ ok: true }));
		await adapter.request("read_animation", {}, SESSION_B);
		await sleep(30);
		assert.deepEqual(quick.cancelled, []);
		plugin.close();
		quick.close();
	});

	test("a connection that replaces a session cannot answer what the old one was asked", async () => {
		const original = await pairPlugin(SESSION_A, async () => {
			await sleep(2000);
			return { from: "original" };
		});
		const pending = adapter.request("preview_animation", { capture: true }, SESSION_A, 1500);
		await sleep(50);
		const asked = original.requestIds[0] as string;
		// A second authenticated plugin takes over the same session id and answers the old request.
		const replacement = await FakePlugin.connect(port, original.credential as { id: string; keyHex: string }, SESSION_A, () => ({
			from: "replacement",
		}));
		replacement.ws.send(JSON.stringify({ t: "res", id: asked, ok: true, result: { from: "replacement", images: [] } }));
		await expectBridgeError(pending, "SESSION_NOT_FOUND");
		assert.deepEqual(replacement.requestIds, []);
		// The replacement serves new requests as itself.
		assert.deepEqual(await adapter.request("read_animation", {}, SESSION_A), { from: "replacement" });
		replacement.close();
		original.close();
	});

	test("a caller that cancels a request stops it in the session", async () => {
		const plugin = await pairPlugin(SESSION_A, async () => {
			await sleep(300);
			return {};
		});
		const caller = await connectAdapter(port, secret);
		const controller = new AbortController();
		const pending = caller.request("preview_animation", { capture: true }, SESSION_A, 5000, controller.signal);
		const outcome = pending.then(
			() => "answered",
			(error: { code?: string }) => error.code,
		);
		await sleep(50);
		assert.deepEqual(plugin.cancelled, []);
		controller.abort();
		assert.equal(await outcome, "CANCELLED");
		await sleep(50);
		assert.deepEqual(plugin.cancelled, plugin.requestIds);
		// The late answer goes nowhere, and the connection is still usable.
		await sleep(300);
		assert.deepEqual(await caller.request("broker.status").then(() => "alive"), "alive");
		// A request cancelled before it is sent never reaches the session.
		const before = plugin.requestIds.length;
		const spent = new AbortController();
		spent.abort();
		await expectBridgeError(caller.request("preview_animation", {}, SESSION_A, 5000, spent.signal), "CANCELLED");
		await sleep(30);
		assert.equal(plugin.requestIds.length, before);
		// One caller cannot cancel another's request.
		const other = adapter.request("read_animation", {}, SESSION_A, 2000);
		await sleep(30);
		const theirs = plugin.requestIds.length;
		caller.close();
		await other;
		assert.equal(plugin.cancelled.length, theirs - 1);
		plugin.close();
	});

	test("a session that disconnects mid-request fails the request", async () => {
		const plugin = await pairPlugin(SESSION_A, () => new Promise(() => {}));
		const pending = adapter.request("edit_animation", {}, SESSION_A);
		await waitFor(() => plugin.received.length === 1);
		plugin.close();
		await expectBridgeError(pending, "SESSION_NOT_FOUND");
	});

	test("a response from another session cannot answer a request", async () => {
		const a = await pairPlugin(SESSION_A, () => new Promise(() => {}));
		const b = await pairPlugin(SESSION_B);
		const pending = adapter.request("read_animation", {}, SESSION_A, 300);
		await waitFor(() => a.received.length === 1);
		// Broker request ids are sequential, so another session could guess them.
		for (let id = 1; id < 200; id++) b.ws.send(JSON.stringify({ t: "res", id: `b${id}`, ok: true, result: { forged: true } }));
		await expectBridgeError(pending, "TIMEOUT");
		a.close();
		b.close();
	});

	test("a 1 MiB payload crosses the broker intact in both directions", async () => {
		const big = "x".repeat(1024 * 1024);
		const plugin = await pairPlugin(SESSION_A, (_method: string, params: unknown) => params);
		const result = (await adapter.request("echo", { big }, SESSION_A)) as { big: string };
		assert.equal(result.big.length, big.length);
		assert.equal(result.big, big);
		plugin.close();
	});
});

describe("credential rotation", () => {
	test("credentials issued under an old secret stop working", async () => {
		const temp = tempHome();
		const port = await freePort();
		let broker = new Broker({ home: temp.home, port });
		await broker.start();
		let adapter = await connectAdapter(port, loadOrCreateSecret(temp.home));
		await adapter.request("broker.pair_register", { code: "ROTATE2345" });
		const plugin = await FakePlugin.pair(port, "ROTATE2345", SESSION_A);
		assert.ok(plugin.credential);
		plugin.close();
		adapter.close();
		await broker.stop();

		// Same secret: the credential survives a broker restart.
		broker = new Broker({ home: temp.home, port });
		await broker.start();
		(await FakePlugin.connect(port, plugin.credential, SESSION_A)).close();
		await broker.stop();

		// Rotated secret: the credential is gone.
		rmSync(join(temp.home, "secret"));
		broker = new Broker({ home: temp.home, port });
		await broker.start();
		await assert.rejects(FakePlugin.connect(port, plugin.credential, SESSION_A), (error) => {
			assert.ok(error instanceof DeniedError);
			assert.equal(error.code, "unknown_credential");
			return true;
		});
		adapter = await connectAdapter(port, loadOrCreateSecret(temp.home));
		adapter.close();
		await broker.stop();
		temp.cleanup();
	});
});

test("the handshake proof is not accepted when replayed with other nonces", () => {
	const key = pairingKey("REPLAYCODE");
	const first = hmacHex(key, proofInput("client", "plugin", "a".repeat(32), "b".repeat(32)));
	const second = hmacHex(key, proofInput("client", "plugin", "a".repeat(32), "c".repeat(32)));
	assert.notEqual(first, second);
});
