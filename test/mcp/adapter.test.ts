import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { after, before, describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Broker } from "../../src/broker/broker.js";
import { connectAdapter } from "../../src/broker/client.js";
import { loadOrCreateSecret } from "../../src/broker/state.js";
import { versionCheck } from "../../src/mcp/adapter.js";
import { VERSION } from "../../src/version.js";
import { CLI_PATH, FakePlugin, freePort, PluginError, tempHome } from "../helpers.js";

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
	let bigRevision = 3;
	let port = 0;

	before(async () => {
		port = await freePort();
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
				// Studio writes an empty table as an empty list, as for counts that found nothing.
				if (input.validate === true) return { revision: `r${revision}`, changed: { poses: 1 }, validation: { valid: true, counts: [], issues: [] } };
				return { revision: `r${revision}`, changed: { poses: 1 } };
			}
			if (method === "open_animation" && input.rig_id === "rig_leaky") {
				// A plugin that tries to pass an image along in the text of an error.
				throw new PluginError({ code: "UNSUPPORTED_RIG", message: `see ${PNG}`, hint: `data:image/png;base64,${PNG}` });
			}
			if (method === "read_animation" && input.clip_id === "clip_big") {
				// A clip of 900 poses, returned a page at a time as the plugin does.
				const offset = Number(input.offset ?? 0);
				const poses = Array.from({ length: Math.min(Number(input.limit ?? 400), 900 - offset) }, (_, index) => ({
					joint: "Head",
					time: (offset + index) / 10,
					position: [0, 0, 0],
					rotation: [0, offset + index, 0],
					easing_style: "Linear",
					easing_direction: "In",
				}));
				const summary = input.poses_only === true ? {} : { name: "Big", keyframe_times: [0, 1], markers: [] };
				return { ...summary, clip_id: "clip_big", revision: `r${bigRevision}`, poses, poses_total: 900 };
			}
			if (method === "validate_animation") {
				// Studio writes an empty set of counts as an empty list.
				return { valid: true, errors: 0, warnings: 0, counts: [], issues: [], thresholds: input.thresholds ?? null };
			}
			if (method === "preview_animation") {
				// This plugin always sends an image, asked or not, so the relay's checks are what is tested.
				// "clip_slow" takes long enough for the caller to give up on it.
				if (input.clip_id === "clip_slow") await new Promise((resolve) => setTimeout(resolve, 400));
				// For "clip_cut" the image is cut off at the end, and reported with the size it then has.
				const whole = Buffer.from(PNG, "base64");
				const data = input.clip_id === "clip_cut" ? whole.subarray(0, whole.length - 12) : whole;
				const capture = { status: "ok", format: "png", width: 1, height: 1, bytes: data.length };
				// A pose is included when a picture was asked for: two boxes, one for each side.
				const pose = {
					parts: [
						{ name: "LeftHand", size: [1, 1, 1], cframe: [-3, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1] },
						{ name: "RightHand", size: [1, 1, 1], cframe: [3, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1] },
					],
				};
				return {
					clip_id: input.clip_id,
					time: input.time,
					capture,
					images: [{ png_base64: data.toString("base64") }],
					// As Studio encodes an empty table.
					joints: [],
					...(input.render === true ? { pose } : {}),
					// Each tracked part, as the plugin places it: the head above, a hand in front.
					...(Array.isArray(input.track)
						? { parts: Object.fromEntries(input.track.map((name) => [name, { position: name === "Head" ? [0, 2, 0] : [1, 1, -1.5] }])) }
						: {}),
				};
			}
			return { method, params };
		});

		mcp = new Client({ name: "adapter-test", version: "0" });
		await mcp.connect(
			new StdioClientTransport({
				command: process.execPath,
				args: [CLI_PATH],
				env: { ...process.env, KEYWRIGHT_HOME: temp.home, KEYWRIGHT_PORT: String(port) } as Record<string, string>,
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

	test("tells the app how to work with Keywright when it connects", () => {
		const instructions = mcp.getInstructions() ?? "";
		assert.match(instructions, /pose strip/);
		assert.match(instructions, /Passing it is necessary, not enough/);
		// Every tool it names is one the adapter offers.
		for (const name of instructions.match(/\b[a-z]+_[a-z_]+\b/g) ?? []) {
			if (name.endsWith("_animation") || name.startsWith("get_") || name.startsWith("inspect_") || name.startsWith("pair_")) {
				assert.ok(["get_workspace", "pair_studio", "inspect_rig", "open_animation", "read_animation", "edit_animation", "validate_animation", "save_animation", "discard_animation", "preview_animation"].includes(name), name);
			}
		}
	});

	test("lists the tools with input schemas", async () => {
		const { tools } = await mcp.listTools();
		assert.deepEqual(
			tools.map((tool) => tool.name).sort(),
			["discard_animation", "edit_animation", "get_workspace", "inspect_rig", "open_animation", "pair_studio", "preview_animation", "read_animation", "save_animation", "validate_animation"],
		);
		// A picture and a save are both asked for through documented inputs.
		const properties = (name: string) => Object.keys((tools.find((tool) => tool.name === name)?.inputSchema.properties ?? {}) as object);
		assert.ok(["render", "views", "render_size", "check_placement", "times", "track", "compare_with", "samples", "style", "measure", "onion", "compare_times"].every((key) => properties("preview_animation").includes(key)));
		assert.deepEqual(properties("save_animation").sort(), ["clip_id", "expected_revision", "name", "replace_source", "studio_session"]);
		// An edit can be checked in the same call.
		assert.deepEqual(properties("edit_animation").sort(), ["clip_id", "expected_revision", "operations", "studio_session", "validate"]);
		// No tool approves a replacement: that is for a person in Studio.
		assert.equal(tools.some((tool) => /approve|decide|accept/.test(tool.name)), false);
		for (const tool of tools) assert.equal(tool.inputSchema.type, "object");
	});

	test("pair_studio registers the code a Studio window shows, so that the window can pair", async () => {
		const shown = "PQRS234WXY";
		const registered = await callTool("pair_studio", { code: "pqrs-234 wxy" });
		assert.equal(registered.isError, false);
		assert.equal(registered.json.registered, true);
		assert.equal(registered.json.valid_for_seconds, 300);
		const second = await FakePlugin.pair(port, shown, "e".repeat(16));
		try {
			const workspace = await callTool("get_workspace", {});
			assert.ok((workspace.json.sessions as Array<{ session: { id: string } }>).some((entry) => entry.session.id === "e".repeat(16)));
		} finally {
			second.close();
		}
	});

	test("pair_studio refuses what cannot be a code, before the broker hears of it", async () => {
		const refused = await callTool("pair_studio", { code: "abc" });
		assert.equal(refused.isError, true);
		assert.equal(refused.json.error.code, "INVALID_ARGUMENT");
	});

	test("edit_animation publishes the same operations the plugin applies", async () => {
		const { tools } = await mcp.listTools();
		const edit = tools.find((tool) => tool.name === "edit_animation");
		const schema = edit?.inputSchema.properties as { operations?: { items?: { oneOf?: unknown[]; anyOf?: unknown[] } } } | undefined;
		const variants = (schema?.operations?.items?.oneOf ?? schema?.operations?.items?.anyOf ?? []) as Array<{ properties: { type: { const: string } } }>;
		const published = variants.map((variant) => variant.properties.type.const).sort();
		const opsIn = (folder: string) => {
			const dir = fileURLToPath(new URL(`../../../plugin/src/Editing/${folder}/`, import.meta.url));
			return readdirSync(dir)
				.filter((file) => file.endsWith(".luau"))
				.flatMap((file) => [...readFileSync(`${dir}${file}`, "utf8").matchAll(/^Ops\.(\w+) = \{/gm)].map((match) => match[1] as string));
		};
		const keyframes = opsIn("KeyframeEdit");
		// Each operation is a module field, `Ops.name = {`, in the folder for its kind of clip.
		const curves = opsIn("CurveEdit");
		assert.equal(keyframes.length, 15);
		assert.equal(curves.length, 22);
		const applied = [...new Set([...keyframes, ...curves])].sort();
		assert.deepEqual(published, applied);
		// Which way each easing direction goes is spelt out where a client will read it.
		assert.match(JSON.stringify(edit?.inputSchema), /In starts slowly and ends fast; Out starts fast and ends slowly/);
	});

	test("an edit checked in the same call gives its counts as an object", async () => {
		const result = await mcp.callTool({
			name: "edit_animation",
			arguments: {
				studio_session: SESSION,
				clip_id: "clip_1",
				expected_revision: `r${revision}`,
				validate: true,
				operations: [{ type: "set_key", joint: "Head", time: 0, rotation: [0, 0, 0] }],
			},
		});
		const payload = JSON.parse((result.content as Array<{ text: string }>)[0]?.text ?? "{}") as { validation?: { counts?: unknown } };
		assert.deepEqual(payload.validation?.counts, {});
	});

	test("edit_animation refuses an operation it does not publish, before Studio hears of it", async () => {
		const before = plugin.received.length;
		const start = revision;
		const refused = await mcp.callTool({
			name: "edit_animation",
			arguments: { studio_session: SESSION, clip_id: "clip_1", expected_revision: `r${start}`, operations: [{ type: "explode", time: 0 }] },
		});
		assert.equal(refused.isError, true);
		const cubic = await mcp.callTool({
			name: "edit_animation",
			arguments: {
				studio_session: SESSION,
				clip_id: "clip_1",
				expected_revision: `r${revision}`,
				operations: [{ type: "set_easing", joint: "Head", time_from: 0, time_to: 1, easing_style: "Cubic" }],
			},
		});
		assert.equal(cubic.isError, true);
		assert.equal(plugin.received.length, before);
		// Operations it does publish go through, several kinds in one batch.
		const accepted = await callTool("edit_animation", {
			studio_session: SESSION,
			clip_id: "clip_1",
			expected_revision: `r${revision}`,
			operations: [
				{ type: "scale_time", time_from: 0, time_to: 1, factor: 2 },
				{ type: "set_marker", time: 1, name: "Step" },
				{ type: "set_properties", loop: true },
			],
		});
		assert.equal(accepted.isError, false);
		assert.equal(accepted.json.revision, `r${start + 1}`);
		assert.equal(plugin.received.length, before + 1);
	});

	test("get_workspace merges broker sessions with each session's workspace", async () => {
		const { json, isError } = await callTool("get_workspace", {});
		assert.equal(isError, false);
		assert.equal(json.sessions.length, 1);
		assert.equal(json.sessions[0].session.id, SESSION);
		assert.equal(json.sessions[0].rigs[0].rig_id, "rig_1");
		assert.equal(json.adapter_version, VERSION);
		// The stand-in plugin reports a version that is not this release's.
		assert.match(json.sessions[0].update_needed, /plugin is test and the adapter is/);
	});

	test("studio_session routes the call and is not forwarded as a parameter", async () => {
		const { json } = await callTool("inspect_rig", { studio_session: SESSION, rig_id: "rig_1", detail: true });
		// The test plugin's version differs from the adapter's, so update_needed leads the result.
		const { update_needed, ...rest } = json;
		assert.match(update_needed, /plugin is test/);
		assert.deepEqual(rest, { method: "inspect_rig", params: { rig_id: "rig_1", detail: true } });
	});

	test("a stale revision comes back as a structured error and a fresh one succeeds", async () => {
		const edit = (expected: string) =>
			callTool("edit_animation", {
				studio_session: SESSION,
				clip_id: "clip_1",
				expected_revision: expected,
				operations: [{ type: "set_pose", joint: "RightUpperArm", time: 0.5, rotation: [0, 0, 90] }],
			});
		const start = revision;
		const first = await edit(`r${start}`);
		assert.equal(first.isError, false);
		assert.equal(first.json.revision, `r${start + 1}`);
		const stale = await edit(`r${start}`);
		assert.equal(stale.isError, true);
		assert.equal(stale.json.error.code, "REVISION_CONFLICT");
		assert.equal(stale.json.error.hint, "Read the clip again and retry.");
	});

	test("invalid input is rejected by the adapter before it reaches Studio", async () => {
		const before = plugin.received.length;
		const result = await mcp.callTool({
			name: "edit_animation",
			arguments: {
				studio_session: SESSION,
				clip_id: "clip_1",
				expected_revision: "r2",
				operations: [{ type: "set_pose", joint: "RightUpperArm", time: -1 }],
			},
		});
		assert.equal(result.isError, true);
		assert.equal(plugin.received.length, before);
	});

	test("an image that was not asked for never reaches the client", async () => {
		const preview = await callTool("preview_animation", { studio_session: SESSION, clip_id: "clip_1", time: 0.5 });
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
			studio_session: SESSION,
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
			.callTool({ name: "preview_animation", arguments: { studio_session: SESSION, clip_id: "clip_slow", time: 0.5, capture: true } }, undefined, {
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
		const { json } = await callTool("read_animation", { studio_session: SESSION, clip_id: "clip_1" });
		assert.equal(json.method, "read_animation");
	});

	test("a long read comes in parts that join up, each within the size asked for", async () => {
		const read = (extra: Record<string, unknown>) => callTool("read_animation", { studio_session: SESSION, clip_id: "clip_big", joints: ["Head"], ...extra });
		const first = await read({});
		assert.equal(first.isError, false);
		assert.equal(first.json.name, "Big");
		assert.ok(Buffer.byteLength(first.content[0]?.text ?? "") <= 16384);
		assert.ok(first.json.poses.length > 0 && first.json.poses.length < 900);

		const seen: number[] = first.json.poses.map((pose: { rotation: number[] }) => pose.rotation[1]);
		let cursor: string | undefined = first.json.next_cursor;
		let pages = 1;
		while (cursor !== undefined) {
			const next = await read({ cursor, max_bytes: 8192 });
			assert.equal(next.isError, false);
			assert.ok(Buffer.byteLength(next.content[0]?.text ?? "") <= 8192);
			// Later parts carry the poses and not the summary again.
			assert.equal(next.json.name, undefined);
			seen.push(...next.json.poses.map((pose: { rotation: number[] }) => pose.rotation[1]));
			cursor = next.json.next_cursor;
			pages += 1;
			assert.ok(pages < 100);
		}
		assert.deepEqual(seen, Array.from({ length: 900 }, (_, index) => index));

		// A cursor from before the clip changed is refused, not answered with the wrong part.
		const stale = first.json.next_cursor as string;
		bigRevision += 1;
		const refused = await read({ cursor: stale });
		assert.equal(refused.isError, true);
		assert.equal(refused.json.error.code, "INVALID_ARGUMENT");
		assert.match(refused.json.error.message, /changed since this cursor/);
		const invented = await read({ cursor: "page 2" });
		assert.equal(invented.isError, true);
		assert.equal(invented.json.error.code, "INVALID_ARGUMENT");
	});

	test("validate_animation passes limits on and gives counts as an object", async () => {
		const result = await callTool("validate_animation", { studio_session: SESSION, clip_id: "clip_1", thresholds: { loop_rotation_degrees: 5 } });
		assert.equal(result.isError, false);
		assert.deepEqual(result.json.counts, {});
		assert.deepEqual(result.json.thresholds, { loop_rotation_degrees: 5 });
		// A limit that does not exist is refused before Studio hears of it.
		const before = plugin.received.length;
		const refused = await mcp.callTool({ name: "validate_animation", arguments: { studio_session: SESSION, clip_id: "clip_1", thresholds: { speed: 1 } } });
		assert.equal(refused.isError, true);
		assert.equal(plugin.received.length, before);
	});

	test("a read of a window whose plugin differs says so", async () => {
		const { json } = await callTool("read_animation", { studio_session: SESSION, clip_id: "clip_big" });
		assert.match(json.update_needed, /plugin is test/);
	});

	test("an error for a window whose plugin differs says so too", async () => {
		const { isError, content } = await callTool("open_animation", { studio_session: SESSION, rig_id: "rig_leaky" });
		assert.equal(isError, true);
		assert.match(JSON.parse(content[0]?.text ?? "{}").update_needed, /options newer than the/);
	});

	test("an image carried in an error message never reaches the client", async () => {
		const { isError, content } = await callTool("open_animation", { studio_session: SESSION, rig_id: "rig_leaky" });
		assert.equal(isError, true);
		assert.doesNotMatch(content[0]?.text ?? "", /iVBORw0KGgo|data:image/);
		assert.match(content[0]?.text ?? "", /UNSUPPORTED_RIG/);
	});

	test("a measurement asks the plugin to track its parts and is worked out from their positions", async () => {
		const { json } = await callTool("preview_animation", {
			studio_session: SESSION,
			clip_id: "clip_1",
			time: 0.5,
			track: ["LeftFoot"],
			measure: [{ part: "RightHand", relative_to: "Head", along: "forward" }],
		});
		const sent = plugin.received.at(-1)?.params as { track?: string[] };
		assert.deepEqual(sent.track, ["LeftFoot", "RightHand", "Head"]);
		// The test plugin reports version "test", so every result says an update is needed.
		assert.match(json.update_needed, /plugin is test and the adapter is .*Tell the person/);
		assert.deepEqual(json.measured, [
			{ part: "RightHand", relative_to: "Head", along: "forward", values: [[0.5, 1.5]], least: { value: 1.5, time: 0.5 }, greatest: { value: 1.5, time: 0.5 }, change: 0 },
		]);
	});

	test("a picture of the pose is drawn by the relay and returned as an image block", async () => {
		const { content, json } = await callTool("preview_animation", {
			studio_session: SESSION,
			clip_id: "clip_1",
			time: 0.5,
			render: true,
			views: ["front", "top"],
			render_size: 128,
		});
		assert.equal(content.length, 2);
		assert.equal(content[1]?.type, "image");
		assert.equal(content[1]?.mimeType, "image/png");
		const png = Buffer.from(content[1]?.data ?? "", "base64");
		assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], [256, 128]);
		assert.equal(json.pose, undefined);
		assert.equal(json.render.status, "ok");
		assert.deepEqual(json.render.views, ["front", "top"]);
		assert.match(json.render.legend, /not a Studio screenshot/);
		// The plugin was asked for the pose, and the screenshot it volunteered was still dropped.
		const sent = plugin.received.at(-1)?.params as { render?: boolean };
		assert.equal(sent.render, true);
		assert.equal(json.capture.status, "unavailable");

		// Without asking, no picture is drawn and no pose data is passed on.
		const plain = await callTool("preview_animation", { studio_session: SESSION, clip_id: "clip_1", time: 0.5 });
		assert.equal(plain.content.length, 1);
		// An empty set of joints reaches the client as an object, whatever Studio sent.
		assert.deepEqual(plain.json.joints, {});
		assert.equal(plain.json.render, undefined);
		assert.equal(plain.json.pose, undefined);

		// Asked for both, the drawn picture comes first and the Studio screenshot second.
		const both = await callTool("preview_animation", { studio_session: SESSION, clip_id: "clip_1", time: 0.5, render: true, capture: true });
		assert.equal(both.content.length, 3);
		assert.notEqual(both.content[1]?.data, PNG);
		assert.equal(both.content[2]?.data, PNG);
	});

	test("a screenshot is returned as an MCP image block, not as text", async () => {
		const { content, json } = await callTool("preview_animation", {
			studio_session: SESSION,
			clip_id: "clip_1",
			time: 0.5,
			capture: true,
		});
		assert.equal(json.capture.status, "ok");
		assert.equal(json.images, undefined);
		assert.equal(content.length, 2);
		assert.deepEqual(content[1], { type: "image", data: PNG, mimeType: "image/png" });
	});

	test("every tool that acts in Studio requires studio_session, and none takes session_id", async () => {
		const { tools } = await mcp.listTools();
		for (const tool of tools) {
			const schema = tool.inputSchema as { properties?: Record<string, unknown>; required?: string[] };
			assert.equal(Object.hasOwn(schema.properties ?? {}, "session_id"), false, tool.name);
			// These two talk to the broker, not to one Studio window.
			if (tool.name !== "get_workspace" && tool.name !== "pair_studio") assert.ok(schema.required?.includes("studio_session"), tool.name);
		}
		// A call without it is refused before anything is sent to Studio.
		const refused = await mcp.callTool({ name: "read_animation", arguments: { clip_id: "clip_1" } });
		assert.equal(refused.isError, true);
		assert.match((refused.content as Content)[0]?.text ?? "", /studio_session/);
	});

	test("an unknown session is a structured error", async () => {
		const { isError, json } = await callTool("read_animation", { studio_session: "e".repeat(16), clip_id: "clip_1" });
		assert.equal(isError, true);
		assert.equal(json.error.code, "SESSION_NOT_FOUND");
	});
});

test("a plugin of another release is pointed out, with which side to update", () => {
	const session = (pluginVersion: string) => ({ id: "0123456789abcdef", placeName: "Place", placeId: 0, pluginVersion });
	assert.deepEqual(versionCheck(session(VERSION)), {});
	assert.deepEqual(versionCheck(session(`${VERSION}+fault`)), {}, "a test build of this release is this release");
	assert.match(versionCheck(session("0.0.1")).update_needed ?? "", /the plugin is older.*install:plugin/);
	assert.match(versionCheck(session("999.0.0")).update_needed ?? "", /the adapter is older.*git pull/);
	assert.match(versionCheck(session("")).update_needed ?? "", /plugin is unnumbered.*the plugin is older/);
});
