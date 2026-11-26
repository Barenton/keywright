import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { setupGuide, shellArgument } from "../src/setup.js";

const facts = {
	version: "9.9.9",
	entry: "C:\\Tools\\keywright\\keywright.mjs",
	installed: { path: "C:\\Users\\me\\AppData\\Local\\Roblox\\Plugins\\Keywright.rbxm", others: [] },
	wsl: false,
	node: "C:\\Program Files\\nodejs\\node.exe",
	platform: "win32" as NodeJS.Platform,
};

test("the guide gives each app's entry with this copy's path, written so the app reads it back exactly", () => {
	const guide = setupGuide(facts);
	assert.match(guide, /^Keywright v9\.9\.9 is set up\./);
	const json = guide.split("\n").find((line) => line.includes('"mcpServers"'));
	assert.deepEqual(JSON.parse(json ?? ""), { mcpServers: { keywright: { command: "node", args: [facts.entry] } } });
	assert.match(guide, /\[mcp_servers\.keywright\]/);
	assert.ok(guide.includes(facts.node), "the full path to node, for apps that can't find it");
});

test("Claude Code is added for every project, with the path quoted for the terminal it runs in", () => {
	assert.ok(setupGuide(facts).includes(`claude mcp add --scope user keywright -- node 'C:\\Tools\\keywright\\keywright.mjs'`));
	const posix = setupGuide({ ...facts, platform: "linux", entry: "/home/me/keywright/keywright.mjs" });
	assert.ok(posix.includes("claude mcp add --scope user keywright -- node /home/me/keywright/keywright.mjs"));
});

test("a path is passed to a POSIX shell as it is, whatever it holds", { skip: process.platform === "win32" }, () => {
	for (const path of ["/opt/Team $Quarter/keywright.mjs", "/opt/it's `here`/k.mjs", "/opt/$(touch x)/k.mjs", "/plain/path.mjs"]) {
		const received = execFileSync("bash", ["--noprofile", "--norc", "-c", `printf %s ${shellArgument(path, "linux")}`], { encoding: "utf8", env: { Quarter: "Q4" } });
		assert.equal(received, path);
	}
});

test("PowerShell's quoting keeps a Windows path's single backslashes and quotes", () => {
	assert.equal(shellArgument("C:\\My Tools\\keywright.mjs", "win32"), "'C:\\My Tools\\keywright.mjs'");
	assert.equal(shellArgument("C:\\Bob's\\k.mjs", "win32"), "'C:\\Bob''s\\k.mjs'");
});

test("the guide says what only the person can do", () => {
	const guide = setupGuide(facts);
	assert.match(guide, /Restart the AI app/);
	assert.match(guide, /Turn on agent access/);
	assert.match(guide, /Pair Keywright with code/);
});

test("inside WSL, apps on Windows start this copy in its own distribution, with the full path to node", () => {
	assert.equal(setupGuide(facts).includes("wsl.exe"), false);
	const guide = setupGuide({ ...facts, platform: "linux", entry: "/home/me/keywright/keywright.mjs", wsl: true, distro: "Debian", node: "/home/me/.nvm/versions/node/v22.0.0/bin/node" });
	const args = ["-d", "Debian", "--exec", "/home/me/.nvm/versions/node/v22.0.0/bin/node", "/home/me/keywright/keywright.mjs"];
	const json = guide.split("\n").find((line) => line.includes('"wsl.exe"'));
	assert.deepEqual(JSON.parse(json ?? ""), { mcpServers: { keywright: { command: "wsl.exe", args } } });
	assert.ok(guide.includes('command = "wsl.exe"'), "and the same for Codex's config.toml");
	assert.ok(guide.includes(`args = [${args.map((arg) => JSON.stringify(arg)).join(", ")}]`));
});

test("the guide mentions other copies Studio would also load", () => {
	const guide = setupGuide({ ...facts, installed: { path: "x", others: ["Keywright (old).rbxm"] } });
	assert.match(guide, /also has Keywright \(old\)\.rbxm/);
});
