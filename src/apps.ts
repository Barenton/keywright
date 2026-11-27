// Adding Keywright to the AI apps on this computer, for `setup`.
//
// Only with the person's yes: setup asks in a terminal, or an agent passes --add-to after
// asking. Each app's settings are changed as little as possible: the keywright entry is
// added or brought up to date, everything else is kept, and a copy of the file as it was
// is saved beside it first. A file that cannot be read as what it should be is left alone.

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Launch } from "./setup.js";

export const APPS = ["claude-desktop", "claude-code", "codex", "cursor"] as const;
export type AppName = (typeof APPS)[number];

export interface App {
	name: AppName;
	label: string;
	/** The settings file for an app set up through a file. */
	file?: string;
}

export type Outcome =
	| { status: "added" | "updated" | "unchanged"; backup?: string }
	| { status: "skipped"; reason: string };

export interface Where {
	platform: NodeJS.Platform;
	env: NodeJS.ProcessEnv;
	home: string;
	/** Whether a command can be run here, as `claude`. */
	hasCommand?: (name: string) => boolean;
}

function commandExists(name: string): boolean {
	const probe = spawnSync(name, ["--version"], { stdio: "ignore", shell: process.platform === "win32", timeout: 15_000 });
	return probe.status === 0;
}

/** Claude Desktop keeps its settings here, on the two systems it runs on. */
function claudeDesktopFile(where: Where): string | undefined {
	if (where.platform === "win32") return where.env.APPDATA ? join(where.env.APPDATA, "Claude", "claude_desktop_config.json") : undefined;
	if (where.platform === "darwin") return join(where.home, "Library", "Application Support", "Claude", "claude_desktop_config.json");
	return undefined;
}

/** An app by name, where its settings would be, whether or not it is installed here. */
export function appFor(name: AppName, where: Where): App | undefined {
	if (name === "claude-desktop") {
		const file = claudeDesktopFile(where);
		return file ? { name, label: "Claude Desktop", file } : undefined;
	}
	if (name === "claude-code") return { name, label: "Claude Code" };
	if (name === "codex") return { name, label: "Codex", file: join(where.home, ".codex", "config.toml") };
	return { name, label: "Cursor", file: join(where.home, ".cursor", "mcp.json") };
}

/** The AI apps that seem to be installed here: by their settings folder, or their command. */
export function findApps(where: Where): App[] {
	const found: App[] = [];
	const desktop = claudeDesktopFile(where);
	if (desktop && existsSync(dirname(desktop))) found.push({ name: "claude-desktop", label: "Claude Desktop", file: desktop });
	if ((where.hasCommand ?? commandExists)("claude")) found.push({ name: "claude-code", label: "Claude Code" });
	const codex = join(where.home, ".codex");
	if (existsSync(codex)) found.push({ name: "codex", label: "Codex", file: join(codex, "config.toml") });
	const cursor = join(where.home, ".cursor");
	if (existsSync(cursor)) found.push({ name: "cursor", label: "Cursor", file: join(cursor, "mcp.json") });
	return found;
}

/**
 * What an app is to run to start Keywright: npx, or node with this copy's file. Plain npx
 * was seen to work in Claude Desktop on Windows (2026-11-27), where npx is a .cmd file.
 */
export function entryFor(launch: Launch, _platform: NodeJS.Platform): { command: string; args: string[] } {
	return { command: launch.command, args: launch.args };
}

/**
 * On Windows, for an app that starts programs without a shell and so can't run npx.cmd:
 * npx started through cmd /c. Offered only as the way out when an app can't start it.
 */
export function windowsFallback(entry: { command: string; args: string[] }): { command: string; args: string[] } | undefined {
	return entry.command === "npx" ? { command: "cmd", args: ["/c", "npx", ...entry.args] } : undefined;
}

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

/** Writes a file whole or not at all, after saving a copy of what was there. */
function replaceFile(file: string, text: string): string | undefined {
	let backup: string | undefined;
	if (existsSync(file)) {
		backup = `${file}.before-keywright`;
		copyFileSync(file, backup);
	} else {
		mkdirSync(dirname(file), { recursive: true });
	}
	const temp = `${file}.${process.pid}.tmp`;
	writeFileSync(temp, text);
	renameSync(temp, file);
	return backup;
}

