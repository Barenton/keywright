import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { createServer as createTcpServer, type Server } from "node:net";
import { join } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";
import { WebSocketServer } from "ws";
import { DeniedError } from "../../src/broker/client.js";
import { ensureBroker } from "../../src/broker/launcher.js";
import { BridgeError } from "../../src/broker/protocol.js";
import { readBrokerState } from "../../src/broker/state.js";
import { CLI_PATH, FakePlugin, freePort, isAlive, tempHome, waitFor } from "../helpers.js";

const run = promisify(execFile);

function cliEnv(home: string, port: number, extra: Record<string, string> = {}): NodeJS.ProcessEnv {
	return { ...process.env, KEYWRIGHT_HOME: home, KEYWRIGHT_PORT: String(port), ...extra };
}

async function stopBroker(home: string): Promise<void> {
	const state = readBrokerState(home);
	if (!state || !isAlive(state.pid)) return;
	process.kill(state.pid, "SIGTERM");
	await waitFor(() => !isAlive(state.pid));
}

function closeServer(server: Server | ReturnType<typeof createHttpServer>): Promise<void> {
	return new Promise((resolve) => server.close(() => resolve()));
}

async function expectConflict(home: string, port: number): Promise<void> {
	try {
		const client = await ensureBroker({ home, port });
		client.close();
	} catch (error) {
		assert.ok(error instanceof BridgeError, String(error));
		assert.equal(error.code, "BROKER_PORT_CONFLICT");
		assert.match(error.message, new RegExp(String(port)));
		assert.ok(error.hint?.includes("Close that program"));
		// Nothing of ours may have started behind the foreign listener.
		assert.equal(readBrokerState(home), undefined);
		return;
	}
	assert.fail("expected BROKER_PORT_CONFLICT");
}

test("E7: twenty adapters started together produce exactly one broker", async () => {
	const temp = tempHome();
	const port = await freePort();
	try {
		const results = await Promise.all(
			Array.from({ length: 20 }, () => run(process.execPath, [CLI_PATH, "status"], { env: cliEnv(temp.home, port) })),
		);
		const pids = new Set(results.map((result) => (JSON.parse(result.stdout) as { pid: number }).pid));
		assert.equal(pids.size, 1, `expected one broker, saw pids ${[...pids].join(", ")}`);
		const [pid] = [...pids];
		assert.ok(pid !== undefined && isAlive(pid));
		assert.equal(readBrokerState(temp.home)?.pid, pid);
		assert.equal(readBrokerState(temp.home)?.port, port);

		// The losers of the bind race must have exited: only one process listens, and a second broker cannot start.
		const second = spawn(process.execPath, [CLI_PATH, "broker"], { env: cliEnv(temp.home, port), stdio: "ignore" });
		const code = await new Promise<number | null>((resolve) => second.once("exit", resolve));
		assert.equal(code, 3);
		assert.equal(readBrokerState(temp.home)?.pid, pid);
	} finally {
		await stopBroker(temp.home);
		temp.cleanup();
	}
});

test("E7: a silent TCP listener on the port is reported as a conflict", async () => {
	const temp = tempHome();
	const port = await freePort();
	const received: Buffer[] = [];
	const server = createTcpServer((socket) => {
		socket.on("data", (chunk) => received.push(chunk));
		socket.on("error", () => {});
	});
	await new Promise<void>((resolve) => server.listen(port, "127.0.0.1", resolve));
	try {
		await expectConflict(temp.home, port);
		// It saw the HTTP upgrade request and nothing else: no secret, no proof, no request.
		const text = Buffer.concat(received).toString("utf8");
		assert.match(text, /^GET \/v1 HTTP\/1\.1/);
		assert.doesNotMatch(text, /"t":/);
	} finally {
		await closeServer(server);
		temp.cleanup();
	}
});

test("E7: an HTTP server on the port is reported as a conflict", async () => {
	const temp = tempHome();
	const port = await freePort();
	const server = createHttpServer((_request, response) => response.end("hello"));
	await new Promise<void>((resolve) => server.listen(port, "127.0.0.1", resolve));
	try {
		await expectConflict(temp.home, port);
	} finally {
		await closeServer(server);
		temp.cleanup();
	}
});

test("E7: a WebSocket server that imitates the broker receives a hello and nothing more", async () => {
	const temp = tempHome();
	const port = await freePort();
	const received: Array<Record<string, unknown>> = [];
	const wss = new WebSocketServer({ port, host: "127.0.0.1" });
	wss.on("connection", (ws) => {
		ws.on("message", (data) => {
			received.push(JSON.parse(String(data)) as Record<string, unknown>);
			// Answer like a broker would, without knowing the secret.
			ws.send(JSON.stringify({ t: "challenge", v: 1, nonce: "0".repeat(32), proof: "0".repeat(64) }));
		});
	});
	await new Promise<void>((resolve) => wss.once("listening", resolve));
	try {
		await expectConflict(temp.home, port);
		assert.equal(received.length, 1);
		assert.deepEqual(Object.keys(received[0] ?? {}).sort(), ["key", "nonce", "role", "t", "v"]);
		assert.equal(received[0]?.t, "hello");
	} finally {
		await new Promise<void>((resolve) => wss.close(() => resolve()));
		temp.cleanup();
	}
});

