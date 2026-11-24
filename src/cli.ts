#!/usr/bin/env node
import { runAdapter } from "./adapter.js";
import { isValidPairingCode } from "./auth.js";
import { Broker } from "./broker.js";
import { ensureBroker } from "./launcher.js";
import { BridgeError } from "./protocol.js";
import { configuredPort, stateDir } from "./state.js";

const USAGE = `Usage: motion-bridge [command]

  (no command)   Run the MCP adapter on stdio. This is what MCP clients start.
  broker         Run the local broker in the foreground.
  status         Start the broker if needed and print its state.
  pair <code>    Register the one-time pairing code shown in the Studio plugin panel.

Environment:
  MOTION_BRIDGE_PORT   Loopback port (default 47318).
  MOTION_BRIDGE_HOME   Directory for the secret, state file and log.`;

async function runBroker(): Promise<number> {
	const home = stateDir();
	const port = configuredPort();
	const idle = Number(process.env.MOTION_BRIDGE_IDLE_EXIT_MS);
	const broker = new Broker({
		home,
		port,
		idleExitMs: Number.isFinite(idle) && idle > 0 ? idle : undefined,
		onIdle: () => void shutdown(),
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
			return 3;
		}
		throw error;
	}
	process.on("SIGINT", () => void shutdown());
	process.on("SIGTERM", () => void shutdown());
	return await new Promise<number>(() => {});
}

async function main(argv: string[]): Promise<number> {
	const [command, ...rest] = argv;
	if (command === undefined || command === "serve") {
		await runAdapter({ home: stateDir(), port: configuredPort() });
		return await new Promise<number>(() => {});
	}
	if (command === "broker") return runBroker();
	if (command === "status" || command === "pair") {
		const client = await ensureBroker({ home: stateDir(), port: configuredPort() });
		try {
			if (command === "status") {
				process.stdout.write(`${JSON.stringify(await client.request("broker.status"))}\n`);
				return 0;
			}
			const code = rest[0];
			if (code === undefined || !isValidPairingCode(code)) {
				process.stderr.write("Give the pairing code shown in the Studio plugin panel: motion-bridge pair <code>\n");
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
