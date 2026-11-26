import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { BrokerClient } from "../broker/client.js";
import { IMAGE_METHOD, screenResult, scrub } from "../render/image.js";
import { ensureBroker } from "../broker/launcher.js";
import { BridgeError, type SessionInfo } from "../broker/protocol.js";
import { MAX_TILE, MAX_VIEWS, MIN_TILE, renderResult, VIEWS } from "../render/render.js";

import { studioSession, clipId, time, joint } from "./schemas/common.js";
import { operations } from "./schemas/operations.js";
import { VERSION } from "../version.js";

export const ADAPTER_VERSION = VERSION;


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
	// The same for the counts of a validation that found nothing, whether it was asked for
	// on its own or with an edit.
	const payload = drawn.payload as { counts?: unknown; validation?: { counts?: unknown } } | null;
	const validation = method === "validate_animation" ? payload : method === "edit_animation" ? payload?.validation : undefined;
	if (validation !== null && typeof validation === "object" && Array.isArray(validation.counts) && validation.counts.length === 0) {
		validation.counts = {};
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

// How much text one read may return, in bytes of JSON.
export const DEFAULT_READ_BYTES = 16 * 1024;
export const MAX_READ_BYTES = 64 * 1024;

/**
 * Cuts a read of a clip down to a number of bytes. Poses are dropped from the end first,
 * and a cursor says where the next read should carry on. If the summary alone is too
 * long, its lists of markers and keyframe times are shortened and marked as such.
 */
export function boundRead(result: Record<string, unknown>, offset: number, budget: number): Record<string, unknown> {
	const bounded: Record<string, unknown> = { ...result };
	delete bounded.next_offset;
	const size = () => Buffer.byteLength(JSON.stringify(bounded));
	// A keyframe clip's read lists poses; a curve clip's lists keys.
	const field = Array.isArray(result.keys) ? "keys" : "poses";
	const poses = Array.isArray(result[field]) ? (result[field] as unknown[]) : undefined;
	const counted = result[`${field}_total`];
	const total = typeof counted === "number" ? counted : (poses?.length ?? 0);
	const withPoses = (count: number) => {
		if (!poses) return;
		bounded[field] = poses.slice(0, count);
		if (offset + count < total) bounded.next_cursor = `${String(result.revision)}:${offset + count}`;
		else delete bounded.next_cursor;
	};
	withPoses(poses?.length ?? 0);
	if (poses && size() > budget) {
		// The largest number of poses that fits, and at least one so that a read always moves on.
		let low = 1;
		let high = poses.length;
		while (low < high) {
			const middle = Math.ceil((low + high) / 2);
			withPoses(middle);
			if (size() <= budget) low = middle;
			else high = middle - 1;
		}
		withPoses(low);
	}
	for (const list of ["markers", "keyframe_times"]) {
		while (size() > budget && Array.isArray(bounded[list]) && (bounded[list] as unknown[]).length > 0) {
			const entries = bounded[list] as unknown[];
			bounded[list] = entries.slice(0, Math.floor(entries.length / 2));
			bounded[`${list}_truncated`] = true;
		}
	}
	return bounded;
}

export interface AdapterOptions {
	home: string;
	port: number;
}

export function createAdapter(options: AdapterOptions): McpServer {
	const server = new McpServer({ name: "keywright", version: ADAPTER_VERSION });
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
				'Create a working copy to edit: blank, or copied from an existing clip. The source clip is never changed. A clip is either keyframes (KeyframeSequence: poses at keyframes, each stretch between two eased by one of a few fixed shapes) or curves (CurveAnimation: each joint channel its own curve through a few keys, with tangents, as in the Curve Editor). Curves are the better choice for motion that should flow: speed carries through a key instead of stopping or turning a corner at it, and a person can keep editing the result in the Animation Editor\'s Curve Editor. Studio plays a curve clip at 30 frames a second, going straight from frame to frame, so put keys on whole frames: multiples of 1/30 s (0.0333, 0.0667, 0.1, ...). Opening a keyframe clip with format "curves" converts it: the keys pass through every pose, with smooth tangents, so the motion between poses can differ.',
			inputSchema: {
				studio_session: studioSession,
				rig_id: z.string(),
				name: z.string().min(1).max(100).optional(),
				source: z
					.string()
					.max(110)
					.optional()
					.describe(
						'Omit for a blank clip. "selection" copies the clip selected in the Explorer. "saved:" followed by a name copies that saved clip of the rig, as listed by get_workspace.',
					),
				format: z
					.enum(["keyframes", "curves"])
					.optional()
					.describe('What the working copy is made of. Default: the source\'s format, or keyframes for a blank clip. A curve clip cannot be turned into keyframes.'),
			},
		},
		async ({ studio_session, ...params }, extra) => call("open_animation", studio_session, params, extra.signal),
	);

	server.registerTool(
		"read_animation",
		{
			description:
				"Read a working copy. Returns a summary: format, duration, keyframe times, animated joints, markers, settings, revision, and a count of any content Keywright keeps but does not edit. For the joints listed, a keyframe clip returns poses and a curve clip returns keys: one per channel (rotation.x/y/z in degrees, position.x/y/z in studs) with interpolation and tangents in and out (per second). Only as many as fit are returned; when there are more, next_cursor says so, and passing it back as cursor returns the next part.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				joints: z.array(z.string()).max(32).optional().describe("Joints whose poses to return. Default: none, only the summary."),
				time_from: z.number().finite().min(0).optional().describe("Only keyframes from this time, in seconds."),
				time_to: z.number().finite().min(0).optional().describe("Only keyframes up to this time, in seconds."),
				rotation_format: z.enum(["euler", "quaternion"]).optional().describe("How pose rotations are returned. Default: Euler angles in degrees, X, Y, Z order."),
				cursor: z.string().max(64).optional().describe("next_cursor from an earlier read of the same clip with the same joints and times. Returns the poses after it, without the summary."),
				max_bytes: z
					.number()
					.int()
					.min(1024)
					.max(MAX_READ_BYTES)
					.optional()
					.describe(`Most text to return, in bytes. Default ${DEFAULT_READ_BYTES}.`),
				hash: z
					.boolean()
					.optional()
					.describe("Include content_hash, a fingerprint of everything that affects how the clip plays. Two clips with the same fingerprint are the same apart from their names."),
			},
			annotations: { readOnlyHint: true },
		},
		async ({ studio_session, cursor, max_bytes, ...params }, extra) => {
			try {
				const budget = max_bytes ?? DEFAULT_READ_BYTES;
				const from = cursor === undefined ? undefined : /^(r\d+):(\d+)$/.exec(cursor);
				if (from === null) throw new BridgeError("INVALID_ARGUMENT", "cursor is not one that read_animation gave.", "Read again without a cursor.");
				const offset = from ? Number(from[2]) : 0;
				// No more poses are asked of Studio than could possibly fit.
				const request = { ...params, offset, limit: Math.max(1, Math.floor(budget / 80)), poses_only: from !== undefined };
				const result = (await (await broker()).request("read_animation", request, studio_session, undefined, extra.signal)) as Record<string, unknown>;
				if (from && result.revision !== from[1]) {
					throw new BridgeError("INVALID_ARGUMENT", "The clip has changed since this cursor was given.", "Read again without a cursor.");
				}
				return ok("read_animation", params, boundRead(result, offset, budget));
			} catch (error) {
				return fail(error);
			}
		},
	);

	server.registerTool(
		"edit_animation",
		{
			description:
				"Apply a batch of operations to a working copy atomically. A keyframe clip takes poses, easing, keyframes and smoothing; a curve clip takes keys, tangents, auto_tangents, add_offset, add_noise, aim, clear_floor, clear_keys, copy_pose, mirror, overlap, pin, place_on_floor, reduce_keys and reverse_time. Both take shift_time and scale_time (retiming), markers, the clip's settings and restore_source; each operation's description says which clips it is for. The operations apply in the order given, each to the clip as the ones before it leave it. The whole batch is tried first; if any operation cannot be done, nothing changes and the error names it by its place in the list. Requires the current revision. One Studio undo reverts the whole batch. Only what an operation names is changed.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				expected_revision: z.string().describe("Revision from the last read or edit of this clip."),
				operations: z.array(z.discriminatedUnion("type", operations)).min(1).max(256),
				validate: z
					.boolean()
					.optional()
					.describe("Also run validate_animation's checks, with its default limits, on the clip as the edit leaves it. The result then has validation: valid, the counts of each finding, and the first 10 findings. Saves a call after each edit."),
			},
		},
		async ({ studio_session, ...params }, extra) => call("edit_animation", studio_session, params, extra.signal),
	);

	server.registerTool(
		"validate_animation",
		{
			description:
				"Check a working copy. Errors mean the clip is not structurally sound and cannot be saved: a pose for a joint the rig lacks, two keyframes at one time, two poses for one joint in a keyframe, numbers that are not finite or out of range. Warnings are measurements to look at and never stop a save: a looping clip whose last keyframe does not match its first, a joint moving faster than a limit between two keyframes, a joint driven through forces, content that is kept but not understood. In a curve clip, contact with the floor is also measured at every frame, the floor being the rig's lowest point at rest: a part below it (BELOW_FLOOR; parts are measured as boxes of their size with the corners rounded, as an R15 part's mesh is, and the lower legs, whose boxes reach down beside the ankle in a crouch, are left out), and, while a foot touches the floor (its lowest point no more than 0.4 of floor_studs above it), whether it moves across it, at whichever of its toe, heel and middle of the sole moves least, so a foot rolling over its toe or heel is not moving: fast at a frame (over 3 studs a second coming into it and going out of it) it scuffs (FOOT_SCUFF: a swinging foot that drags or a planted one that skates; each run of such frames is reported with its top speed), creeping for three frames or more it slides (FOOT_SLIDE). A foot passing a little above the floor, as a swing does, touches nothing. In a looping clip made on the spot, where planted feet move back steadily, the floor is taken to move with them, at the most common step of the soles on it, and feet are judged against it: a planted foot is fine, and a swing that skims the floor just before landing is still a scuff. Each finding has a code, the joints and times, the measured value and the limit. At most 50 are listed, with counts of all of them. These are measurements, not a judgement of how the motion looks.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				thresholds: z
					.object({
						loop_rotation_degrees: z.number().positive().optional().describe("How far a looping clip's last keyframe may be from its first, per joint. Default 2."),
						loop_position_studs: z.number().positive().optional().describe("The same for position. Default 0.02."),
						speed_degrees_per_second: z.number().positive().optional().describe("How fast a joint may turn between two keyframes. Default 2000."),
						speed_studs_per_second: z.number().positive().optional().describe("How fast a joint may move between two keyframes. Default 40."),
						floor_studs: z.number().positive().optional().describe("Curve clips: how far a part may go below the floor; a foot within 0.4 of this above it touches the floor. Default 0.1."),
						slide_studs: z.number().positive().optional().describe("Curve clips: how far a planted foot may slide. Default 0.1."),
					})
					.strict()
					.optional()
					.describe("Limits to use in place of the defaults."),
			},
			annotations: { readOnlyHint: true },
		},
		async ({ studio_session, ...params }, extra) => call("validate_animation", studio_session, params, extra.signal),
	);

	server.registerTool(
		"save_animation",
		{
			description:
				"Save a copy of a working copy as a new clip for its rig, where Roblox's Animation Editor keeps that rig's clips, so that it can be loaded in the editor. The working copy stays open and unchanged. Nothing already saved is replaced: a name that is taken is refused. A clip with structural errors (see validate_animation) is refused; warnings never stop a save. One Studio undo removes the saved clip. With replace_source, nothing is saved: instead a person in Studio is asked whether the clip the working copy was opened from may be replaced by it, and the result says pending, approved or rejected. Call again with the same revision to see the outcome.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				expected_revision: z.string().describe("Revision from the last read or edit of this clip."),
				name: z.string().min(1).max(100).optional().describe("Name for the saved clip. Default: the working copy's name."),
				replace_source: z
					.boolean()
					.optional()
					.describe(
						"Propose replacing the clip this working copy was opened from, in place of saving a new one. Only a person can approve it, in the Keywright panel. Refused with SOURCE_CHANGED if that clip has changed since the working copy was opened. A rejection stands for that revision.",
					),
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
				"Sample a working copy at an exact time and report the joint transforms. The clip is evaluated on a disposable copy of the rig; the rig itself and the camera are never moved. To see the pose, pass render: true: the result then includes a schematic picture drawn from the sampled joint positions, with each part as a box, the rig's left side blue and its right side orange, and a dark mark on the front of the head. It shows the pose, not the rig's real appearance, and is not a Studio screenshot. Studio screenshots (capture: true) are off by default and return capture.status \"unavailable\" with the reason.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				time: z.number().finite().min(0).max(300).optional().describe("The time to sample, in seconds. Give this or times."),
				times: z
					.array(z.number().finite().min(0).max(300))
					.min(2)
					.max(8)
					.optional()
					.describe(
						"Several times to sample in one call, in place of time. With render, the picture is a filmstrip: one column for each time in the order given, one row for each view (at most two), all framed alike so that what moves can be seen. The result lists the frames in the same order.",
					),
				samples: z
					.number()
					.int()
					.min(9)
					.max(48)
					.optional()
					.describe(
						"In place of time or times: follow parts over the whole clip, at this many moments evenly spread. The parts are those in track, or the hands, feet, head and hips. The result has motion: for each part, how far it travels (path) and ends from where it began (net); how low its lowest point comes (lowest, measured as validate_animation does) and when (lowest_time); its top speed and when; when it starts and stops moving; holds, the stretches in between where it stands still; the largest change of speed from one moment to the next and when; and bow, how far its path strays from a straight line. Parts that all start and stop together move as one block; a large speed jump is a corner in the motion; no bow is a straight line. With render, the picture shows each part's path over the rig, a dot at every sample, beside a chart of each part's speed across the clip.",
					),
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
				compare_with: z
					.string()
					.max(120)
					.optional()
					.describe(
						'With times: also sample another clip of the same rig at the same times. "source" is the clip this working copy was opened from, "saved:" followed by a name is one of the rig\'s saved clips, anything else is the id of another working copy. The result gains compared: for each time, the largest distance in studs and turn in degrees between where the two clips put the rig\'s parts, and the part furthest apart. With render, the picture has this clip along the top row and the other along the bottom.',
					),
				track: z
					.array(z.string())
					.max(15)
					.optional()
					.describe(
						"Parts whose place in the rig to report as numbers, for example LeftFoot and RightFoot. Each gets position (x toward the rig's right, y up, z toward its back; forward is negative z), in studs from the root part, and lowest, the height of its lowest point, measured as validate_animation does: a box of the part's size with its corners rounded. With times, each frame after the first also has velocity (studs per second along x, y, z since the frame before) and speed, and the result has ranges: for each part, the least, greatest and difference of x, y, z and lowest over the frames. A foot that is planted keeps the same lowest; in a cycle made on the spot it moves steadily backward while planted.",
					),
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
