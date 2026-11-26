// Writes the version in package.json into plugin/src/Version.luau, so the plugin and the
// adapter of one release carry the same number. `npm version <new>` runs this before it
// commits; run it by hand after changing the version any other way.
//
// Usage: node scripts/sync-version.mjs

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export function versionModule(version) {
	return `--!strict\n-- Keywright's version. Written from package.json by scripts/sync-version.mjs: change it there.\n\nreturn "${version}"\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const { version } = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
	writeFileSync(join(ROOT, "plugin", "src", "Version.luau"), versionModule(version));
	process.stdout.write(`plugin/src/Version.luau now says ${version}.\n`);
}
