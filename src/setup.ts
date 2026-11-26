// What `keywright setup` prints after installing the plugin: how to add Keywright to the
// common AI apps, with this copy's real path filled in, and what only the person can do.
// Written for a person and for an agent doing the setup for them alike.

import type { Installed } from "./install.js";

export interface SetupFacts {
	version: string;
	/** The file the AI app is to run with node: keywright.mjs, or dist/src/cli.js. */
	entry: string;
	installed: Installed;
	/** True inside WSL, where an AI app on the Windows side starts this file through wsl.exe. */
	wsl: boolean;
	/** The full path of the node running now, for wsl.exe, which may not find node on its own. */
	node: string;
}

/** A path as a quoted string that JSON and TOML both read back as the same path. */
const quoted = (path: string) => JSON.stringify(path);

export function setupGuide(facts: SetupFacts): string {
	const { version, entry, installed } = facts;
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
		"2. Add Keywright to the AI app. The app starts it with:",
		`   node ${quoted(entry)}`,
		"",
		"   Claude Code, in a terminal:",
		`     claude mcp add keywright -- node ${quoted(entry)}`,
		"",
		"   Codex, in ~/.codex/config.toml:",
		"     [mcp_servers.keywright]",
		'     command = "node"',
		`     args = [${quoted(entry)}]`,
		"",
		"   Claude Desktop, Cursor and most other apps, in their MCP settings (JSON):",
		`     { "mcpServers": { "keywright": { "command": "node", "args": [${quoted(entry)}] } } }`,
		...(facts.wsl
			? [
					"",
					"   This copy is inside WSL. An app that runs on Windows, such as Claude Desktop, starts it through",
					"   wsl.exe, with the full path to node inside WSL:",
					`     { "mcpServers": { "keywright": { "command": "wsl.exe", "args": [${quoted(facts.node)}, ${quoted(entry)}] } } }`,
				]
			: []),
		"",
		"3. What the person does",
		"   a. Restart the AI app, or reconnect its MCP servers, so that it starts Keywright.",
		"   b. In Roblox Studio, open the place to work in, click Keywright on the Plugins tab, and click",
		"      Turn on agent access. Access is off until a person turns it on, separately for each place.",
		"   c. The first time only, the panel shows a pairing code that works once within 5 minutes.",
		'      Tell the AI app "Pair Keywright with code <the code>", or run:',
		`      node ${quoted(entry)} pair <the code>`,
		"",
		"Then ask for an animation, for example: make a 1-second looping walk cycle for the rig in my place.",
	];
	return `${lines.join("\n")}\n`;
}