/** Adds the entry to a JSON settings file with an mcpServers object (Claude Desktop, Cursor). */
export function addToJson(file: string, entry: { command: string; args: string[] }): Outcome {
	let settings: Record<string, unknown> = {};
	if (existsSync(file)) {
		const text = readFileSync(file, "utf8");
		if (text.trim() !== "") {
			try {
				const parsed: unknown = JSON.parse(text);
				if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return { status: "skipped", reason: `${file} is not a settings object, so it was left as it is` };
				settings = parsed as Record<string, unknown>;
			} catch {
				return { status: "skipped", reason: `${file} could not be read as JSON, so it was left as it is` };
			}
		}
	}
	const servers = settings.mcpServers;
	if (servers !== undefined && (servers === null || typeof servers !== "object" || Array.isArray(servers))) {
		return { status: "skipped", reason: `mcpServers in ${file} is not an object, so the file was left as it is` };
	}
	const existing = (servers as Record<string, unknown> | undefined)?.keywright;
	if (same(existing, entry)) return { status: "unchanged" };
	const updated = { ...settings, mcpServers: { ...((servers as Record<string, unknown>) ?? {}), keywright: entry } };
	const backup = replaceFile(file, `${JSON.stringify(updated, null, 2)}\n`);
	return { status: existing === undefined ? "added" : "updated", backup };
}

/** Adds a [mcp_servers.keywright] section to Codex's TOML settings, or leaves one that is there. */
export function addToToml(file: string, entry: { command: string; args: string[] }): Outcome {
	const text = existsSync(file) ? readFileSync(file, "utf8") : "";
	const section = `[mcp_servers.keywright]\ncommand = ${JSON.stringify(entry.command)}\nargs = [${entry.args.map((arg) => JSON.stringify(arg)).join(", ")}]\n`;
	if (/^\s*\[mcp_servers\.keywright\]\s*$/m.test(text)) {
		if (text.includes(section)) return { status: "unchanged" };
		// Rewriting TOML by hand could damage what is around it: say what to change instead.
		return { status: "skipped", reason: `${file} already has a [mcp_servers.keywright] section; change it to:\n${section}` };
	}
	const joined = text === "" || text.endsWith("\n\n") ? text : text.endsWith("\n") ? `${text}\n` : `${text}\n\n`;
	const backup = replaceFile(file, `${joined}${section}`);
	return { status: "added", backup };
}

/** Adds Keywright to Claude Code for every project, with its own command. */
export function addToClaudeCode(entry: { command: string; args: string[] }, run: typeof spawnSync = spawnSync): Outcome {
	const shell = process.platform === "win32";
	const listed = run("claude", ["mcp", "get", "keywright"], { encoding: "utf8", shell, timeout: 30_000 });
	if (listed.status === 0) {
		const output = String(listed.stdout ?? "");
		if (output.includes(`Args: ${entry.args.join(" ")}`) && output.includes(`Command: ${entry.command}`)) return { status: "unchanged" };
		run("claude", ["mcp", "remove", "keywright", "-s", "user"], { encoding: "utf8", shell, timeout: 30_000 });
	}
	const added = run("claude", ["mcp", "add", "--scope", "user", "keywright", "--", entry.command, ...entry.args], { encoding: "utf8", shell, timeout: 30_000 });
	if (added.status !== 0) return { status: "skipped", reason: `claude mcp add failed: ${String(added.stderr ?? "").trim() || `exit ${added.status}`}` };
	return { status: listed.status === 0 ? "updated" : "added" };
}

/** Adds Keywright to one app. */
export function addTo(app: App, entry: { command: string; args: string[] }): Outcome {
	try {
		if (app.name === "claude-code") return addToClaudeCode(entry);
		if (app.name === "codex") return addToToml(app.file as string, entry);
		return addToJson(app.file as string, entry);
	} catch (error) {
		return { status: "skipped", reason: error instanceof Error ? error.message : String(error) };
	}
}
