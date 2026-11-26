import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BridgeError } from "../../src/broker/protocol.js";
import { installPlugin, PLUGIN_FILE, robloxFolder, type Machine } from "../../src/install.js";

function machine(overrides: Partial<Machine>): Machine {
	return {
		platform: "linux",
		env: {},
		home: "/home/someone",
		wsl: false,
		windowsLocalAppData: () => {
			throw new Error("not asked for");
		},
		...overrides,
	};
}

function scratch(): string {
	return mkdtempSync(join(tmpdir(), "keywright-install-"));
}

test("Studio's Roblox folder is found on each system", () => {
	assert.equal(robloxFolder(machine({ platform: "win32", env: { LOCALAPPDATA: "C:\\Users\\a\\AppData\\Local" } })), join("C:\\Users\\a\\AppData\\Local", "Roblox"));
	assert.equal(robloxFolder(machine({ platform: "darwin", home: "/Users/a" })), join("/Users/a", "Documents", "Roblox"));
	assert.equal(robloxFolder(machine({ wsl: true, windowsLocalAppData: () => "/mnt/c/Users/a/AppData/Local" })), "/mnt/c/Users/a/AppData/Local/Roblox");
});

test("where Studio cannot be, the folder has to be given", () => {
	for (const where of [machine({}), machine({ platform: "win32" }), machine({ wsl: true })]) {
		assert.throws(
			() => robloxFolder(where),
			(error: unknown) => error instanceof BridgeError && error.code === "INSTALL_FAILED" && /--folder/.test(error.hint ?? ""),
		);
	}
});

test("the plugin is copied in, replacing an older one, and nothing else is touched", () => {
	const root = scratch();
	try {
		const source = join(root, "built.rbxm");
		writeFileSync(source, "new plugin");
		const plugins = join(root, "Roblox", "Plugins");
		mkdirSync(plugins, { recursive: true });
		writeFileSync(join(plugins, PLUGIN_FILE), "old plugin");
		writeFileSync(join(plugins, "SomethingElse.rbxm"), "another plugin");

		const installed = installPlugin(source, plugins);
		assert.equal(installed.path, join(plugins, PLUGIN_FILE));
		assert.equal(readFileSync(installed.path, "utf8"), "new plugin");
		assert.deepEqual(readdirSync(plugins).sort(), [PLUGIN_FILE, "SomethingElse.rbxm"]);
		assert.deepEqual(installed.others, []);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});

test("other copies of Keywright in the folder are pointed out, not removed", () => {
	const root = scratch();
	try {
		const source = join(root, "built.rbxm");
		writeFileSync(source, "plugin");
		const plugins = join(root, "Roblox", "Plugins");
		mkdirSync(plugins, { recursive: true });
		for (const name of ["KeywrightFault.rbxm", "MotionBridge.rbxm", "keywright-old.rbxmx", "Keywright notes.txt"]) writeFileSync(join(plugins, name), "");
		const installed = installPlugin(source, plugins);
		assert.deepEqual(installed.others.sort(), ["KeywrightFault.rbxm", "MotionBridge.rbxm", "keywright-old.rbxmx"]);
		assert.equal(installed.replaced, undefined);
		assert.equal(readdirSync(plugins).length, 5);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});

test("a copy saved from Studio under the plugin's name is replaced", () => {
	const root = scratch();
	try {
		const source = join(root, "built.rbxm");
		writeFileSync(source, "plugin");
		const plugins = join(root, "Roblox", "Plugins");
		mkdirSync(plugins, { recursive: true });
		writeFileSync(join(plugins, "Keywright.rbxmx"), "saved from Studio");
		const installed = installPlugin(source, plugins);
		assert.equal(installed.replaced, join(plugins, "Keywright.rbxmx"));
		assert.deepEqual(readdirSync(plugins), [PLUGIN_FILE]);
		assert.deepEqual(installed.others, []);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});

test("a missing Plugins folder is made, but only inside an existing Roblox folder", () => {
	const root = scratch();
	try {
		const source = join(root, "built.rbxm");
		writeFileSync(source, "plugin");
		mkdirSync(join(root, "Roblox"));
		installPlugin(source, join(root, "Roblox", "Plugins"));
		assert.deepEqual(readdirSync(join(root, "Roblox", "Plugins")), [PLUGIN_FILE]);
		assert.throws(() => installPlugin(source, join(root, "NoRoblox", "Plugins")), /does not seem to be installed/);
		assert.throws(() => installPlugin(join(root, "missing.rbxm"), join(root, "Roblox", "Plugins")), /no built plugin/);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});
