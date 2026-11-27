// Adding Keywright to the AI apps on this computer, for `setup`.
//
// Only with the person's yes: setup asks in a terminal, or an agent passes --add-to after
// asking. Each app's settings are changed as little as possible: the keywright entry is
// added or brought up to date, everything else is kept, and a copy of the file as it was
// is saved beside it first. A file that cannot be read as what it should be is left alone.

import { spawnSync } from "node:child_process";
import { constants, copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
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
	| { status: "added" | "updated" | "unchanged"; backup?: string; skill?: string }
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

/** Codex's folder: CODEX_HOME when it is set, as Codex itself reads it, else ~/.codex. */
function codexFolder(where: Where): string {
	return where.env.CODEX_HOME ? where.env.CODEX_HOME : join(where.home, ".codex");
}

/** An app by name, where its settings would be, whether or not it is installed here. */
export function appFor(name: AppName, where: Where): App | undefined {
	if (name === "claude-desktop") {
		const file = claudeDesktopFile(where);
		return file ? { name, label: "Claude Desktop", file } : undefined;
	}
	if (name === "claude-code") return { name, label: "Claude Code" };
	if (name === "codex") return { name, label: "Codex", file: join(codexFolder(where), "config.toml") };
	return { name, label: "Cursor", file: join(where.home, ".cursor", "mcp.json") };
}

/** The AI apps that seem to be installed here: by their settings folder, or their command. */
export function findApps(where: Where): App[] {
	const found: App[] = [];
	const desktop = claudeDesktopFile(where);
	if (desktop && existsSync(dirname(desktop))) found.push({ name: "claude-desktop", label: "Claude Desktop", file: desktop });
	if ((where.hasCommand ?? commandExists)("claude")) found.push({ name: "claude-code", label: "Claude Code" });
	const codex = codexFolder(where);
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

/**
 * Writes a file whole or not at all, keeping its permissions (a settings file may hold
 * tokens), after keeping a copy of it as it was before Keywright first changed it. Files
 * are made afresh and exclusively, so a link left at a path is never written through.
 */
function replaceFile(file: string, text: string): string | undefined {
	let backup: string | undefined;
	let mode = 0o600;
	if (existsSync(file)) {
		mode = statSync(file).mode & 0o777;
		backup = `${file}.before-keywright`;
		// The first copy is the one from before Keywright; a later update keeps it.
		if (!existsSync(backup)) copyFileSync(file, backup, constants.COPYFILE_EXCL);
	} else {
		mkdirSync(dirname(file), { recursive: true });
	}
	const temp = `${file}.${process.pid}.tmp`;
	rmSync(temp, { force: true });
	writeFileSync(temp, text, { mode, flag: "wx" });
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
	const current = existing !== null && typeof existing === "object" && !Array.isArray(existing) ? (existing as Record<string, unknown>) : undefined;
	if (current && same(current.command, entry.command) && same(current.args, entry.args)) return { status: "unchanged" };
	// Only how it is started changes; anything else in the entry, as env, is kept.
	const updated = { ...settings, mcpServers: { ...((servers as Record<string, unknown>) ?? {}), keywright: { ...(current ?? {}), ...entry } } };
	const backup = replaceFile(file, `${JSON.stringify(updated, null, 2)}\n`);
	return { status: existing === undefined ? "added" : "updated", backup };
}

/** Adds a [mcp_servers.keywright] section to Codex's TOML settings, or leaves one that is there. */
export function addToToml(file: string, entry: { command: string; args: string[] }): Outcome {
	const text = existsSync(file) ? readFileSync(file, "utf8") : "";
	const section = `[mcp_servers.keywright]\ncommand = ${JSON.stringify(entry.command)}\nargs = [${entry.args.map((arg) => JSON.stringify(arg)).join(", ")}]\n`;
	if (text.includes(section)) return { status: "unchanged" };
	// A keywright entry already there in any spelling, or servers written as an inline
	// table, can't be added to by appending: rewriting TOML by hand could damage what is
	// around it, so say what to change instead.
	const hasEntry = /^\s*\[\s*mcp_servers\s*\.\s*["']?keywright["']?\s*\]/m.test(text);
	const inline = /^\s*mcp_servers\s*=/m.test(text) || /^\s*\[\s*mcp_servers\s*\]/m.test(text) && /^\s*keywright\s*=/m.test(text);
	if (hasEntry || inline) {
		return { status: "skipped", reason: `${file} already lists Keywright, or lists its servers in a way setup doesn't change; make Keywright's entry:\n${section}` };
	}
	const joined = text === "" || text.endsWith("\n\n") ? text : text.endsWith("\n") ? `${text}\n` : `${text}\n\n`;
	const backup = replaceFile(file, `${joined}${section}`);
	return { status: "added", backup };
}

/**
 * An argument for Windows' command shell, which claude (a .cmd file there) runs through:
 * quoted where it holds a space or a character the shell would act on, or undefined if it
 * holds one the shell would act on even in quotes.
 */
export function cmdArgument(value: string): string | undefined {
	if (/["%!\r\n]/.test(value)) return undefined;
	return /[\s&|<>^()]/.test(value) ? `"${value}"` : value;
}

/**
 * Adds Keywright to Claude Code for every project, with its own command. An entry already
 * there for every project is never removed: one that differs is reported with the commands
 * to change it, so a failure part-way can't leave Claude Code without Keywright.
 */
export function addToClaudeCode(entry: { command: string; args: string[] }, run: typeof spawnSync = spawnSync, platform: NodeJS.Platform = process.platform): Outcome {
	const windows = platform === "win32";
	const args = (list: string[]): string[] | undefined => {
		if (!windows) return list;
		const quoted = list.map(cmdArgument);
		return quoted.every((item) => item !== undefined) ? (quoted as string[]) : undefined;
	};
	const wanted = ["mcp", "add", "--scope", "user", "keywright", "--", entry.command, ...entry.args];
	const by = `claude ${wanted.join(" ")}`;
	const addArgs = args(wanted);
	if (!addArgs) return { status: "skipped", reason: `the command has characters Windows' shell would change; run it yourself: ${by}` };
	const listed = run("claude", ["mcp", "get", "keywright"], { encoding: "utf8", shell: windows, timeout: 30_000 });
	const output = String(listed.stdout ?? "");
	// Only the entry for every project counts: one for the project setup runs in doesn't.
	if (listed.status === 0 && /Scope:\s*User/i.test(output)) {
		if (output.includes(`Command: ${entry.command}`) && output.includes(`Args: ${entry.args.join(" ")}`)) return { status: "unchanged" };
		return { status: "skipped", reason: `Claude Code already starts Keywright another way; to change it, run: claude mcp remove keywright -s user, then ${by}` };
	}
	const added = run("claude", addArgs, { encoding: "utf8", shell: windows, timeout: 30_000 });
	if (added.status !== 0) return { status: "skipped", reason: `claude mcp add failed: ${String(added.stderr ?? "").trim() || `exit ${added.status}`}` };
	return { status: "added" };
}

/**
 * Puts the Keywright skill into Claude Code's skills folder for this user, from the folder
 * the release carries, replacing an earlier copy of it. Returns where it went.
 */
export function installSkill(home: string, source: string): string {
	const target = join(home, ".claude", "skills", "keywright");
	// The copy there is set aside first, so local changes to it aren't lost and files a
	// release no longer has don't linger; only the copy set aside last time is replaced.
	if (existsSync(target)) {
		// Outside the skills folder, where Claude Code would load it as a second skill.
		const aside = join(home, ".claude", "keywright-skill.before-update");
		rmSync(aside, { recursive: true, force: true });
		renameSync(target, aside);
	}
	cpSync(source, target, { recursive: true });
	return target;
}

/** Adds Keywright to one app; for Claude Code, with its skill when the release carries it. */
export function addTo(app: App, entry: { command: string; args: string[] }, extras: { home?: string; skill?: string } = {}): Outcome {
	try {
		if (app.name === "claude-code") {
			const outcome = addToClaudeCode(entry);
			if (outcome.status !== "skipped" && extras.home && extras.skill && existsSync(extras.skill)) {
				return { ...outcome, skill: installSkill(extras.home, extras.skill) };
			}
			return outcome;
		}
		if (app.name === "codex") return addToToml(app.file as string, entry);
		return addToJson(app.file as string, entry);
	} catch (error) {
		return { status: "skipped", reason: error instanceof Error ? error.message : String(error) };
	}
}
