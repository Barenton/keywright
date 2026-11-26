import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { BrokerClient } from "../broker/client.js";
import { IMAGE_METHOD, screenResult, scrub } from "../render/image.js";
import { compareVersions, ensureBroker } from "../broker/launcher.js";
import { isValidPairingCode, normalizePairingCode } from "../broker/auth.js";
import { BridgeError, PAIRING_TTL_MS, type SessionInfo } from "../broker/protocol.js";
import { ALONG, MAX_MEASURES, measureResult, trackFor } from "../render/measure.js";
import { MAX_TILE, MAX_VIEWS, MIN_TILE, renderResult, STYLES, VIEWS } from "../render/render.js";

import { studioSession, clipId, time, joint } from "./schemas/common.js";
import { operations } from "./schemas/operations.js";
import { viaNpx } from "../layout.js";
import { VERSION } from "../version.js";

export const ADAPTER_VERSION = VERSION;

/**
 * How to work with Keywright, sent to every MCP app when it connects. The tool descriptions
 * say what each tool does; this says how to direct an animation with them, which an agent
 * otherwise works out by trial: it stops at a clip that validates, or looks at timing
 * without looking at the poses.
 */
export const SERVER_INSTRUCTIONS = `Keywright makes animations for rigs in Roblox Studio. How to work with it:

1. Start with get_workspace. If it, or any result, carries update_needed, tell the person straight away, with what it says to do: until the plugin and the adapter match, tools may fail or ignore options. Use pair_studio only with a code the person gives you. Call inspect_rig before posing: its turns say which way each joint moves for a positive rotation about X, Y and Z.
2. Plan before editing. Write down the key poses, when each happens, and what each must read as: for a kick, the chamber, the contact (leg extended, hips turned over) and the recovery. Use curve clips (format "curves") for motion that should flow, with keys on whole frames (multiples of 1/30 s).
3. Block the key poses first and check them. Then add the in-betweens, overlap, and contacts with the floor (pin, place_on_floor).
4. After every revision, look at it. preview_animation with times at the key moments and render: true gives a pose strip, which shows whether each silhouette reads. With samples and render: true it gives motion paths and a speed plot, which show stops, pops and corners. Use both: a speed plot cannot tell you whether a pose reads, and a pose strip cannot show timing. Use compare_with to see what a revision changed, onion: true to see how a limb travels between poses, and measure to turn a check (a punch's reach, how low the hips sink after a landing) into numbers.
5. validate_animation finds structural errors and measures loops, speeds and feet. Passing it is necessary, not enough. The animation is done when every key moment reads in the pose strip, the motion has no stops you did not plan, feet that should stay planted do, and a loop closes.
6. Save with save_animation under a new name. Replace a clip the person already has only when they ask, and then they approve it in Studio. Tell the person what you made and ask them to play it in the Animation Editor: the pictures are schematics, not the rig's real look.`;


// A result is text, plus at most two images, both only for a preview. One is the picture
// of the pose that the relay draws itself from the sampled joint positions. The other is a
// Studio screenshot, which only a preview that asked for one can produce and only after
// the relay's own check (see image.ts).
function ok(method: string, params: unknown, result: unknown, updateNeeded?: string): CallToolResult {
	const screened = screenResult(method, params, result);
	// Measurements come first: they use the raw sampled positions, which drawing boils down.
	const drawn = method === IMAGE_METHOD ? renderResult(params, measureResult(params, screened.payload)) : { payload: screened.payload };
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
	// A version mismatch leads the result, so that it is not missed.
	const text = updateNeeded !== undefined && drawn.payload !== null && typeof drawn.payload === "object" && !Array.isArray(drawn.payload) ? { update_needed: updateNeeded, ...drawn.payload } : drawn.payload;
	const content: CallToolResult["content"] = [{ type: "text", text: JSON.stringify(text) }];
	for (const image of [drawn.image, screened.image]) {
		if (image !== undefined) content.push({ type: "image", data: image, mimeType: "image/png" });
	}
	return { content };
}

