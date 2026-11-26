import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { VERSION } from "../version.js";
import { BrokerAbsentError, connectAdapter, DeniedError, ForeignListenerError, type BrokerClient } from "./client.js";
import { BridgeError } from "./protocol.js";
import { loadOrCreateSecret, readBrokerState } from "./state.js";

const START_WAIT_MS = 10_000;
const RETRY_INTERVAL_MS = 100;
const STOP_WAIT_MS = 5000;

export interface EnsureBrokerOptions {
	home: string;
	port: number;
	/** Set to false to only connect to a broker that is already running. */
	autoStart?: boolean;
	env?: NodeJS.ProcessEnv;
}

function portConflict(port: number): BridgeError {
	return new BridgeError(
		"BROKER_PORT_CONFLICT",
		`Port ${port} is held by another program that is not the Keywright broker.`,
		"Close that program, then try again.",
	);
}

/** A broker that is ours but speaks another protocol, so it cannot be asked anything. */
function otherProtocol(options: EnsureBrokerOptions, port: number): BridgeError {
	const recorded = readBrokerState(options.home);
	const which = recorded?.port === port ? ` (process ${recorded.pid})` : "";
	return new BridgeError(
		"BROKER_UNAVAILABLE",
		`The Keywright broker on port ${port}${which} is from a version that cannot work with this adapter (${VERSION}).`,
		`Stop that process, or restart the computer, and try again. Then make sure the Studio plugin is the same version: run npm run install:plugin in the keywright folder.`,
	);
}

/**
 * Orders versions like 0.2.0 and 0.10.1 by their numbers. A pre-release (0.2.0-beta.1)
 * comes before its release; anything that is not a version comes before everything.
 */
export function compareVersions(a: string, b: string): number {
	const parse = (version: string) => /^(\d+)\.(\d+)\.(\d+)(-.+)?$/.exec(version);
	const x = parse(a);
	const y = parse(b);
	if (!x || !y) return (x ? 1 : 0) - (y ? 1 : 0);
	for (let index = 1; index <= 3; index += 1) {
		const difference = Number(x[index]) - Number(y[index]);
		if (difference !== 0) return Math.sign(difference);
	}
	if (x[4] === y[4]) return 0;
	if (x[4] === undefined) return 1;
	if (y[4] === undefined) return -1;
	return x[4] < y[4] ? -1 : 1;
}

/**
 * Stops this user's broker on a port, if one is running, and waits until it has gone.
 * Returns false if it is still there after a few seconds. Anything else holding the port
 * is not ours to stop and fails with BROKER_PORT_CONFLICT.
 */
export async function stopBroker(home: string, port: number): Promise<boolean> {
	const secret = loadOrCreateSecret(home);
	try {
		const client = await connectAdapter(port, secret);
		try {
			await client.request("broker.shutdown");
		} catch (error) {
			// A broker started by an older version does not know how to be asked. It has
			// proved it holds this user's secret, so it is ours: stop it by its process id.
			if (!(error instanceof BridgeError) || error.code !== "INVALID_ARGUMENT") throw error;
			const { pid } = (await client.request("broker.status")) as { pid: number };
			process.kill(pid, "SIGTERM");
		}
		client.close();
	} catch (error) {
		if (error instanceof ForeignListenerError) throw portConflict(port);
		// No broker running is fine.
		if (!(error instanceof BrokerAbsentError)) throw error;
	}
	const deadline = Date.now() + STOP_WAIT_MS;
	for (;;) {
		try {
			(await connectAdapter(port, secret)).close();
		} catch (error) {
			if (error instanceof BrokerAbsentError) return true;
			if (error instanceof ForeignListenerError) throw portConflict(port);
			// A broker caught in the middle of stopping: not gone yet, look again.
		}
		if (Date.now() > deadline) return false;
		await sleep(RETRY_INTERVAL_MS);
	}
}

/** The release of the broker a client is connected to. A broker from before releases had numbers says none. */
async function brokerVersion(client: BrokerClient): Promise<string> {
	const status = (await client.request("broker.status")) as { version?: unknown };
	return typeof status.version === "string" ? status.version : "";
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function spawnBroker(options: EnsureBrokerOptions): void {
	const cli = fileURLToPath(new URL("../cli.js", import.meta.url));
	const child = spawn(process.execPath, [cli, "broker"], {
		detached: true,
		stdio: "ignore",
		windowsHide: true,
		env: {
			...(options.env ?? process.env),
			KEYWRIGHT_HOME: options.home,
			KEYWRIGHT_PORT: String(options.port),
		},
	});
	child.unref();
}

/**
 * Returns an authenticated connection to this user's broker, starting one if none is
 * running. An occupied port is never assumed to be ours: the listener must pass the
 * handshake, otherwise this fails with BROKER_PORT_CONFLICT and sends it nothing more.
 *
 * A broker from an older release, still running after an update, is stopped and a new
 * one started in its place. Only an older one: two adapters of different versions never
 * take turns replacing each other's broker.
 */
export async function ensureBroker(options: EnsureBrokerOptions): Promise<BrokerClient> {
	const secret = loadOrCreateSecret(options.home);

	// A broker recorded in the state file may run on a different port than the one configured now.
	const replaceable = options.autoStart !== false;
	// Connected to a broker: kept if it is no older than this adapter, or else stopped.
	const current = async (client: BrokerClient, port: number): Promise<BrokerClient | undefined> => {
		if (!replaceable || compareVersions(await brokerVersion(client), VERSION) >= 0) return client;
		client.close();
		if (!(await stopBroker(options.home, port))) {
			throw new BridgeError(
				"BROKER_UNAVAILABLE",
				`An older Keywright broker is running on port ${port} and did not stop when asked.`,
				"Stop it, or restart the computer, and try again.",
			);
		}
		return undefined;
	};

	const recorded = readBrokerState(options.home);
	if (recorded && recorded.port !== options.port) {
		let client: BrokerClient | undefined;
		try {
			client = await connectAdapter(recorded.port, secret);
		} catch {
			// Stale state file. Fall through to the configured port.
		}
		if (client) {
			const kept = await current(client, recorded.port);
			if (kept) return kept;
		}
	}

	let spawned = false;
	const deadline = Date.now() + START_WAIT_MS;
	for (;;) {
		try {
			const kept = await current(await connectAdapter(options.port, secret), options.port);
			if (kept) return kept;
		} catch (error) {
			if (error instanceof ForeignListenerError) throw portConflict(options.port);
			if (error instanceof DeniedError && error.code === "version") throw otherProtocol(options, options.port);
			if (!(error instanceof BrokerAbsentError)) throw error;
		}
		if (options.autoStart === false) {
			throw new BridgeError("BROKER_UNAVAILABLE", `No broker is running on port ${options.port}.`);
		}
		if (!spawned) {
			spawnBroker(options);
			spawned = true;
		}
		if (Date.now() > deadline) {
			throw new BridgeError(
				"BROKER_UNAVAILABLE",
				`The broker did not start on port ${options.port}.`,
				"Run `keywright broker` in a terminal to see why it fails.",
			);
		}
		await sleep(RETRY_INTERVAL_MS);
	}
}
