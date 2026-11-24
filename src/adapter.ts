import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { BrokerClient } from "./client.js";
import { IMAGE_METHOD, screenResult, scrub } from "./image.js";
import { ensureBroker } from "./launcher.js";
import { BridgeError, type SessionInfo } from "./protocol.js";
import { MAX_TILE, MAX_VIEWS, MIN_TILE, renderResult, VIEWS } from "./render.js";

export const ADAPTER_VERSION = "0.0.0";

// Not named "session_id": Claude Desktop was seen to leave an argument of that name out of
// the calls it sends, while passing the others on. It stays required. A session id changes
// when the plugin reloads, and clip ids are numbered afresh then, so a call that names a
// session from before a reload is refused instead of reaching a different clip.
const studioSession = z.string().describe("Which Studio window to act in: a session id from get_workspace.");
const clipId = z.string().describe("Working copy id from open_animation or get_workspace.");
const vec3 = z.array(z.number().finite()).length(3);

const setPose = z.object({
	type: z.literal("set_pose"),
	joint: z.string().describe("Name of the driven part, for example RightUpperArm."),
	time: z.number().finite().min(0).max(300).describe("Keyframe time in seconds. The keyframe is created if absent."),
	position: vec3.optional().describe("Joint-local offset from the rest pose, in studs."),
	rotation: vec3.optional().describe("Joint-local rotation as Euler angles in degrees, applied in X, Y, Z order."),
	relative: z.boolean().optional().describe("Apply on top of the existing pose instead of replacing it."),
});
const restoreSource = z.object({
	type: z.literal("restore_source").describe("Reset the working copy to the clip it was opened from."),
});

// A result is text, plus at most two images, both only for a preview. One is the picture
// of the pose that the relay draws itself from the sampled joint positions. The other is a
// Studio screenshot, which only a preview that asked for one can produce and only after
// the relay's own check (see image.ts).
function ok(method: string, params: unknown, result: unknown): CallToolResult {
	const screened = screenResult(method, params, result);
	const drawn = method === IMAGE_METHOD ? renderResult(params, screened.payload) : { payload: screened.payload };
	// Studio writes an empty set of joints as an empty list; clients are promised an object.
	const shaped = drawn.payload as { joints?: unknown } | null;
	if (method === IMAGE_METHOD && shaped !== null && typeof shaped === "object" && Array.isArray(shaped.joints) && shaped.joints.length === 0) {
		shaped.joints = {};
	}
	const content: CallToolResult["content"] = [{ type: "text", text: JSON.stringify(drawn.payload) }];
	for (const image of [drawn.image, screened.image]) {
		if (image !== undefined) content.push({ type: "image", data: image, mimeType: "image/png" });
	}
	return { content };
}

function fail(error: unknown): CallToolResult {
	const wire =
		error instanceof BridgeError
			? error.toWire()
			: { code: "INTERNAL", message: error instanceof Error ? error.message : String(error) };
	// Errors are passed on as text, so they get the same screening as any other text.
	return { isError: true, content: [{ type: "text", text: JSON.stringify({ error: scrub(wire).value }) }] };
}

export interface AdapterOptions {
	home: string;
	port: number;
}

