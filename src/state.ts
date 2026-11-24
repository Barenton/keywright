import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { DEFAULT_PORT } from "./protocol.js";

export interface BrokerState {
	port: number;
	pid: number;
	protocol: number;
	startedAt: string;
}

/** Per-user directory holding the secret, the broker state file and plugin credentials. */
export function stateDir(env: NodeJS.ProcessEnv = process.env): string {
	if (env.MOTION_BRIDGE_HOME) return env.MOTION_BRIDGE_HOME;
	if (process.platform === "win32") {
		return join(env.APPDATA ?? join(homedir(), "AppData", "Roaming"), "motion-bridge");
	}
	if (process.platform === "darwin") {
		return join(homedir(), "Library", "Application Support", "motion-bridge");
	}
	return join(env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "motion-bridge");
}

export function configuredPort(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.MOTION_BRIDGE_PORT;
	if (raw === undefined || raw === "") return DEFAULT_PORT;
	const port = Number(raw);
	if (!Number.isInteger(port) || port < 1024 || port > 65535) {
		throw new Error(`MOTION_BRIDGE_PORT must be an integer from 1024 to 65535, got "${raw}"`);
	}
	return port;
}

function ensureDir(dir: string): void {
	mkdirSync(dir, { recursive: true, mode: 0o700 });
}

/**
 * Returns the per-user secret, creating it on first use. Creation is exclusive, so
 * processes that start together all end up with the same secret.
 */
export function loadOrCreateSecret(dir: string): Buffer {
	ensureDir(dir);
	const file = join(dir, "secret");
	try {
		writeFileSync(file, randomBytes(32).toString("hex"), { flag: "wx", mode: 0o600 });
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
	}
	for (let attempt = 0; attempt < 50; attempt++) {
		const text = readFileSync(file, "utf8").trim();
		if (/^[0-9a-f]{64}$/.test(text)) return Buffer.from(text, "hex");
		Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
	}
	throw new Error(`Secret file ${file} is malformed. Delete it to generate a new one.`);
}

export function readBrokerState(dir: string): BrokerState | undefined {
	try {
		const parsed = JSON.parse(readFileSync(join(dir, "broker.json"), "utf8")) as Partial<BrokerState>;
		if (typeof parsed.port === "number" && typeof parsed.pid === "number") {
			return {
				port: parsed.port,
				pid: parsed.pid,
				protocol: typeof parsed.protocol === "number" ? parsed.protocol : 0,
				startedAt: typeof parsed.startedAt === "string" ? parsed.startedAt : "",
			};
		}
	} catch {
		// Missing or unreadable state is the same as no broker.
	}
	return undefined;
}

function writeAtomic(file: string, text: string): void {
	const temp = `${file}.${process.pid}.tmp`;
	writeFileSync(temp, text, { mode: 0o600 });
	renameSync(temp, file);
}

export function writeBrokerState(dir: string, state: BrokerState): void {
	ensureDir(dir);
	writeAtomic(join(dir, "broker.json"), JSON.stringify(state));
}

/** Removes the state file only if it still describes this process. */
export function removeBrokerState(dir: string, pid: number): void {
	if (readBrokerState(dir)?.pid === pid) rmSync(join(dir, "broker.json"), { force: true });
}

export type CredentialStore = Record<string, { key: string; createdAt: string }>;

/**
 * Credentials are bound to the secret they were issued under. After the secret is
 * rotated the fingerprint no longer matches and every stored credential is dropped,
 * so plugins must pair again.
 */
export function loadCredentials(dir: string, secretFingerprint: string): CredentialStore {
	try {
		const parsed = JSON.parse(readFileSync(join(dir, "credentials.json"), "utf8")) as {
			secret?: string;
			credentials?: CredentialStore;
		};
		if (parsed.secret === secretFingerprint && parsed.credentials) return parsed.credentials;
	} catch {
		// Missing or unreadable file: no credentials.
	}
	return {};
}

export function saveCredentials(dir: string, secretFingerprint: string, store: CredentialStore): void {
	ensureDir(dir);
	writeAtomic(join(dir, "credentials.json"), JSON.stringify({ secret: secretFingerprint, credentials: store }));
}
