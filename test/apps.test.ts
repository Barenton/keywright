import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { addToClaudeCode, addToJson, addToToml, appFor, entryFor, findApps, windowsFallback } from "../src/apps.js";

const npx = { command: "npx", args: ["-y", "keywright@latest"], fullPath: "/usr/bin/npx" };
const entry = { command: "npx", args: ["-y", "keywright@latest"] };

function withHome(run: (home: string) => void) {
	const home = mkdtempSync(join(tmpdir(), "keywright-apps-"));
	try {
		run(home);
	} finally {
		rmSync(home, { recursive: true, force: true });
	}
}

test("an app starts npx as it is, with cmd /c kept as Windows' way out", () => {
	assert.deepEqual(entryFor(npx, "win32"), entry, "plain npx works in Claude Desktop on Windows");
	assert.deepEqual(entryFor(npx, "linux"), entry);
	assert.deepEqual(windowsFallback(entry), { command: "cmd", args: ["/c", "npx", "-y", "keywright@latest"] });
	assert.deepEqual(entryFor({ command: "node", args: ["C:\\\\k\\\\keywright.mjs"], fullPath: "node.exe" }, "win32"), { command: "node", args: ["C:\\\\k\\\\keywright.mjs"] });
});

test("installed apps are found by their settings folders and commands", () =>
	withHome((home) => {
		const appData = join(home, "AppData", "Roaming");
		mkdirSync(join(appData, "Claude"), { recursive: true });
		mkdirSync(join(home, ".codex"));
		const found = findApps({ platform: "win32", env: { APPDATA: appData }, home, hasCommand: () => false });
		assert.deepEqual(found.map((app) => app.name), ["claude-desktop", "codex"]);
		assert.equal(found[0]?.file, join(appData, "Claude", "claude_desktop_config.json"));
		const withClaude = findApps({ platform: "linux", env: {}, home, hasCommand: (name) => name === "claude" });
		assert.deepEqual(withClaude.map((app) => app.name), ["claude-code", "codex"], "no Claude Desktop on Linux");
		assert.equal(appFor("cursor", { platform: "linux", env: {}, home })?.file, join(home, ".cursor", "mcp.json"));
		assert.equal(appFor("claude-desktop", { platform: "linux", env: {}, home }), undefined);
	}));

test("a JSON settings file gains the entry and keeps everything else, with the old file kept", () =>
	withHome((home) => {
		const file = join(home, "Claude", "claude_desktop_config.json");
		assert.deepEqual(addToJson(file, entry), { status: "added", backup: undefined }, "made when missing");
		assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), { mcpServers: { keywright: entry } });
		writeFileSync(file, JSON.stringify({ theme: "dark", mcpServers: { other: { command: "x", args: [] } } }));
		const added = addToJson(file, entry);
		assert.equal(added.status, "added");
		assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), { theme: "dark", mcpServers: { other: { command: "x", args: [] }, keywright: entry } });
		assert.ok("backup" in added && added.backup && existsSync(added.backup), "the file as it was is kept");
		assert.deepEqual(addToJson(file, entry), { status: "unchanged" });
		assert.equal(addToJson(file, { command: "cmd", args: ["/c", "npx", "-y", "keywright@latest"] }).status, "updated");
	}));

test("a JSON settings file that can't be read as such is left as it is", () =>
	withHome((home) => {
		const file = join(home, "mcp.json");
		for (const text of ["{ not json", "[1, 2]", JSON.stringify({ mcpServers: [1] })]) {
			writeFileSync(file, text);
			assert.equal(addToJson(file, entry).status, "skipped", text);
			assert.equal(readFileSync(file, "utf8"), text);
		}
	}));

test("Codex's TOML gains a section of its own, and one already there is left with what to change", () =>
	withHome((home) => {
		const file = join(home, ".codex", "config.toml");
		mkdirSync(join(home, ".codex"));
		writeFileSync(file, 'model = "x"\n');
		assert.equal(addToToml(file, entry).status, "added");
		assert.equal(readFileSync(file, "utf8"), 'model = "x"\n\n[mcp_servers.keywright]\ncommand = "npx"\nargs = ["-y", "keywright@latest"]\n');
		assert.deepEqual(addToToml(file, entry), { status: "unchanged" });
		const before = readFileSync(file, "utf8");
		const other = addToToml(file, { command: "node", args: ["k.mjs"] });
		assert.equal(other.status, "skipped");
		assert.match(other.status === "skipped" ? other.reason : "", /command = "node"/);
		assert.equal(readFileSync(file, "utf8"), before, "not rewritten by hand");
	}));

test("Claude Code is set up with its own command", () => {
	const calls: string[][] = [];
	const answer = (status: number, stdout = "") => ({ status, stdout, stderr: "", pid: 0, output: [], signal: null });
	const missing = ((_command: string, args: string[]) => {
		calls.push(args);
		return args[1] === "get" ? answer(1) : answer(0);
	}) as never;
	assert.deepEqual(addToClaudeCode(entry, missing), { status: "added" });
	assert.deepEqual(calls.at(-1), ["mcp", "add", "--scope", "user", "keywright", "--", "npx", "-y", "keywright@latest"]);
	const present = ((_command: string, args: string[]) => (args[1] === "get" ? answer(0, "  Command: npx\n  Args: -y keywright@latest\n") : answer(0))) as never;
	assert.deepEqual(addToClaudeCode(entry, present), { status: "unchanged" });
});
