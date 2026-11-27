import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { addToClaudeCode, addToJson, addToToml, appFor, cmdArgument, entryFor, findApps, installSkill, windowsFallback } from "../src/apps.js";

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

test("Claude Code is set up with its own command, and an entry already there is never removed", () => {
	const calls: string[][] = [];
	const answer = (status: number, stdout = "") => ({ status, stdout, stderr: "", pid: 0, output: [], signal: null });
	const fake = (got: (args: string[]) => ReturnType<typeof answer>) =>
		((_command: string, args: string[]) => {
			calls.push(args);
			return got(args);
		}) as never;
	assert.deepEqual(addToClaudeCode(entry, fake((args) => (args[1] === "get" ? answer(1) : answer(0))), "linux"), { status: "added" });
	assert.deepEqual(calls.at(-1), ["mcp", "add", "--scope", "user", "keywright", "--", "npx", "-y", "keywright@latest"]);
	const user = (args: string[]) => (args[1] === "get" ? answer(0, "  Scope: User config (available in all your projects)\n  Command: npx\n  Args: -y keywright@latest\n") : answer(0));
	assert.deepEqual(addToClaudeCode(entry, fake(user), "linux"), { status: "unchanged" });
	calls.length = 0;
	const other = addToClaudeCode({ command: "node", args: ["k.mjs"] }, fake(user), "linux");
	assert.equal(other.status, "skipped");
	assert.equal(calls.some((args) => args[1] === "remove"), false, "never removed");
	// One for the project setup runs in doesn't count: the one for every project is added.
	const project = (args: string[]) => (args[1] === "get" ? answer(0, "  Scope: Local config\n  Command: npx\n  Args: -y keywright@latest\n") : answer(0));
	assert.deepEqual(addToClaudeCode(entry, fake(project), "linux"), { status: "added" });
});

test("on Windows Claude Code's command is quoted for its shell, or given to run by hand", () => {
	assert.equal(cmdArgument("C:\\Users\\Jane Doe\\k.mjs"), '"C:\\Users\\Jane Doe\\k.mjs"');
	assert.equal(cmdArgument("C:\\work\\A&B\\k.mjs"), '"C:\\work\\A&B\\k.mjs"');
	assert.equal(cmdArgument("keywright@latest"), "keywright@latest");
	assert.equal(cmdArgument("C:\\100%\\k.mjs"), undefined, "% is expanded even in quotes");
	const calls: string[][] = [];
	const run = ((_command: string, args: string[]) => {
		calls.push(args);
		return { status: args[1] === "get" ? 1 : 0, stdout: "", stderr: "", pid: 0, output: [], signal: null };
	}) as never;
	addToClaudeCode({ command: "node", args: ["C:\\Users\\Jane Doe\\k.mjs"] }, run, "win32");
	assert.equal(calls.at(-1)?.at(-1), '"C:\\Users\\Jane Doe\\k.mjs"');
	const refused = addToClaudeCode({ command: "node", args: ["C:\\100%\\k.mjs"] }, run, "win32");
	assert.equal(refused.status, "skipped");
});

test("the skill is put into Claude Code's skills folder, replacing an earlier copy", () =>
	withHome((home) => {
		const source = join(home, "release", "skills", "keywright");
		mkdirSync(join(source, "reference"), { recursive: true });
		writeFileSync(join(source, "SKILL.md"), "new");
		writeFileSync(join(source, "reference", "moves.md"), "moves");
		const target = join(home, ".claude", "skills", "keywright");
		mkdirSync(target, { recursive: true });
		writeFileSync(join(target, "SKILL.md"), "old");
		writeFileSync(join(target, "obsolete.md"), "gone");
		assert.equal(installSkill(home, source), target);
		assert.equal(readFileSync(join(target, "SKILL.md"), "utf8"), "new");
		assert.equal(readFileSync(join(target, "reference", "moves.md"), "utf8"), "moves");
		assert.equal(existsSync(join(target, "obsolete.md")), false, "nothing a release no longer has lingers");
		const aside = join(home, ".claude", "keywright-skill.before-update");
		assert.equal(readFileSync(join(aside, "SKILL.md"), "utf8"), "old", "the copy there is kept, outside the skills folder");
	}));

test("a JSON entry keeps what else it has, the file keeps its permissions, and the first backup is kept", () =>
	withHome((home) => {
		const file = join(home, "claude_desktop_config.json");
		writeFileSync(file, JSON.stringify({ mcpServers: { keywright: { command: "node", args: ["old.mjs"], env: { KEYWRIGHT_PORT: "47400" } } } }), { mode: 0o600 });
		assert.equal(addToJson(file, entry).status, "updated");
		assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).mcpServers.keywright, { ...entry, env: { KEYWRIGHT_PORT: "47400" } });
		if (process.platform !== "win32") assert.equal(statSync(file).mode & 0o777, 0o600, "still readable only by its owner");
		const backup = `${file}.before-keywright`;
		assert.match(readFileSync(backup, "utf8"), /old\.mjs/);
		addToJson(file, { command: "cmd", args: ["/c", "npx"] });
		assert.match(readFileSync(backup, "utf8"), /old\.mjs/, "the copy from before Keywright stays");
	}));

test("Codex settings that already list Keywright in another spelling, or inline, are left alone", () =>
	withHome((home) => {
		const file = join(home, "config.toml");
		for (const text of ['[mcp_servers."keywright"] # chosen\ncommand = "node"\n', "mcp_servers = {}\n", '[mcp_servers]\nkeywright = { command = "node" }\n']) {
			writeFileSync(file, text);
			assert.equal(addToToml(file, entry).status, "skipped", text);
			assert.equal(readFileSync(file, "utf8"), text);
		}
	}));

test("Codex is looked for where CODEX_HOME says", () =>
	withHome((home) => {
		const custom = join(home, "work-codex");
		mkdirSync(custom);
		const where = { platform: "linux" as NodeJS.Platform, env: { CODEX_HOME: custom }, home, hasCommand: () => false };
		assert.equal(findApps(where).find((app) => app.name === "codex")?.file, join(custom, "config.toml"));
		assert.equal(appFor("codex", where)?.file, join(custom, "config.toml"));
	}));
