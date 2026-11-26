import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { VERSION } from "../../src/version.js";

const root = new URL("../../../", import.meta.url);
const read = (path: string) => readFileSync(new URL(path, root), "utf8");
const sync = (await import(new URL("scripts/sync-version.mjs", root).href)) as { versionModule(version: string): string };
const notes = (await import(new URL("scripts/release-notes.mjs", root).href)) as { notesFor(changelog: string, version: string): string | undefined };

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

test("the changelog describes this version", () => {
	assert.ok(notes.notesFor(read("CHANGELOG.md"), VERSION), `CHANGELOG.md needs a "## [${VERSION}]" section`);
});

test("release notes are the version's own section and no more", () => {
	const changelog = "# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2027-01-01\n\n- Two.\n\n## [0.1.0] - 2026-11-25\n\n- One.\n\n[0.1.0]: https://example.com\n";
	assert.equal(notes.notesFor(changelog, "0.2.0"), "- Two.");
	assert.equal(notes.notesFor(changelog, "0.1.0"), "- One.");
	assert.equal(notes.notesFor(changelog, "Unreleased"), undefined, "an empty section is no notes");
	assert.equal(notes.notesFor(changelog, "0.3.0"), undefined);
});
