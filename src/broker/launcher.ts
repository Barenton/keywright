import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { BrokerAbsentError, connectAdapter, ForeignListenerError, type BrokerClient } from "./client.js";
import { BridgeError } from "./protocol.js";
import { loadOrCreateSecret, readBrokerState } from "./state.js";

const START_WAIT_MS = 10_000;
const RETRY_INTERVAL_MS = 100;

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
		"Close that program, or set KEYWRIGHT_PORT to a free port and set the same port in the Studio plugin panel.",
	);
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
 */
export async function ensureBroker(options: EnsureBrokerOptions): Promise<BrokerClient> {
	const secret = loadOrCreateSecret(options.home);

	// A broker recorded in the state file may run on a different port than the one configured now.
	const recorded = readBrokerState(options.home);
	if (recorded && recorded.port !== options.port) {
		try {
			return await connectAdapter(recorded.port, secret);
		} catch {
			// Stale state file. Fall through to the configured port.
		}
	}

	let spawned = false;
	const deadline = Date.now() + START_WAIT_MS;
	for (;;) {
		try {
			return await connectAdapter(options.port, secret);
		} catch (error) {
			if (error instanceof ForeignListenerError) throw portConflict(options.port);
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