function fail(error: unknown, updateNeeded?: string): CallToolResult {
	const wire =
		error instanceof BridgeError
			? error.toWire()
			: { code: "INTERNAL", message: error instanceof Error ? error.message : String(error) };
	// Errors are passed on as text, so they get the same screening as any other text. A
	// version mismatch goes with them: it is often why a call failed.
	const body = { ...(updateNeeded !== undefined ? { update_needed: updateNeeded } : {}), error: scrub(wire).value };
	return { isError: true, content: [{ type: "text", text: JSON.stringify(body) }] };
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

/**
 * What to tell the agent when a Studio window's plugin is not the adapter's release. A
 * test build's suffix (0.1.0+fault) is not a different release.
 */
export function versionCheck(session: Pick<SessionInfo, "pluginVersion">): { update_needed?: string } {
	const plugin = session.pluginVersion.split("+")[0] ?? "";
	if (plugin === VERSION) return {};
	const older = compareVersions(plugin, VERSION) < 0 ? "plugin" : "adapter";
	const how =
		older === "plugin"
			? viaNpx()
				? "Ask the person to update the plugin: npx -y keywright@latest install-plugin."
				: "Ask the person to update the plugin: node keywright.mjs install-plugin with the latest release, or npm run install:plugin in a source checkout."
			: viaNpx()
				? "Ask the person to reconnect Keywright in their AI app, so that npx starts the latest; if it stays older, to run npx -y keywright@latest setup."
				: "Ask the person to update the adapter: download keywright.mjs from the latest release (in a source checkout, git pull, npm install and npm run build), then reconnect it.";
	return {
		update_needed: `This Studio window's Keywright plugin is ${session.pluginVersion || "unnumbered"} and the adapter is ${VERSION}; the ${older} is older. Tell the person: until they match, tools may fail, and options newer than the ${older} are ignored. ${how}`,
	};
}

export function createAdapter(options: AdapterOptions): McpServer {
	const server = new McpServer({ name: "keywright", version: ADAPTER_VERSION }, { instructions: SERVER_INSTRUCTIONS });
	let client: BrokerClient | undefined;

	const broker = async (): Promise<BrokerClient> => {
		if (!client?.isOpen) client = await ensureBroker(options);
		return client;
	};
	// `signal` is the MCP client's own cancellation of the tool call. It is passed on, so
	// that a call nobody is waiting for stops in Studio too.
	// `asked` is what the agent asked for, when the plugin is sent more than that.
	// Each Studio window's plugin version, by session. A window keeps its version for as
	// long as its session lasts: a plugin that is updated reconnects as a new session.
	const pluginVersions = new Map<string, string>();
	const updateNeeded = async (session: string): Promise<string | undefined> => {
		try {
			if (!pluginVersions.has(session)) {
				const { sessions } = (await (await broker()).request("broker.sessions")) as { sessions: SessionInfo[] };
				for (const known of sessions) pluginVersions.set(known.id, known.pluginVersion);
			}
			const version = pluginVersions.get(session);
			return version === undefined ? undefined : versionCheck({ pluginVersion: version }).update_needed;
		} catch {
			return undefined;
		}
	};
	// Every call to a Studio window carries update_needed while its plugin and this adapter
	// differ, not only get_workspace, so that an agent can't miss telling the person.
	const call = async (method: string, session: string, params: unknown, signal?: AbortSignal, timeoutMs?: number, asked: unknown = params) => {
		try {
			const result = await (await broker()).request(method, params, session, timeoutMs, signal);
			return ok(method, asked, result, await updateNeeded(session));
		} catch (error) {
			return fail(error, await updateNeeded(session));
		}
	};

	server.registerTool(
		"get_workspace",
		{
			description:
				"List connected Roblox Studio sessions with their rigs, working copies and revisions, the current selection, and whether screenshots are available. A session whose plugin is a different version from this adapter carries update_needed, saying what to ask the person to update; every other tool's result for that session carries it too. Tell the person when you see it.",
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
							return { session, ...versionCheck(session), ...(screenResult("get_workspace", {}, answer).payload as object) };
						} catch (error) {
							return { session, ...versionCheck(session), error: error instanceof BridgeError ? error.toWire() : String(error) };
						}
					}),
				);
				return ok("get_workspace", {}, { adapter_version: VERSION, sessions: workspaces });
			} catch (error) {
				return fail(error);
			}
		},
	);

	server.registerTool(
		"pair_studio",
		{
			description:
				"Pair a Studio window with Keywright, once per Studio install. When a person turns on agent access in a Studio that has never been paired, the Keywright panel shows a one-time code, and the person may give it to you. Register only a code the person gave you; never guess one. Codes last 5 minutes and work once. Afterwards the panel says it is connected, and the window appears in get_workspace within a few seconds. Studio remembers the pairing, so this is not needed again.",
			inputSchema: {
				code: z.string().min(1).max(64).describe("The code the Keywright panel shows, as the person gave it. Spaces, dashes and case do not matter."),
			},
		},
		async ({ code }) => {
			try {
				if (!isValidPairingCode(code)) {
					throw new BridgeError("INVALID_ARGUMENT", "That is not a pairing code: codes are 8 to 32 letters and digits.", "Ask the person for the code the Keywright panel shows.");
				}
				await (await broker()).request("broker.pair_register", { code: normalizePairingCode(code) });
				return ok("pair_studio", { code }, {
					registered: true,
					valid_for_seconds: PAIRING_TTL_MS / 1000,
					next: "The Studio window connects on its own within a few seconds. Call get_workspace to see it. If it does not appear, the code may have expired: ask the person to turn agent access off and on for a new one.",
				});
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
				rig_id: z.string().describe("Which rig: a rig_id from get_workspace."),
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
				rig_id: z.string().describe("Which rig: a rig_id from get_workspace."),
				name: z.string().min(1).max(100).optional().describe('Name of the working copy, and the name it is saved under unless save_animation is given another. Default: the source\'s name, or "Untitled" for a blank clip.'),
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
				operations: z.array(z.discriminatedUnion("type", operations)).min(1).max(256).describe("The operations, applied in order. Each is one kind of edit, named by its type."),
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
				style: z
					.enum(STYLES)
					.optional()
					.describe(
						'How the picture draws the rig. "boxes" (default) draws every part as a box of its size: best for contact with the floor and for parts passing through each other. "slim" draws the arms and legs thin along their length, keeping the hands, feet, torso and head as boxes: best for reading limb angles, elbow and knee bends, and arm swings, which bulky boxes hide.',
					),
				onion: z
					.boolean()
					.optional()
					.describe(
						"With times and render: draw the moments over each other in one picture for each view (at most two), the last solid and earlier ones fainter the earlier they are, instead of a filmstrip. Each part in track has its whole arm or leg drawn stronger and its path drawn through the frames, a dot at each numbered in the order of the times. Shows how a limb travels between poses: where an elbow turns round, whether a fist or foot moves in an arc. Pass a few neighbouring times, 3 to 7, and one or two tracked parts; slim style reads best.",
					),
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
				compare_times: z
					.array(z.number().finite().min(0).max(300))
					.min(2)
					.max(8)
					.optional()
					.describe(
						"With compare_with: the other clip's own times, one for each of times, in the same order, for when a move has been retimed. Each column then pairs this clip at a time in times with the other clip at its time here: an impact on frame 11 now with an impact on frame 8 before. To line clips up by a marker, read both clips' marker times with read_animation and pass them. The bottom row is labelled with these times, and each entry of compared gains other_time.",
					),
				track: z
					.array(z.string())
					.max(15)
					.optional()
					.describe(
						"Parts whose place in the rig to report as numbers, for example LeftFoot and RightFoot. Each gets position (x toward the rig's right, y up, z toward its back; forward is negative z), in studs from the root part, and lowest, the height of its lowest point, measured as validate_animation does: a box of the part's size with its corners rounded. With times, each frame after the first also has velocity (studs per second along x, y, z since the frame before) and speed, and the result has ranges: for each part, the least, greatest and difference of x, y, z and lowest over the frames. A foot that is planted keeps the same lowest; in a cycle made on the spot it moves steadily backward while planted.",
					),
				measure: z
					.array(
						z.object({
							part: z.string().min(1).max(64).describe("The part measured, for example RightHand."),
							relative_to: z.string().min(1).max(64).optional().describe("The part it is measured from, for example Head. Default: the root part."),
							along: z
								.enum(ALONG)
								.describe('"forward" (toward where the rig faces at rest), "up" or "right" (the rig\'s right), each in the rig\'s own directions, or "distance", the straight-line distance.'),
						}),
					)
					.min(1)
					.max(MAX_MEASURES)
					.optional()
					.describe(
						"Measure one part from another, or from the root part, along one of the rig's directions, at every time sampled (with time, times or samples). The parts are tracked for you. The result has measured: for each measurement, values (time and studs at each moment), least and greatest (each with its time), and change, the difference between them. Examples: how far a fist reaches past the head at impact ({part: \"RightHand\", relative_to: \"Head\", along: \"forward\"}, with the impact's time among times); how low the hips sink after a foot lands and when they are lowest ({part: \"LowerTorso\", along: \"up\"}); how far a planted foot drifts ({part: \"LeftFoot\", along: \"forward\"} over its stance). To read a value at a marker, include the marker's time in times.",
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
		async ({ studio_session, ...params }, extra) => {
			// The plugin is asked to track the parts measured, as well as any named. The
			// result is shaped by what was asked: only the named parts get onion-skin paths.
			const sent = params.measure ? { ...params, track: trackFor(params.measure, params.track, params.samples !== undefined) } : params;
			return call("preview_animation", studio_session, sent, extra.signal, 60_000, params);
		},
	);

	return server;
}

export async function runAdapter(options: AdapterOptions): Promise<void> {
	const server = createAdapter(options);
	await server.connect(new StdioServerTransport());
}
