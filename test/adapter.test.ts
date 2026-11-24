import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Broker } from "../src/broker.js";
import { connectAdapter } from "../src/client.js";
import { loadOrCreateSecret } from "../src/state.js";
import { CLI_PATH, FakePlugin, freePort, PluginError, tempHome } from "./helpers.js";

const SESSION = "d".repeat(16);
// A 1x1 PNG.
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

type Content = Array<{ type: string; text?: string; data?: string; mimeType?: string }>;

describe("MCP adapter over stdio", () => {
	const temp = tempHome();
	let broker: Broker;
	let plugin: FakePlugin;
	let mcp: Client;
	let revision = 1;

	before(async () => {
		const port = await freePort();
		broker = new Broker({ home: temp.home, port });
		await broker.start();
		const admin = await connectAdapter(port, loadOrCreateSecret(temp.home));
		await admin.request("broker.pair_register", { code: "ADAPTERTEST" });
		admin.close();
		plugin = await FakePlugin.pair(port, "ADAPTERTEST", SESSION, async (method, params) => {
			const input = params as Record<string, unknown>;
			if (method === "get_workspace") {
				// A plugin that volunteers an image where none belongs.
				return { rigs: [{ rig_id: "rig_1", name: "Dummy" }], capture_available: true, images: [{ png_base64: PNG }] };
			}
			if (method === "edit_animation") {
				if (input.expected_revision !== `r${revision}`) {
					throw new PluginError({
						code: "REVISION_CONFLICT",
						message: `Expected ${String(input.expected_revision)}, clip is at r${revision}.`,
						hint: "Read the clip again and retry.",
					});
				}
				revision += 1;
				return { revision: `r${revision}`, changed: { poses: 1 } };
			}
			if (method === "open_animation" && input.rig_id === "rig_leaky") {
				// A plugin that tries to pass an image along in the text of an error.
				throw new PluginError({ code: "UNSUPPORTED_RIG", message: `see ${PNG}`, hint: `data:image/png;base64,${PNG}` });
			}
			if (method === "preview_animation") {
				// This plugin always sends an image, asked or not, so the relay's checks are what is tested.
				// "clip_slow" takes long enough for the caller to give up on it.
				if (input.clip_id === "clip_slow") await new Promise((resolve) => setTimeout(resolve, 400));
				// For "clip_cut" the image is cut off at the end, and reported with the size it then has.
				const whole = Buffer.from(PNG, "base64");
				const data = input.clip_id === "clip_cut" ? whole.subarray(0, whole.length - 12) : whole;
				const capture = { status: "ok", format: "png", width: 1, height: 1, bytes: data.length };
				return { clip_id: input.clip_id, time: input.time, capture, images: [{ png_base64: data.toString("base64") }] };
			}
			return { method, params };
		});

		mcp = new Client({ name: "adapter-test", version: "0" });
		await mcp.connect(
			new StdioClientTransport({
				command: process.execPath,
				args: [CLI_PATH],
				env: { ...process.env, MOTION_BRIDGE_HOME: temp.home, MOTION_BRIDGE_PORT: String(port) } as Record<string, string>,
			}),
		);
	});

	after(async () => {
		await mcp.close();
		plugin.close();
		await broker.stop();
		temp.cleanup();
	});

	const callTool = async (name: string, args: Record<string, unknown>) => {
		const result = await mcp.callTool({ name, arguments: args });
		const content = result.content as Content;
		return { isError: result.isError === true, content, json: JSON.parse(content[0]?.text ?? "null") as Record<string, any> };
	};

	test("lists the Phase 0 tools with input schemas", async () => {
		const { tools } = await mcp.listTools();
		assert.deepEqual(
			tools.map((tool) => tool.name).sort(),
			["edit_animation", "get_workspace", "inspect_rig", "open_animation", "preview_animation", "read_animation"],
		);
		for (const tool of tools) assert.equal(tool.inputSchema.type, "object");
	});

	test("get_workspace merges broker sessions with each session's workspace", async () => {
		const { json, isError } = await callTool("get_workspace", {});
		assert.equal(isError, false);
		assert.equal(json.sessions.length, 1);
		assert.equal(json.sessions[0].session.id, SESSION);
		assert.equal(json.sessions[0].rigs[0].rig_id, "rig_1");
	});

	test("session_id routes the call and is not forwarded as a parameter", async () => {
		const { json } = await callTool("inspect_rig", { session_id: SESSION, rig_id: "rig_1", detail: true });
		assert.deepEqual(json, { method: "inspect_rig", params: { rig_id: "rig_1", detail: true } });
	});

	test("a stale revision comes back as a structured error and a fresh one succeeds", async () => {
		const edit = (expected: string) =>
			callTool("edit_animation", {
				session_id: SESSION,
				clip_id: "clip_1",
				expected_revision: expected,
				operations: [{ type: "set_pose", joint: "RightUpperArm", time: 0.5, rotation: [0, 0, 90] }],
			});
		const first = await edit("r1");
		assert.equal(first.isError, false);
		assert.equal(first.json.revision, "r2");
		const stale = await edit("r1");
		assert.equal(stale.isError, true);
		assert.equal(stale.json.error.code, "REVISION_CONFLICT");
		assert.equal(stale.json.error.hint, "Read the clip again and retry.");
	});

	test("invalid input is rejected by the adapter before it reaches Studio", async () => {
		const before = plugin.received.length;
		const result = await mcp.callTool({
			name: "edit_animation",
			arguments: {
				session_id: SESSION,
				clip_id: "clip_1",
				expected_revision: "r2",
				operations: [{ type: "set_pose", joint: "RightUpperArm", time: -1 }],
			},
		});
		assert.equal(result.isError, true);
		assert.equal(plugin.received.length, before);
	});

	test("an image that was not asked for never reaches the client", async () => {
		const preview = await callTool("preview_animation", { session_id: SESSION, clip_id: "clip_1", time: 0.5 });
		assert.equal(preview.content.length, 1);
		assert.equal(preview.json.images, undefined);
		assert.equal(preview.json.capture.status, "unavailable");
		assert.match(preview.json.capture.reason, /not asked for/);

		const workspace = await callTool("get_workspace", {});
		assert.equal(workspace.content.length, 1);
		assert.doesNotMatch(workspace.content[0]?.text ?? "", /png_base64|iVBOR/);
		assert.equal(workspace.json.sessions[0].rigs[0].rig_id, "rig_1");
	});

	test("a cut-short image is rejected by the relay and reported as unavailable", async () => {
		const { content, json } = await callTool("preview_animation", {
			session_id: SESSION,
			clip_id: "clip_cut",
			time: 0.5,
			capture: true,
		});
		assert.equal(content.length, 1);
		assert.equal(json.capture.status, "unavailable");
		assert.match(json.capture.reason, /relay rejected the screenshot: it is cut short/);
	});

	test("a tool call the client cancels is cancelled in Studio", async () => {
		const before = plugin.cancelled.length;
		const controller = new AbortController();
		const pending = mcp
			.callTool({ name: "preview_animation", arguments: { session_id: SESSION, clip_id: "clip_slow", time: 0.5, capture: true } }, undefined, {
				signal: controller.signal,
			})
			.then(
				() => "answered",
				() => "cancelled",
			);
		await new Promise((resolve) => setTimeout(resolve, 100));
		assert.equal(plugin.cancelled.length, before);
		controller.abort();
		assert.equal(await pending, "cancelled");
		await new Promise((resolve) => setTimeout(resolve, 100));
		assert.equal(plugin.cancelled.length, before + 1);
		assert.equal(plugin.cancelled.at(-1), plugin.requestIds.at(-1));
		// The adapter is still usable after the late answer has come and gone.
		await new Promise((resolve) => setTimeout(resolve, 350));
		const { json } = await callTool("read_animation", { session_id: SESSION, clip_id: "clip_1" });
		assert.equal(json.method, "read_animation");
	});

	test("an image carried in an error message never reaches the client", async () => {
		const { isError, content } = await callTool("open_animation", { session_id: SESSION, rig_id: "rig_leaky" });
		assert.equal(isError, true);
		assert.doesNotMatch(content[0]?.text ?? "", /iVBORw0KGgo|data:image/);
		assert.match(content[0]?.text ?? "", /UNSUPPORTED_RIG/);
	});

	test("a screenshot is returned as an MCP image block, not as text", async () => {
		const { content, json } = await callTool("preview_animation", {
			session_id: SESSION,
			clip_id: "clip_1",
			time: 0.5,
			capture: true,
		});
		assert.equal(json.capture.status, "ok");
		assert.equal(json.images, undefined);
		assert.equal(content.length, 2);
		assert.deepEqual(content[1], { type: "image", data: PNG, mimeType: "image/png" });
	});

	test("an unknown session is a structured error", async () => {
		const { isError, json } = await callTool("read_animation", { session_id: "e".repeat(16), clip_id: "clip_1" });
		assert.equal(isError, true);
		assert.equal(json.error.code, "SESSION_NOT_FOUND");
	});
});
