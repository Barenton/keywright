// Partial E9 check, run from WSL: can a Windows process reach a broker that listens on
// 127.0.0.1 inside WSL, and complete the authenticated handshake over that link?
//
// It starts a broker in a throwaway state directory, then runs Windows node.exe with a
// small client that connects to ws://127.0.0.1:<port> from the Windows side. This is the
// same network path the Studio plugin uses when Studio runs on Windows and the broker in
// WSL. It does not exercise Studio itself. It changes no network setting.
//
// Usage: npm run build && node scripts/wsl-loopback-check.mjs

import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Broker } from "../dist/src/broker.js";
import { loadOrCreateSecret } from "../dist/src/state.js";

if (process.platform !== "linux" || !/microsoft/i.test(readFileSync("/proc/version", "utf8"))) {
	console.error("Run this inside WSL.");
	process.exit(2);
}

const execFileAsync = promisify(execFile);

const freePort = () =>
	new Promise((resolve) => {
		const server = createServer();
		server.listen(0, "127.0.0.1", () => {
			const { port } = server.address();
			server.close(() => resolve(port));
		});
	});

// Runs on the Windows side. Uses only Node built-ins: the global WebSocket and node:crypto.
const windowsClient = (port, secretHex) => `
const { createHmac, randomBytes } = require("node:crypto");
const key = Buffer.from("${secretHex}", "hex");
const hmac = (text) => createHmac("sha256", key).update(text).digest("hex");
const started = Date.now();
let attempts = 0;
const done = (result) => { console.log(JSON.stringify({ ...result, attempts, ms: Date.now() - started, node: process.version })); process.exit(0); };
setTimeout(() => done({ ok: false, stage: "timeout" }), 15000);
// WSL forwards a new loopback listener to Windows only after a short delay, so retry.
function attempt() {
  attempts += 1;
  const cn = randomBytes(16).toString("hex");
  const ws = new WebSocket("ws://127.0.0.1:${port}/v1");
  let sn, connected = false;
  ws.onerror = () => { if (!connected) return setTimeout(attempt, 250); done({ ok: false, stage: "error after connect" }); };
  ws.onopen = () => { connected = true; ws.send(JSON.stringify({ t: "hello", v: 1, role: "adapter", key: "user", nonce: cn })); };
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.t === "denied") return done({ ok: false, stage: "denied", code: message.code });
    if (message.t === "challenge") {
      sn = message.nonce;
      if (message.proof !== hmac("mb1|broker|adapter|" + cn + "|" + sn)) return done({ ok: false, stage: "broker proof mismatch" });
      return ws.send(JSON.stringify({ t: "auth", proof: hmac("mb1|client|adapter|" + cn + "|" + sn) }));
    }
    if (message.t === "ready") return ws.send(JSON.stringify({ t: "req", id: "w1", method: "broker.status" }));
    if (message.t === "res") return done({ ok: message.ok === true, stage: "request answered", status: message.result });
  };
}
attempt();
`;

const home = mkdtempSync(join(tmpdir(), "motion-bridge-wsl-"));
const port = await freePort();
const broker = new Broker({ home, port });
await broker.start();
let output = "";
try {
	const secret = loadOrCreateSecret(home).toString("hex");
	// Asynchronous on purpose: the broker runs in this process and must keep serving.
	output = (await execFileAsync("node.exe", ["-e", windowsClient(port, secret)], { cwd: "/mnt/c", encoding: "utf8", timeout: 30_000 })).stdout;
} catch (error) {
	output = JSON.stringify({ ok: false, stage: "could not run node.exe", error: String(error.message ?? error) });
} finally {
	await broker.stop();
}
const brokerLog = readFileSync(join(home, "broker.log"), "utf8").trim().split("\n");
rmSync(home, { recursive: true, force: true });

const networking = (() => {
	try {
		return execFileSync("wslinfo", ["--networking-mode"], { encoding: "utf8" }).trim();
	} catch {
		return "unknown";
	}
})();
const windowsClientResult = JSON.parse(output.trim().split("\n").pop());
const result = {
	wsl_networking_mode: networking,
	broker_bind: `127.0.0.1:${port} (inside WSL)`,
	windows_client: windowsClientResult,
	// On failure, what the broker saw tells a blocked route apart from a refused request.
	broker_log: windowsClientResult.ok ? undefined : brokerLog,
};
console.log(JSON.stringify(result, null, 2));
process.exit(result.windows_client.ok ? 0 : 1);
