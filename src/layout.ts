import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// Where Keywright's own files are. It runs in one of two forms:
//
// - From a checkout, compiled into dist/: this file is dist/src/layout.js, the CLI is beside
//   it, and the built plugin and package.json are two folders up.
// - As the single file a release carries, keywright.mjs, made by scripts/bundle.mjs. All of
//   the code is in that one file, the built plugin is downloaded beside it, and the version
//   is written into it when it is made.
//
// The bundle defines these two names; in a checkout they do not exist.
declare const __KEYWRIGHT_BUNDLED__: boolean | undefined;
declare const __KEYWRIGHT_VERSION__: string | undefined;

/** True when running as the single-file release. */
export const BUNDLED: boolean = typeof __KEYWRIGHT_BUNDLED__ !== "undefined" && __KEYWRIGHT_BUNDLED__ === true;

/** The file to run to start Keywright's CLI: this bundle, or dist/src/cli.js. */
export function cliPath(): string {
	return fileURLToPath(BUNDLED ? import.meta.url : new URL("./cli.js", import.meta.url));
}

/**
 * True when started through npx (npm exec), from the npm package. Its files then sit in
 * npm's cache, which can be cleared, so an AI app is told to start it with npx, not by path.
 */
export function viaNpx(env: NodeJS.ProcessEnv = process.env): boolean {
	return BUNDLED && env.npm_command === "exec";
}

/** How a person runs Keywright from a terminal, for messages that tell them a command. */
export function command(): string {
	if (viaNpx()) return "npx -y keywright";
	return BUNDLED ? "node keywright.mjs" : "node dist/src/cli.js";
}

/** Where the built plugin is expected: beside the bundle, or in the checkout's build/ folder. */
export function pluginPath(file: string): string {
	return fileURLToPath(new URL(BUNDLED ? `./${file}` : `../../build/${file}`, import.meta.url));
}

/** Keywright's version: written into the bundle, or read from the checkout's package.json. */
export function packageVersion(): string {
	if (BUNDLED && typeof __KEYWRIGHT_VERSION__ === "string") return __KEYWRIGHT_VERSION__;
	return (JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8")) as { version: string }).version;
}
