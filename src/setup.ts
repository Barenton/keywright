// What `keywright setup` prints after installing the plugin: how to add Keywright to the
// common AI apps, with this copy's real path filled in, and what only the person can do.
// Written for a person and for an agent doing the setup for them alike.

import { posix } from "node:path";
import { type App, entryFor, type Outcome, windowsFallback } from "./apps.js";
import type { Installed } from "./install.js";

/** How an AI app starts Keywright: node with this copy's file, or npx with the package's name. */
export interface Launch {
	command: string;
	args: string[];
	/** The full path of the command, for wsl.exe and for apps that cannot find it on their own. */
	fullPath: string;
}

export interface SetupFacts {
	version: string;
	/** The file the AI app is to run with node: keywright.mjs, or dist/src/cli.js. */
	entry: string;
	/** Set when run through npx: the app then starts Keywright the same way, not by a path in npm's cache. */
	launch?: Launch;
	installed: Installed;
	/** True inside WSL, where an AI app on the Windows side starts this file through wsl.exe. */
	wsl: boolean;
	/** Inside WSL, the distribution this copy is in, so that wsl.exe starts it in that one. */
	distro?: string;
	/** The full path of the node running now: for wsl.exe, and for apps that can't find node. */
	node: string;
	/** Where setup runs, which decides how a terminal command is quoted: PowerShell on Windows. */
	platform: NodeJS.Platform;
	/** The AI apps found here, and what was done for each one the person said yes to. */
	apps?: { found: App[]; results: Array<{ app: App; outcome: Outcome }> };
}

/** A value as a quoted string that JSON and TOML both read back exactly. */
const quoted = (value: string) => JSON.stringify(value);

