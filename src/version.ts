import { packageVersion } from "./layout.js";

/**
 * Keywright's version, the one in package.json. The plugin carries the same number in
 * plugin/src/Version.luau, written from package.json by scripts/sync-version.mjs, so the
 * two halves of a release always say which release they belong to.
 */
export const VERSION: string = packageVersion();