test("E7: the CLI reports a port conflict and exits non-zero", async () => {
	const temp = tempHome();
	const port = await freePort();
	const server = createHttpServer((_request, response) => response.end("hello"));
	await new Promise<void>((resolve) => server.listen(port, "127.0.0.1", resolve));
	try {
		await assert.rejects(run(process.execPath, [CLI_PATH, "status"], { env: cliEnv(temp.home, port) }), (error) => {
			const failure = error as { code: number; stderr: string };
			assert.equal(failure.code, 1);
			assert.match(failure.stderr, /BROKER_PORT_CONFLICT/);
			return true;
		});
	} finally {
		await closeServer(server);
		temp.cleanup();
	}
});

test("E7: a state file left by a dead broker is replaced", async () => {
	const temp = tempHome();
	const port = await freePort();
	const stalePort = await freePort();
	writeFileSync(
		join(temp.home, "broker.json"),
		JSON.stringify({ port: stalePort, pid: 2 ** 22 + 12345, protocol: 1, startedAt: "2020-01-01T00:00:00Z" }),
	);
	try {
		const client = await ensureBroker({ home: temp.home, port });
		const status = (await client.request("broker.status")) as { pid: number; port: number };
		client.close();
		assert.equal(status.port, port);
		assert.deepEqual(
			{ pid: readBrokerState(temp.home)?.pid, port: readBrokerState(temp.home)?.port },
			{ pid: status.pid, port },
		);
	} finally {
		await stopBroker(temp.home);
		temp.cleanup();
	}
});

test("the broker exits when no adapter has been connected for the idle period", async () => {
	const temp = tempHome();
	const port = await freePort();
	try {
		const client = await ensureBroker({
			home: temp.home,
			port,
			env: cliEnv(temp.home, port, { KEYWRIGHT_IDLE_EXIT_MS: "300" }),
		});
		const { pid } = (await client.request("broker.status")) as { pid: number };
		assert.ok(isAlive(pid));
		client.close();
		await waitFor(() => !isAlive(pid), 5_000);
		assert.equal(existsSync(join(temp.home, "broker.json")), false);
	} finally {
		await stopBroker(temp.home);
		temp.cleanup();
	}
});

test("rotate stops the broker, replaces the secret, and leaves old credentials refused", async () => {
	const temp = tempHome();
	const port = await freePort();
	try {
		// A broker started the usual way, with one plugin paired to it.
		const status = JSON.parse((await run(process.execPath, [CLI_PATH, "status"], { env: cliEnv(temp.home, port) })).stdout) as { pid: number };
		await run(process.execPath, [CLI_PATH, "pair", "ROTATECLI23"], { env: cliEnv(temp.home, port) });
		const plugin = await FakePlugin.pair(port, "ROTATECLI23", "f".repeat(16));
		assert.ok(plugin.credential);
		plugin.close();
		const before = readFileSync(join(temp.home, "secret"), "utf8");

		const rotated = await run(process.execPath, [CLI_PATH, "rotate"], { env: cliEnv(temp.home, port) });
		assert.match(rotated.stdout, /must pair again/);
		await waitFor(() => !isAlive(status.pid), 5_000);
		const after = readFileSync(join(temp.home, "secret"), "utf8");
		assert.match(after.trim(), /^[0-9a-f]{64}$/);
		assert.notEqual(after, before);
		assert.equal(existsSync(join(temp.home, "credentials.json")), false);

		// The next adapter starts a broker with the new secret; the old credential is refused.
		const client = await ensureBroker({ home: temp.home, port, env: cliEnv(temp.home, port) });
		const restarted = (await client.request("broker.status")) as { pid: number };
		assert.notEqual(restarted.pid, status.pid);
		await assert.rejects(FakePlugin.connect(port, plugin.credential, "f".repeat(16)), (error) => {
			assert.ok(error instanceof DeniedError);
			assert.equal(error.code, "unknown_credential");
			return true;
		});
		client.close();

		// With no broker running there is nothing to stop, and the secret is still replaced.
		await stopBroker(temp.home);
		await run(process.execPath, [CLI_PATH, "rotate"], { env: cliEnv(temp.home, port) });
		assert.notEqual(readFileSync(join(temp.home, "secret"), "utf8"), after);
	} finally {
		await stopBroker(temp.home);
		temp.cleanup();
	}
});