/** A value as one argument of a terminal command: PowerShell's quoting on Windows, a POSIX shell's elsewhere. */
export function shellArgument(value: string, platform: NodeJS.Platform): string {
	// Plain as it is where nothing in it needs quoting, so it works in Command Prompt too.
	if (/^[A-Za-z0-9_./:=@%+-]+$/.test(value)) return value;
	if (platform === "win32") return `'${value.replace(/'/g, "''")}'`;
	return `'${value.replace(/'/g, `'\\''`)}'`;
}

export function setupGuide(facts: SetupFacts): string {
	const { version, installed } = facts;
	const launch: Launch = facts.launch ?? { command: "node", args: [facts.entry], fullPath: facts.node };
	const shell = (value: string) => shellArgument(value, facts.platform);
	const line = [launch.command, ...launch.args].map((part, index) => (index === 0 ? part : shell(part))).join(" ");
	// What an app runs, and on Windows the way out for an app that can't start npx.
	const entry = entryFor(launch, facts.platform);
	const fallback = facts.platform === "win32" ? windowsFallback(entry) : undefined;
	const appLine = [entry.command, ...entry.args].map((part, index) => (index === 0 ? part : shell(part))).join(" ");
	const args = entry.args.map(quoted).join(", ");
	// What setup did in each app the person said yes to, and the apps it found but left.
	const results = facts.apps?.results ?? [];
	const done = new Set(results.map((result) => result.app.name));
	const left = (facts.apps?.found ?? []).filter((app) => !done.has(app.name));
	const reported = results.map(({ app, outcome }) => {
		if (outcome.status === "skipped") return `   Not added to ${app.label}: ${outcome.reason}`;
		if (outcome.status === "unchanged") return `   ${app.label} already starts Keywright.${outcome.skill ? ` Its skill is brought up to date at ${outcome.skill}.` : ""}`;
		const where = app.file ? ` (${app.file})` : "";
		const kept = outcome.backup ? " The file as it was is kept beside it, ending in .before-keywright." : "";
		const skill = outcome.skill ? ` Its skill is installed at ${outcome.skill}.` : "";
		return `   ${outcome.status === "added" ? "Added Keywright to" : "Brought Keywright up to date in"} ${app.label}${where}.${kept}${skill}`;
	});
	// Started from Windows, wsl.exe --exec gives no login shell, so a node installed with nvm
	// is not on PATH. npx finds node through PATH, so it is run with node's folder put there.
	const throughPath = launch.command === "node" ? [] : ["/usr/bin/env", `PATH=${posix.dirname(facts.node)}:/usr/local/bin:/usr/bin:/bin`];
	const wslArgs = [...(facts.distro ? ["-d", facts.distro] : []), "--exec", ...throughPath, launch.fullPath, ...launch.args];
	const lines = [
		`Keywright v${version} is set up.`,
		"",
		"1. The plugin",
		`   Installed at ${installed.path}.`,
		...(installed.replaced ? [`   It replaces ${installed.replaced}, the copy saved from Studio.`] : []),
		...(installed.others.length > 0
			? [`   The folder also has ${installed.others.join(", ")}. Studio loads every plugin there, so remove ${installed.others.length === 1 ? "it" : "them"} to run only this one.`]
			: []),
		"   Studio loads it on its own. If the Keywright button does not appear on the Plugins tab, restart Studio.",
		"",
		"2. Add Keywright to the AI app",
		...reported,
		...(left.length > 0
			? [
					`   Found here: ${left.map((app) => app.label).join(", ")}. Setup can add Keywright to ${left.length === 1 ? "it" : "them"}: ask the person, then run`,
					`     ${line} setup --add-to ${left.map((app) => app.name).join(",")}`,
				]
			: []),
		...(reported.length > 0 || left.length > 0 ? [""] : []),
		`   To add it by hand, the app starts it with: ${appLine}`,
		"",
		"   Claude Code, in a terminal (for every project):",
		`     claude mcp add --scope user keywright -- ${appLine}`,
		"",
		"   Codex, in ~/.codex/config.toml:",
		"     [mcp_servers.keywright]",
		`     command = ${quoted(entry.command)}`,
		`     args = [${args}]`,
		"",
		"   Claude Desktop, Cursor and most other apps, in their MCP settings (JSON):",
		`     { "mcpServers": { "keywright": { "command": ${quoted(entry.command)}, "args": [${args}] } } }`,
		// Not npx.cmd on Windows: an app that can't start npx can't run a .cmd file either.
		...(fallback
			? [
					"",
					"   If an app on Windows says it can't start Keywright, give it npx through cmd instead:",
					`     { "mcpServers": { "keywright": { "command": "cmd", "args": [${fallback.args.map(quoted).join(", ")}] } } }`,
				]
			: ["", `   If an app cannot find ${launch.command}, use its full path in place of "${launch.command}": ${launch.fullPath}`]),
		...(facts.wsl
			? [
					"",
					"   This copy is inside WSL. An app that runs on Windows starts it through wsl.exe, in this",
					`   distribution${facts.distro ? ` (${facts.distro})` : ""}, with the full path to ${launch.command} inside WSL:`,
					`     { "mcpServers": { "keywright": { "command": "wsl.exe", "args": [${wslArgs.map(quoted).join(", ")}] } } }`,
					"   or, for Codex on Windows, in its config.toml:",
					"     [mcp_servers.keywright]",
					'     command = "wsl.exe"',
					`     args = [${wslArgs.map(quoted).join(", ")}]`,
				]
			: []),
		"",
		"3. What the person does",
		"   a. Restart the AI app, or reconnect its MCP servers, so that it starts Keywright.",
		"   b. In Roblox Studio, open the place to work in, click Keywright on the Plugins tab, and click",
		"      Turn on agent access. Access is off until a person turns it on, separately for each place.",
		"   c. The first time only, the panel shows a pairing code that works once within 5 minutes.",
		'      Tell the AI app "Pair Keywright with code <the code>", or run:',
		`      ${line} pair <the code>`,
		"",
		"Then ask for an animation, for example: make a 1-second looping walk cycle for the rig in my place.",
	];
	return `${lines.join("\n")}\n`;
}
