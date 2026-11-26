#!/usr/bin/env node
import { dirname, join, resolve } from "node:path";
import { runAdapter } from "./mcp/adapter.js";
import { isValidPairingCode } from "./broker/auth.js";
import { Broker } from "./broker/broker.js";
import { ensureBroker, PORT_TAKEN_EXIT, stopBroker } from "./broker/launcher.js";
import { BridgeError } from "./broker/protocol.js";
import { configuredPort, readBrokerState, rotateSecret, stateDir } from "./broker/state.js";
import { builtPlugin, installPlugin, robloxFolder, thisMachine, type Installed } from "./install.js";
import { cliPath, command as howToRun, viaNpx } from "./layout.js";
import { setupGuide } from "./setup.js";
import { VERSION } from "./version.js";

const USAGE = `Keywright v${VERSION}

Usage: ${howToRun()} [command]

  (no command)   Run the MCP adapter on stdio. This is what MCP clients start.
  broker         Run the local broker in the foreground.
  status         Start the broker if needed and print its state.
  pair <code>    Register the one-time pairing code shown in the Studio plugin panel.
  rotate         Replace the secret. Every Studio window must then pair again.
  setup [--folder <path>]
                 Install the plugin, then print how to add Keywright to an AI app,
                 with this copy's path filled in, and what is left for the person.
  install-plugin [--folder <path>]
                 Copy the plugin built from this copy of Keywright into Studio's
                 plugins folder, replacing an older one.
  version        Print the version.

Environment:
  KEYWRIGHT_PORT   Loopback port (default 47318).
  KEYWRIGHT_HOME   Directory for the secret, state file and log.`;

async function runBroker(): Promise<number> {
	const home = stateDir();
	const port = configuredPort();
	const idle = Number(process.env.KEYWRIGHT_IDLE_EXIT_MS);
	const broker = new Broker({
		home,
		port,
		idleExitMs: Number.isFinite(idle) && idle > 0 ? idle : undefined,
		onIdle: () => void shutdown(),
		onShutdown: () => void shutdown(),
	});
	const shutdown = async () => {
		await broker.stop();
		process.exit(0);
	};
	try {
		await broker.start();
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "EADDRINUSE") {
			// Another broker won the race, or a foreign program holds the port. Adapters tell which by handshake.
			process.stderr.write(`Port ${port} is already in use.\n`);
			return PORT_TAKEN_EXIT;
		}
		throw error;
	}
	process.on("SIGINT", () => void shutdown());
	process.on("SIGTERM", () => void shutdown());
	return await new Promise<number>(() => {});
}

/**
 * Replaces the secret. A running broker holds the old one in memory, so it is stopped
 * first; the next adapter to need a broker starts one with the new secret.
 */
async function rotate(): Promise<number> {
	const home = stateDir();
	const port = configuredPort();
	if (!(await stopBroker(home, port))) {
		process.stderr.write("The broker did not stop, so the secret was left as it is.\n");
		return 1;
	}
	// A broker started earlier with another KEYWRIGHT_PORT is stopped too: it holds the old
	// secret in memory and would go on accepting it. Only one of ours is stopped there.
	const recorded = readBrokerState(home);
	if (recorded && recorded.port !== port) {
		let stopped = true;
		try {
			stopped = await stopBroker(home, recorded.port);
		} catch {
			// Not a broker of ours on that port: nothing of ours to stop.
		}
		if (!stopped) {
			process.stderr.write(`The broker on port ${recorded.port} did not stop, so the secret was left as it is.\n`);
			return 1;
		}
	}
	rotateSecret(home);
	process.stdout.write("The secret was replaced. Every Studio window must pair again: turn agent access off and on in the Keywright panel to get a new code.\n");
	return 0;
}

/** Installs the plugin into the folder given with --folder, or Studio's own; undefined if the arguments are wrong. */
function installFrom(command: string, args: string[]): Installed | undefined {
	let folder: string | undefined;
	if (args.length > 0) {
		if (args[0] !== "--folder" || args.length !== 2) {
			process.stderr.write(`Usage: ${howToRun()} ${command} [--folder <path>]\n`);
			return undefined;
		}
		folder = resolve(args[1] as string);
	}
	const target = folder ?? join(robloxFolder(thisMachine()), "Plugins");
	return installPlugin(builtPlugin(), target);
}

function setup(args: string[]): number {
	const installed = installFrom("setup", args);
	if (!installed) return 2;
	const machine = thisMachine();
	// Started through npx, the app is told to start it the same way. npx sits beside node.
	const npx = join(dirname(process.execPath), process.platform === "win32" ? "npx.cmd" : "npx");
	const launch = viaNpx() ? { command: "npx", args: ["-y", "keywright"], fullPath: npx } : undefined;
	process.stdout.write(
		setupGuide({ version: VERSION, entry: cliPath(), launch, installed, wsl: machine.wsl, distro: machine.env.WSL_DISTRO_NAME, node: process.execPath, platform: process.platform }),
	);
	return 0;
}

function install(args: string[]): number {
	const installed = installFrom("install-plugin", args);
	if (!installed) return 2;
	process.stdout.write(`Installed the Keywright plugin (v${VERSION}) at ${installed.path}.\nStudio loads it on its own; if the Keywright button does not appear or update, restart Studio.\n`);
	if (installed.replaced) process.stdout.write(`It replaces ${installed.replaced}, the copy saved from Studio.\n`);
	if (installed.others.length > 0) {
		process.stdout.write(`\nThis folder also has ${installed.others.join(", ")}. Studio loads every plugin in it, so remove ${installed.others.length === 1 ? "that file" : "those files"} to run only this one.\n`);
	}
	return 0;
}

async function main(argv: string[]): Promise<number> {
	const [command, ...rest] = argv;
	if (command === undefined || command === "serve") {
		await runAdapter({ home: stateDir(), port: configuredPort() });
		return await new Promise<number>(() => {});
	}
	if (command === "broker") return runBroker();
	if (command === "install-plugin") return install(rest);
	if (command === "setup") return setup(rest);
	if (command === "version" || command === "--version") {
		process.stdout.write(`${VERSION}\n`);
		return 0;
	}
	if (command === "rotate") return rotate();
	if (command === "status" || command === "pair") {
		const client = await ensureBroker({ home: stateDir(), port: configuredPort() });
		try {
			if (command === "status") {
				process.stdout.write(`${JSON.stringify(await client.request("broker.status"))}\n`);
				return 0;
			}
			const code = rest[0];
			if (code === undefined || !isValidPairingCode(code)) {
				process.stderr.write(`Give the pairing code shown in the Studio plugin panel: ${howToRun()} pair <code>\n`);
				return 2;
			}
			await client.request("broker.pair_register", { code });
			process.stdout.write("Pairing code registered. It is valid for 5 minutes and one use.\n");
			return 0;
		} finally {
			client.close();
		}
	}
	process.stderr.write(`${USAGE}\n`);
	return command === "help" || command === "--help" ? 0 : 2;
}

main(process.argv.slice(2)).then(
	(code) => process.exit(code),
	(error: unknown) => {
		const text = error instanceof BridgeError ? `${error.code}: ${error.message}${error.hint ? `\n${error.hint}` : ""}` : String(error);
		process.stderr.write(`${text}\n`);
		process.exit(1);
	},
);
