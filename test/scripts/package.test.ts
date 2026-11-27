import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { VERSION } from "../../src/version.js";
import { tempHome } from "../helpers.js";

const root = new URL("../../../", import.meta.url);
const scripts = (await import(new URL("scripts/bundle.mjs", root).href)) as {
	bundle(options: { out: string; plugin: boolean }): Promise<{ outfile: string }>;
};

// The npm package, packed and installed as npm would install it, with nothing from the
// network: it has no dependencies, since everything is in the bundle.
describe("the npm package", () => {
	const temp = tempHome();
	const npm = (args: string[], cwd: string, env: NodeJS.ProcessEnv = process.env) =>
		// npm's own options go first: after "--", everything belongs to the command run.
		execFileSync("npm", ["--offline", "--no-audit", "--no-fund", "--loglevel=error", ...args], { cwd, encoding: "utf8", env });
	let prefix = "";

	before(async () => {
		const folder = join(temp.home, "package");
		await scripts.bundle({ out: folder, plugin: false });
		writeFileSync(join(folder, "Keywright.rbxm"), "stand-in plugin");
		const packed = JSON.parse(npm(["pack", "--json", "--pack-destination", temp.home], folder)) as Array<{ filename: string }>;
		prefix = join(temp.home, "installed");
		mkdirSync(prefix);
		npm(["install", "--ignore-scripts", join(temp.home, packed[0]?.filename ?? "")], prefix);
	});

	after(() => temp.cleanup());

	test("holds the adapter, the plugin, the skill, the licences and the README, and depends on nothing", () => {
		const installed = join(prefix, "node_modules", "keywright");
		const manifest = JSON.parse(readFileSync(join(installed, "package.json"), "utf8")) as Record<string, unknown>;
		assert.equal(manifest.version, VERSION);
		assert.deepEqual(manifest.bin, { keywright: "keywright.mjs" });
		assert.equal(manifest.dependencies, undefined);
		for (const file of ["keywright.mjs", "Keywright.rbxm", "THIRD_PARTY_LICENSES.txt", "README.md", "LICENSE", "skills/keywright/SKILL.md", "skills/keywright/reference/moves.md"]) {
			assert.ok(readFileSync(join(installed, file)).length > 0, file);
		}
	});

	test("runs as the keywright command", () => {
		assert.equal(execFileSync(join(prefix, "node_modules", ".bin", "keywright"), ["version"], { encoding: "utf8" }).trim(), VERSION);
	});

	test("run through npm exec, as npx runs it, sets itself up and tells apps to start it with npx", () => {
		mkdirSync(join(temp.home, "Roblox"));
		const plugins = join(temp.home, "Roblox", "Plugins");
		const said = npm(["exec", "--", "keywright", "setup", "--folder", plugins], prefix);
		assert.equal(readFileSync(join(plugins, "Keywright.rbxm"), "utf8"), "stand-in plugin");
		assert.match(said, /claude mcp add --scope user keywright -- npx -y keywright@latest/);
		assert.doesNotMatch(said, /node_modules/, "no path into an install folder or npm's cache");
	});
});
