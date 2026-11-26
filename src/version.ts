import { readFileSync } from "node:fs";

/**
 * Keywright's version, the one in package.json. The plugin carries the same number in
 * plugin/src/Version.luau, written from package.json by scripts/sync-version.mjs, so the
 * two halves of a release always say which release they belong to.
 */
export const VERSION: string = (JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8")) as { version: string }).version;