export function createAdapter(options: AdapterOptions): McpServer {
	const server = new McpServer({ name: "motion-bridge", version: ADAPTER_VERSION });
	let client: BrokerClient | undefined;

	const broker = async (): Promise<BrokerClient> => {
		if (!client?.isOpen) client = await ensureBroker(options);
		return client;
	};
	// `signal` is the MCP client's own cancellation of the tool call. It is passed on, so
	// that a call nobody is waiting for stops in Studio too.
	const call = async (method: string, session: string, params: unknown, signal?: AbortSignal, timeoutMs?: number) => {
		try {
			return ok(method, params, await (await broker()).request(method, params, session, timeoutMs, signal));
		} catch (error) {
			return fail(error);
		}
	};

	server.registerTool(
		"get_workspace",
		{
			description:
				"List connected Roblox Studio sessions with their rigs, working copies and revisions, the current selection, and whether screenshots are available.",
			inputSchema: {},
			annotations: { readOnlyHint: true },
		},
		async () => {
			try {
				const connection = await broker();
				const { sessions } = (await connection.request("broker.sessions")) as { sessions: SessionInfo[] };
				const workspaces = await Promise.all(
					sessions.map(async (session) => {
						try {
							const answer = await connection.request("get_workspace", {}, session.id);
							return { session, ...(screenResult("get_workspace", {}, answer).payload as object) };
						} catch (error) {
							return { session, error: error instanceof BridgeError ? error.toWire() : String(error) };
						}
					}),
				);
				return ok("get_workspace", {}, { sessions: workspaces });
			} catch (error) {
				return fail(error);
			}
		},
	);

	server.registerTool(
		"inspect_rig",
		{
			description:
				"Describe a rig: joint names, hierarchy, joint class (Motor6D or AnimationConstraint) and rest transforms. Returns a summary unless detail is true.",
			inputSchema: {
				studio_session: studioSession,
				rig_id: z.string(),
				detail: z.boolean().optional().describe("Include per-joint rest transforms and part sizes."),
			},
			annotations: { readOnlyHint: true },
		},
		async ({ studio_session, ...params }, extra) => call("inspect_rig", studio_session, params, extra.signal),
	);

	server.registerTool(
		"open_animation",
		{
			description:
				"Create a working copy to edit: blank, or copied from an existing KeyframeSequence. The source clip is never changed.",
			inputSchema: {
				studio_session: studioSession,
				rig_id: z.string(),
				name: z.string().min(1).max(100).optional(),
				source: z
					.string()
					.max(110)
					.optional()
					.describe(
						'Omit for a blank clip. "selection" copies the KeyframeSequence selected in the Explorer. "saved:" followed by a name copies that saved clip of the rig, as listed by get_workspace.',
					),
			},
		},
		async ({ studio_session, ...params }, extra) => call("open_animation", studio_session, params, extra.signal),
	);

	server.registerTool(
		"read_animation",
		{
			description:
				"Read a working copy. Returns a summary (keyframe times, animated joints, revision). Pose values are returned only for the joints listed.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				joints: z.array(z.string()).max(32).optional(),
				time_from: z.number().finite().min(0).optional(),
				time_to: z.number().finite().min(0).optional(),
				hash: z
					.boolean()
					.optional()
					.describe("Include content_hash, a fingerprint of everything that affects how the clip plays. Two clips with the same fingerprint are the same apart from their names."),
			},
			annotations: { readOnlyHint: true },
		},
		async ({ studio_session, ...params }, extra) => call("read_animation", studio_session, params, extra.signal),
	);

	server.registerTool(
		"edit_animation",
		{
			description:
				"Apply a batch of operations to a working copy atomically. All operations are validated first; if any fails nothing changes. Requires the current revision. One Studio undo reverts the whole batch.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				expected_revision: z.string().describe("Revision from the last read or edit of this clip."),
				operations: z.array(z.discriminatedUnion("type", [setPose, restoreSource])).min(1).max(256),
			},
		},
		async ({ studio_session, ...params }, extra) => call("edit_animation", studio_session, params, extra.signal),
	);

	server.registerTool(
		"save_animation",
		{
			description:
				"Save a copy of a working copy as a new clip for its rig, where Roblox's Animation Editor keeps that rig's clips, so that it can be loaded in the editor. The working copy stays open and unchanged. Nothing already saved is replaced: a name that is taken is refused. One Studio undo removes the saved clip.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				expected_revision: z.string().describe("Revision from the last read or edit of this clip."),
				name: z.string().min(1).max(100).optional().describe("Name for the saved clip. Default: the working copy's name."),
			},
		},
		async ({ studio_session, ...params }, extra) => call("save_animation", studio_session, params, extra.signal),
	);

	server.registerTool(
		"discard_animation",
		{
			description:
				"Remove a working copy that is no longer needed. Saved clips are not affected. One Studio undo brings the working copy back.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				expected_revision: z.string().describe("Revision from the last read or edit of this clip."),
			},
		},
		async ({ studio_session, ...params }, extra) => call("discard_animation", studio_session, params, extra.signal),
	);

	server.registerTool(
		"preview_animation",
		{
			description:
				"Sample a working copy at an exact time and report the joint transforms. The clip is evaluated on a disposable copy of the rig; the rig itself and the camera are never moved. To see the pose, pass render: true: the result then includes a schematic picture drawn from the sampled joint positions, with each part as a box, the rig's left side blue and its right side orange, and a dark mark on the front of the head. It shows the pose, not the rig's real appearance, and is not a Studio screenshot. Studio screenshots (capture: true) are off by default and return capture.status \"unavailable\" with the reason; they are possible only in a test fixture after a person in Studio has approved the scene and camera.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				time: z.number().finite().min(0).max(300),
				render: z.boolean().optional().describe("Include a schematic picture of the pose, drawn from the sampled joint positions."),
				views: z
					.array(z.enum(VIEWS))
					.min(1)
					.max(MAX_VIEWS)
					.optional()
					.describe('Directions to draw the pose from, side by side. Default ["three_quarter"]. "left" and "right" are the rig\'s own sides.'),
				render_size: z.number().int().min(MIN_TILE).max(MAX_TILE).optional().describe("Height of the picture in pixels; each view is square. Default 384."),
				capture: z.boolean().optional().describe("Ask for a Studio screenshot. Off unless approved in Studio; see the tool description."),
				max_edge: z.number().int().min(64).max(1536).optional().describe("Longest edge of the screenshot in pixels. Default 768."),
				joints: z.array(z.string()).max(32).optional().describe("Joints to sample. Default: none."),
				check_placement: z
					.boolean()
					.optional()
					.describe(
						"A check on Studio itself, not needed for animating. Also compare where Studio put each part of the disposable copy with where the joint transforms say it should be. The result then includes placement: the number of parts compared, the largest difference in studs and in degrees, and the part it was on.",
					),
			},
			annotations: { readOnlyHint: true },
		},
		async ({ studio_session, ...params }, extra) => call("preview_animation", studio_session, params, extra.signal, 60_000),
	);

	return server;
}

export async function runAdapter(options: AdapterOptions): Promise<void> {
	const server = createAdapter(options);
	await server.connect(new StdioServerTransport());
}
