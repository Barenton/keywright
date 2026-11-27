import { execFileSync } from "node:child_process";
import { constants, copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { BridgeError } from "./broker/protocol.js";
import { BUNDLED, command, pluginPath } from "./layout.js";

/** The file the plugin is installed as. Installing again replaces it. */
export const PLUGIN_FILE = "Keywright.rbxm";
const SAVED_FILE = "Keywright.rbxmx";

/**
 * Where the plugin that goes with this copy of Keywright is: build/Keywright.rbxm in a
 * checkout, or Keywright.rbxm beside the single-file release.
 */
export function builtPlugin(): string {
	return pluginPath(PLUGIN_FILE);
}

export interface Machine {
	platform: NodeJS.Platform;
	env: NodeJS.ProcessEnv;
	home: string;
	/** True inside WSL, where Studio runs on the Windows side. */
	wsl: boolean;
	/** Inside WSL: the Windows user's local app data folder, as a WSL path. */
	windowsLocalAppData: () => string;
}

function insideWsl(env: NodeJS.ProcessEnv): boolean {
	if (env.WSL_DISTRO_NAME) return true;
	try {
		return /microsoft/i.test(readFileSync("/proc/version", "utf8"));
	} catch {
		return false;
	}
}

function windowsLocalAppData(): string {
	// cmd.exe is started from a Windows folder, so that it does not complain about
	// starting in a WSL one; what it prints is turned into a WSL path.
	const windows = execFileSync("cmd.exe", ["/d", "/c", "echo %LOCALAPPDATA%"], { cwd: "/mnt/c", encoding: "utf8" }).trim();
	if (windows === "" || windows.includes("%")) throw new Error("Windows did not say where its local app data folder is.");
	return execFileSync("wslpath", ["-u", windows], { encoding: "utf8" }).trim();
}

export function thisMachine(): Machine {
	return { platform: process.platform, env: process.env, home: homedir(), wsl: process.platform === "linux" && insideWsl(process.env), windowsLocalAppData };
}

/**
 * Roblox's folder for this user, the one that holds Studio's Plugins folder: in local app
 * data on Windows (also when asked from WSL), in Documents on macOS.
 */
export function robloxFolder(machine: Machine): string {
	if (machine.platform === "win32") {
		const local = machine.env.LOCALAPPDATA;
		if (!local) throw new BridgeError("INSTALL_FAILED", "LOCALAPPDATA is not set, so Studio's plugins folder cannot be found.", `Pass the folder: ${command()} install-plugin --folder <path>`);
		return join(local, "Roblox");
	}
	if (machine.platform === "darwin") return join(machine.home, "Documents", "Roblox");
	if (machine.wsl) {
		let local: string;
		try {
			local = machine.windowsLocalAppData();
		} catch (error) {
			throw new BridgeError("INSTALL_FAILED", `Could not ask Windows where Studio's plugins folder is: ${error instanceof Error ? error.message : String(error)}`, `Pass the folder: ${command()} install-plugin --folder <path>`);
		}
		return join(local, "Roblox");
	}
	throw new BridgeError("INSTALL_FAILED", "Roblox Studio does not run on this system, so there is no plugins folder here.", `Run this where Studio is installed, or pass the folder: ${command()} install-plugin --folder <path>`);
}

export interface Installed {
	/** Where the plugin now is. */
	path: string;
	/** An older copy of it saved from Studio under the same name, as Keywright.rbxmx, which it replaced. */
	replaced?: string;
	/** Other copies of Keywright in the same folder, which Studio would also load. */
	others: string[];
}

/**
 * Copies the built plugin into Studio's plugins folder as Keywright.rbxm, replacing an
 * older one: one installed the same way, or one saved from Studio as Keywright.rbxmx. The
 * file is written beside it first and then moved into place, so Studio never sees half
 * of it. Nothing else in the folder is changed.
 */
/**
 * Studio's plugins folder for this user, or the folder KEYWRIGHT_PLUGIN_FOLDER names: set in
 * the environment the person starts Keywright with, for an unusual install, never by an agent.
 */
export function pluginsFolder(machine: Machine): string {
	return machine.env.KEYWRIGHT_PLUGIN_FOLDER || join(robloxFolder(machine), "Plugins");
}

export function installPlugin(source: string, folder: string): Installed {
	if (!existsSync(source)) {
		throw new BridgeError("INSTALL_FAILED", `There is no built plugin at ${source}.`, BUNDLED ? "Download Keywright.rbxm from the same release into the folder with keywright.mjs." : "Build it first: npm run build:plugin");
	}
	if (!existsSync(folder)) {
		// The Plugins folder itself may not exist yet; the Roblox folder around it must.
		if (!existsSync(dirname(folder))) {
			throw new BridgeError("INSTALL_FAILED", `${dirname(folder)} does not exist, so Roblox Studio does not seem to be installed for this user.`, `Install and open Studio once, or pass the folder: ${command()} install-plugin --folder <path>`);
		}
		mkdirSync(folder);
	}
	const path = join(folder, PLUGIN_FILE);
	const partial = `${path}.partial`;
	try {
		// Made afresh and exclusively: anything left at that path, a link to a file elsewhere
		// included, is removed first and never written through.
		rmSync(partial, { force: true });
		copyFileSync(source, partial, constants.COPYFILE_EXCL);
		renameSync(partial, path);
	} finally {
		rmSync(partial, { force: true });
	}
	// "Save as Local Plugin" in Studio writes the plugin as a model file under the name
	// given; left beside this one, Studio would run both.
	let replaced: string | undefined;
	const saved = join(folder, SAVED_FILE);
	if (existsSync(saved)) {
		rmSync(saved);
		replaced = saved;
	}
	const others = readdirSync(folder).filter((name) => name !== PLUGIN_FILE && /^(keywright|motion ?bridge)/i.test(name) && /\.rbxmx?$/i.test(name));
	return replaced ? { path, replaced, others } : { path, others };
}
