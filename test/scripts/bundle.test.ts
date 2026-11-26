import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { VERSION } from "../../src/version.js";
import { freePort, tempHome } from "../helpers.js";

const root = new URL("../../../", import.meta.url);
const scripts = (await import(new URL("scripts/bundle.mjs", root).href)) as {
	bundle(options: { out: string; plugin: boolean }): Promise<{ outfile: string; packages: number }>;
};

// The single-file release, run the way a person who downloaded it would run it: from a
// folder of its own, with the plugin beside it, and none of the checkout around it.
describe("the single-file release", () => {
	const temp = tempHome();
	let bundle = "";
	let folder = "";
	const run = (args: string[], env: Record<string, string> = {}) =>
		execFileSync(process.execPath, [bundle, ...args], { encoding: "utf8", env: { ...process.env, ...env }, cwd: temp.home });

	before(async () => {
		folder = join(temp.home, "download");
		const made = await scripts.bundle({ out: folder, plugin: false });
		bundle = made.outfile;
		writeFileSync(join(folder, "Keywright.rbxm"), "stand-in plugin");
	});

	after(() => temp.cleanup());

	test("says its version", () => {
		assert.equal(run(["version"]).trim(), VERSION);
	});

	test("lists the licences of what it bundles", () => {
		const notices = readFileSync(join(folder, "THIRD_PARTY_LICENSES.txt"), "utf8");
		for (const name of ["@modelcontextprotocol/sdk", "ws", "zod"]) assert.match(notices, new RegExp(`^${name.replace("/", "\\/")} `, "m"));
	});

	test("offers the same tools over MCP as the checkout", async () => {
		const port = await freePort();
		const client = new Client({ name: "bundle-test", version: "0" });
		await client.connect(
			new StdioClientTransport({
				command: process.execPath,
				args: [bundle],
				env: { ...process.env, KEYWRIGHT_HOME: join(temp.home, "state"), KEYWRIGHT_PORT: String(port) } as Record<string, string>,
			}),
		);
		try {
			const { tools } = await client.listTools();
			assert.deepEqual(
				tools.map((tool) => tool.name),
				["get_workspace", "pair_studio", "inspect_rig", "open_animation", "read_animation", "edit_animation", "validate_animation", "save_animation", "discard_animation", "preview_animation"],
			);
		} finally {
			await client.close();
		}
	});

	test("installs the plugin that is beside it", () => {
		const plugins = join(temp.home, "Roblox", "Plugins");
		mkdirSync(join(temp.home, "Roblox"));
		const said = run(["install-plugin", "--folder", plugins]);
		assert.match(said, new RegExp(`\\(v${VERSION.replace(/\./g, "\\.")}\\)`));
		assert.equal(readFileSync(join(plugins, "Keywright.rbxm"), "utf8"), "stand-in plugin");
	});

	test("sets itself up: installs the plugin and gives the AI app its own path", () => {
		const plugins = join(temp.home, "Roblox", "Setup");
		const said = run(["setup", "--folder", plugins]);
		assert.equal(readFileSync(join(plugins, "Keywright.rbxm"), "utf8"), "stand-in plugin");
		assert.ok(said.includes(`claude mcp add keywright -- node ${JSON.stringify(bundle)}`), said);
		assert.ok(said.includes(join(plugins, "Keywright.rbxm")));
	});

	test("starts a broker from itself", async () => {
		const port = await freePort();
		const status = JSON.parse(run(["status"], { KEYWRIGHT_HOME: join(temp.home, "broker"), KEYWRIGHT_PORT: String(port) })) as { pid: number; version: string; port: number };
		try {
			assert.equal(status.version, VERSION);
			assert.equal(status.port, port);
		} finally {
			process.kill(status.pid);
		}
	});
});
