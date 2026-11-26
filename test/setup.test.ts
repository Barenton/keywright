import assert from "node:assert/strict";
import { test } from "node:test";
import { setupGuide } from "../src/setup.js";

const facts = {
	version: "9.9.9",
	entry: "C:\\Tools\\keywright\\keywright.mjs",
	installed: { path: "C:\\Users\\me\\AppData\\Local\\Roblox\\Plugins\\Keywright.rbxm", others: [] },
	wsl: false,
	node: "/usr/bin/node",
};

test("the guide gives each app's entry with this copy's path, written so the app reads it back exactly", () => {
	const guide = setupGuide(facts);
	assert.match(guide, /^Keywright v9\.9\.9 is set up\./);
	assert.ok(guide.includes(`claude mcp add keywright -- node "C:\\\\Tools\\\\keywright\\\\keywright.mjs"`));
	const json = guide.split("\n").find((line) => line.includes('"mcpServers"'));
	assert.deepEqual(JSON.parse(json ?? ""), { mcpServers: { keywright: { command: "node", args: [facts.entry] } } });
	assert.match(guide, /\[mcp_servers\.keywright\]/);
});

test("the guide says what only the person can do", () => {
	const guide = setupGuide(facts);
	assert.match(guide, /Restart the AI app/);
	assert.match(guide, /Turn on agent access/);
	assert.match(guide, /Pair Keywright with code/);
});

test("inside WSL, the guide adds the entry for apps on Windows, through wsl.exe and the full path to node", () => {
	assert.equal(setupGuide(facts).includes("wsl.exe"), false);
	const guide = setupGuide({ ...facts, entry: "/home/me/keywright/keywright.mjs", wsl: true, node: "/home/me/.nvm/versions/node/v22.0.0/bin/node" });
	const json = guide.split("\n").find((line) => line.includes('"wsl.exe"'));
	assert.deepEqual(JSON.parse(json ?? ""), {
		mcpServers: { keywright: { command: "wsl.exe", args: ["/home/me/.nvm/versions/node/v22.0.0/bin/node", "/home/me/keywright/keywright.mjs"] } },
	});
});

test("the guide mentions other copies Studio would also load", () => {
	const guide = setupGuide({ ...facts, installed: { path: "x", others: ["Keywright (old).rbxm"] } });
	assert.match(guide, /also has Keywright \(old\)\.rbxm/);
});
