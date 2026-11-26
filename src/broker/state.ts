import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { DEFAULT_PORT } from "./protocol.js";

export interface BrokerState {
	port: number;
	pid: number;
	protocol: number;
	/** The release the broker belongs to; empty for one from before releases had numbers. */
	version: string;
	startedAt: string;
}

/** The name the project had before it was called Keywright. */
const FORMER_NAME = "motion-" + "bridge";

/** The per-user directory for a product name, by the platform's convention. */
function userDir(name: string, env: NodeJS.ProcessEnv): string {
	if (process.platform === "win32") {
		return join(env.APPDATA ?? join(homedir(), "AppData", "Roaming"), name);
	}
	if (process.platform === "darwin") {
		return join(homedir(), "Library", "Application Support", name);
	}
	return join(env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), name);
}

/**
 * Per-user directory holding the secret, the broker state file and plugin credentials.
 * A directory left by the project under its former name is taken over once, so that a
 * pairing made before the rename still works.
 */
export function stateDir(env: NodeJS.ProcessEnv = process.env): string {
	if (env.KEYWRIGHT_HOME) return env.KEYWRIGHT_HOME;
	const dir = userDir("keywright", env);
	const former = userDir(FORMER_NAME, env);
	if (!existsSync(dir) && existsSync(former)) {
		try {
			renameSync(former, dir);
		} catch {
			// Another process took it over first, or it cannot be moved: start afresh.
		}
	}
	return dir;
}

export function configuredPort(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.KEYWRIGHT_PORT;
	if (raw === undefined || raw === "") return DEFAULT_PORT;
	const port = Number(raw);
	if (!Number.isInteger(port) || port < 1024 || port > 65535) {
		throw new Error(`KEYWRIGHT_PORT must be an integer from 1024 to 65535, got "${raw}"`);
	}
	return port;
}

/**
 * On macOS and Linux, makes sure a file or folder of Keywright's state belongs to this
 * user and is closed to others, as one restored from a backup or copied in may not be.
 * Windows keeps a user's folder closed to others by its own permissions.
 */
function guard(path: string, mode: number): void {
	if (process.platform === "win32") return;
	const info = statSync(path);
	if (typeof process.getuid === "function" && info.uid !== process.getuid()) {
		throw new Error(`${path} belongs to another user. Delete it, or set KEYWRIGHT_HOME to a folder of your own.`);
	}
	if ((info.mode & 0o077) !== 0) chmodSync(path, mode);
}

function ensureDir(dir: string): void {
	mkdirSync(dir, { recursive: true, mode: 0o700 });
	guard(dir, 0o700);
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
	guard(file, 0o600);
	for (let attempt = 0; attempt < 50; attempt++) {
		const text = readFileSync(file, "utf8").trim();
		if (/^[0-9a-f]{64}$/.test(text)) return Buffer.from(text, "hex");
		Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
	}
	throw new Error(`Secret file ${file} is malformed. Delete it to generate a new one.`);
}

/**
 * Replaces the per-user secret with a new one and drops every credential issued under
 * the old one. Every Studio window must then pair again. The broker must not be running:
 * it holds the old secret in memory.
 */
export function rotateSecret(dir: string): Buffer {
	rmSync(join(dir, "credentials.json"), { force: true });
	rmSync(join(dir, "secret"), { force: true });
	return loadOrCreateSecret(dir);
}

export function readBrokerState(dir: string): BrokerState | undefined {
	try {
		const parsed = JSON.parse(readFileSync(join(dir, "broker.json"), "utf8")) as Partial<BrokerState>;
		if (typeof parsed.port === "number" && typeof parsed.pid === "number") {
			return {
				port: parsed.port,
				pid: parsed.pid,
				protocol: typeof parsed.protocol === "number" ? parsed.protocol : 0,
				version: typeof parsed.version === "string" ? parsed.version : "",
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
		// One belonging to another user is not used: every plugin then pairs again.
		guard(join(dir, "credentials.json"), 0o600);
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
