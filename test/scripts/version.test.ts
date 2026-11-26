import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { VERSION } from "../../src/version.js";

const root = new URL("../../../", import.meta.url);
const read = (path: string) => readFileSync(new URL(path, root), "utf8");
const sync = (await import(new URL("scripts/sync-version.mjs", root).href)) as { versionModule(version: string): string };

test("the adapter's version is the one in package.json", () => {
	assert.equal(VERSION, (JSON.parse(read("package.json")) as { version: string }).version);
	assert.match(VERSION, /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/);
});

test("the plugin carries the same version", () => {
	assert.equal(read("plugin/src/Version.luau"), sync.versionModule(VERSION), "run: node scripts/sync-version.mjs");
});

test("the plugin's entry point takes its version from that module", () => {
	assert.match(read("plugin/Main.server.luau"), /local PLUGIN_VERSION = require\("\.\/src\/Version"\)/);
});
