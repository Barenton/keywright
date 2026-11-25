import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { BrokerClient } from "../broker/client.js";
import { IMAGE_METHOD, screenResult, scrub } from "../render/image.js";
import { ensureBroker } from "../broker/launcher.js";
import { BridgeError, type SessionInfo } from "../broker/protocol.js";
import { MAX_TILE, MAX_VIEWS, MIN_TILE, renderResult, VIEWS } from "../render/render.js";

export const ADAPTER_VERSION = "0.0.0";

// Not named "session_id": Claude Desktop was seen to leave an argument of that name out of
// the calls it sends, while passing the others on. It stays required. A session id changes
// when the plugin reloads, and clip ids are numbered afresh then, so a call that names a
// session from before a reload is refused instead of reaching a different clip.
const studioSession = z.string().describe("Which Studio window to act in: a session id from get_workspace.");
const clipId = z.string().describe("Working copy id from open_animation or get_workspace.");
const vec3 = z.array(z.number().finite()).length(3);

const time = (what: string) => z.number().finite().min(0).max(300).describe(what);
const joint = z.string().describe("Name of the driven part, for example RightUpperArm.");
// The parts of an R15 rig that a joint drives.
const r15Part = z.enum(["LowerTorso", "UpperTorso", "Head", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot"]);
const position = vec3.optional().describe("Joint-local offset from the rest pose, in studs.");
const rotation = vec3.optional().describe("Joint-local rotation as Euler angles in degrees, applied in X, Y, Z order.");
const quaternion = z
	.array(z.number().finite())
	.length(4)
	.optional()
	.describe("Joint-local rotation as a quaternion (x, y, z, w) of length 1, in place of rotation.");
const rangeFrom = time("Start of the time range in seconds. Keyframes at the ends are included.");
const rangeTo = time("End of the time range in seconds.");
// As measured in Studio on a jump: Out covers most of the distance early and slows into
// the next pose; In starts slowly and arrives fast.
const easingStyle = z
	.enum(["Linear", "Constant", "Elastic", "CubicV2", "Bounce"])
	.optional()
	.describe("How the joint moves from this pose to its next one. A pose's easing shapes the stretch that starts at it, not the one that ends at it. The deprecated Cubic style is kept where a clip has it but cannot be set.");
const easingDirection = z
	.enum(["In", "Out", "InOut"])
	.optional()
	.describe("In starts slowly and ends fast; Out starts fast and ends slowly; InOut is slow at both ends. For a jump, the rise is Out and the fall is In.");
const markerName = z.string().min(1).max(100);

// Every operation of edit_animation. A batch applies them in the order given.
const operations = [
	z.object({
		type: z.literal("set_pose").describe("Set a joint's pose at a time. The keyframe is created if there is none within a millisecond."),
		joint,
		time: time("Keyframe time in seconds."),
		position,
		rotation,
		quaternion,
		relative: z.boolean().optional().describe("Apply on top of the existing pose instead of replacing it."),
		easing_style: easingStyle,
		easing_direction: easingDirection,
	}),
	z.object({
		type: z.literal("remove_pose").describe("Remove a joint's pose from a keyframe, so that the joint is no longer keyed there."),
		joint,
		time: time("Time of the keyframe in seconds."),
	}),
	z.object({
		type: z.literal("offset_pose").describe("Apply an offset on top of every existing pose of a joint in a time range."),
		joint,
		time_from: rangeFrom,
		time_to: rangeTo,
		position,
		rotation,
		quaternion,
	}),
	z.object({
		type: z.literal("set_easing").describe("Set the easing of every existing pose of a joint in a time range."),
		joint,
		time_from: rangeFrom,
		time_to: rangeTo,
		easing_style: easingStyle,
		easing_direction: easingDirection,
	}),
	z.object({
		type: z.literal("add_keyframe").describe("Add an empty keyframe. Refused if there is one within a millisecond."),
		time: time("Time of the new keyframe in seconds."),
		hold: z
			.boolean()
			.optional()
			.describe(
				"Key every joint the clip moves at the pose it already has at this time, as Studio plays it, so that the clip passes through the same pose there. Between keyframes the motion stays the same only for joints whose easing is Linear or Constant; for any other easing the result lists the joint under held[].motion_changed, because splitting an eased stretch in two changes its shape. At most 8 per batch.",
			),
	}),
	z.object({
		type: z.literal("remove_keyframe").describe("Remove a keyframe with everything in it."),
		time: time("Time of the keyframe in seconds."),
	}),
	z.object({
		type: z.literal("move_keyframe").describe("Move one keyframe to another time. Refused if a keyframe is already there."),
		time: time("Time of the keyframe in seconds."),
		to: time("Its new time in seconds."),
	}),
	z.object({
		type: z.literal("duplicate_keyframe").describe("Copy a keyframe, with its poses and markers, to another time. Refused if a keyframe is already there."),
		time: time("Time of the keyframe to copy, in seconds."),
		to: time("Time of the copy in seconds."),
	}),
	z.object({
		type: z
			.literal("shift_time")
			.describe(
				"Move every keyframe in a time range by the same amount; in a curve clip, every key of every joint and every marker, each onto the nearest whole frame. Refused if one would land on or pass a key or keyframe outside the range.",
			),
		time_from: rangeFrom,
		time_to: rangeTo,
		offset: z.number().finite().describe("Seconds to move by; negative moves earlier."),
	}),
	z.object({
		type: z
			.literal("scale_time")
			.describe(
				"Stretch or squeeze the keyframes in a time range, to make that part of the move slower or faster. In a curve clip, every key of every joint and every marker in the range, each onto the nearest whole frame, with tangents scaled so the curves keep their shape; keys squeezed onto one frame are joined into one, and the result counts keys_merged with first_merge_at. Refused if one would land on or pass a key or keyframe outside the range, unless ripple carries those along.",
			),
		time_from: rangeFrom,
		time_to: rangeTo,
		factor: z.number().min(0.01).max(100).describe("2 makes the range twice as long, 0.5 half as long."),
		anchor: time("The time that stays where it is. Default: time_from.").optional(),
		ripple: z
			.boolean()
			.optional()
			.describe("Also move everything after the range by as much as its end moves, so the rest of the clip keeps its own timing and the clip grows or shrinks. Default false."),
	}),
	z.object({
		type: z
			.literal("reverse_time")
			.describe(
				"Curve clips only. Play a time range backward: each key at time t moves to time_from + time_to - t, with its tangents turned round, and markers with them. A get-up reversed is a fall; a reach reversed is a return.",
			),
		time_from: rangeFrom,
		time_to: rangeTo,
	}),
	z.object({
		type: z.literal("set_properties").describe("Change the clip's own settings. Give at least one."),
		name: z.string().min(1).max(100).optional(),
		loop: z.boolean().optional(),
		priority: z.enum(["Idle", "Movement", "Action", "Action2", "Action3", "Action4", "Core"]).optional(),
	}),
	z.object({
		type: z.literal("set_marker").describe("Add a marker to the keyframe at a time, or change its value. The keyframe is created if absent."),
		time: time("Time of the keyframe in seconds."),
		name: markerName,
		value: z.string().max(200).optional().describe("Default: empty."),
	}),
	z.object({
		type: z.literal("remove_marker").describe("Remove a marker from the keyframe at a time."),
		time: time("Time of the keyframe in seconds."),
		name: markerName,
	}),
	z.object({
		type: z
			.literal("smooth_motion")
			.describe(
				"Run one smooth curve through each joint's keys in a time range and write it out as a pose at every step, replacing those keys. Roblox eases each stretch between two keys by itself, so a move made of several eased stretches stops at every key and one made of straight stretches turns a corner at every key. The curve instead carries speed through a key the motion passes on its way, comes to rest only where the motion turns round, and never goes past a key. Block out the move with a few keys per joint, then smooth it. Keyframes that hold markers are kept. Joints with fewer than two keys in the range are left as they are.",
			),
		time_from: rangeFrom,
		time_to: rangeTo,
		joints: z.array(z.string()).min(1).max(32).optional().describe("The joints to smooth. Default: every joint the clip moves."),
		rate: z.number().int().min(10).max(60).optional().describe("Poses written per second. Default 30."),
		snap_at: z
			.array(time("A key time."))
			.max(16)
			.optional()
			.describe("Key times that are struck, not eased into: the motion arrives there fast and stops dead, as a fist on what it hits."),
		loop: z.boolean().optional().describe("Carry speed across from the last key to the first. Default: true when the clip loops and the range is the whole clip."),
	}),
	z.object({
		type: z
			.literal("set_key")
			.describe("Curve clips only. Put a key at a time on a joint's rotation curves, position curves, or both; a key already within a millisecond is changed. A new key starts with flat tangents; run auto_tangents afterwards for smooth motion, or set them with set_tangent."),
		joint,
		time: time("Key time in seconds."),
		rotation: vec3.optional().describe("Joint-local rotation as Euler angles in degrees, X, Y, Z order, each its own curve."),
		position: vec3.optional().describe("Joint-local offset from rest, in studs."),
		interpolation: z
			.enum(["Cubic", "Linear", "Constant"])
			.optional()
			.describe("How the stretch from this key to the next is played: Cubic follows the tangents, Linear is straight, Constant holds. Default Cubic for a new key."),
	}),
	z.object({
		type: z.literal("remove_key").describe("Curve clips only. Remove a joint's keys at a time."),
		joint,
		time: time("Key time in seconds."),
		channels: z.array(z.enum(["rotation", "position"])).min(1).max(2).optional().describe("Default: both."),
	}),
	z.object({
		type: z
			.literal("set_tangent")
			.describe("Curve clips only. Set the slope of one channel's curve as it arrives at (in) and leaves (out) a key: how fast the value is changing there. 0 is at rest. Leaving with out makes the stretch after the key cubic."),
		joint,
		time: time("Key time in seconds."),
		channel: z.enum(["rotation.x", "rotation.y", "rotation.z", "position.x", "position.y", "position.z"]),
		in: z.number().finite().optional().describe("Degrees per second for rotation, studs per second for position."),
		out: z.number().finite().optional().describe("Degrees per second for rotation, studs per second for position."),
	}),
	z.object({
		type: z
			.literal("auto_tangents")
			.describe("Curve clips only. Give every key in a time range the tangents of one smooth curve through its channel's keys: a key the motion passes on its way is passed at speed, a key where it turns round is come to rest at, and nothing goes past a key. Keys in the range become Cubic. The usual last step after placing keys."),
		time_from: rangeFrom,
		time_to: rangeTo,
		joints: z.array(z.string()).min(1).max(32).optional().describe("Default: every joint."),
		snap_at: z
			.array(time("A key time."))
			.max(16)
			.optional()
			.describe("Key times that are struck, not eased into: the motion arrives fast and stops dead, as a fist on what it hits."),
		loop: z.boolean().optional().describe("Carry speed across from the last key to the first. Default: true when the clip loops and the range is the whole clip."),
	}),
	z.object({
		type: z
			.literal("pin")
			.describe(
				"Curve clips only. Hold a foot or hand in place over a time range, or put it somewhere and hold it there, by turning the limb's three joints at every frame: a planted foot stays put while the hips move, a hand stays on a wall while the body leans. The knee or elbow bends the way it bends and keeps pointing as it was animated unless pole is given. The hips and everything else are left as they are. The limb's rotation keys in the range are replaced by one key a frame, with smooth tangents; outside the range the clip is unchanged. The result counts frames_pinned and, if the hips went too far for the limb to reach, frames_out_of_reach, largest_miss_studs, and out_of_reach_from and out_of_reach_to: the first and last of those frames, in seconds, where the hips are to be brought nearer. For a landing, hold the pose the foot settles in (at the end of the range), not the one it touches down in, or it is held where it first touched, often still in the air. End the range, and any blend_out, where the foot leaves the floor: easing out while it is still down lets it slide.",
			),
		part: z.enum(["LeftFoot", "RightFoot", "LeftHand", "RightHand"]).describe("The end of the limb to hold."),
		time_from: time("Start of the range in seconds."),
		time_to: time("End of the range in seconds. Must not be past the end of the clip."),
		at: time("The time whose pose is held: the part stays where it is then. Default time_from.").optional(),
		position: vec3
			.optional()
			.describe("Where the part's middle is to be instead, in studs from the root part: x toward the rig's right, y up, z toward its back. With relative_to, in studs from that part's middle along its own directions instead."),
		relative_to: r15Part
			.optional()
			.describe("Hold the part against another part instead of in place, re-placed at every frame as that part moves: a hand on the chest stays on the chest while the body bends, a hand on a knee stays on it as the knee rises. Without position, the part keeps where it was against that part at `at`. Not a part of the limb itself."),
		hold: z
			.enum(["full", "position"])
			.optional()
			.describe("full (default) holds the part's position and rotation, as a foot flat on the ground. position holds only where the ankle or wrist is, and the foot or hand keeps its own animated turn."),
		pole: vec3.optional().describe("A point the knee or elbow is to point toward, in the same space as position (so also against relative_to when given)."),
		blend_in: z.number().finite().min(0).max(2).optional().describe("Seconds before time_from over which the limb eases from its own motion into the hold. While easing in or out, the part travels straight from where its own motion has it to where it is held, turning evenly between the two. Default 0."),
		blend_out: z.number().finite().min(0).max(2).optional().describe("Seconds after time_to over which it eases back out. Default 0."),
	}),
	z.object({
		type: z
			.literal("mirror")
			.describe(
				"Curve clips only. Mirror motion across the rig's middle, from its left side to its right. flip turns the whole clip into its mirror image: a punch with the right hand becomes the same punch with the left, the hips' and chest's turns and sideways moves reversed. left_to_right and right_to_left copy one side's motion onto the other side, mirrored, and leave the middle and the side copied from as they are. The keys themselves are mirrored, tangents included, so the result is exact and keeps the keys it had, editable in the Curve Editor. A joint copied from that does not move leaves its mirror not moving. Refused on a rig whose sides are not mirror images of each other.",
			),
		mode: z.enum(["flip", "left_to_right", "right_to_left"]),
		joints: z
			.array(z.string())
			.min(1)
			.max(32)
			.optional()
			.describe("Only these joints and their counterparts on the other side, for example LeftUpperLeg, LeftLowerLeg and LeftFoot for one leg. Default: every joint."),
		offset: z
			.number()
			.finite()
			.optional()
			.describe("With left_to_right or right_to_left in a looping clip: seconds later that the copied side does what the other side did, carried round from the end to the start. Half the clip's length makes a walk or run cycle from one leg and one arm."),
	}),
	z.object({
		type: z
			.literal("clear_keys")
			.describe(
				"Curve clips only. Remove every key in a time range, ends included, from the joints and channels named; the curves then run straight from the last key before the range to the first after it. A curve holds its first key's value back to the start, so clearing from 0 changes the start too. To redo a pin or place_on_floor over another range, clear the keys they wrote first: the old range with its blends, on the limb's three joints (rotation) or the hips (position). Never an error when the range holds no key; the result counts keys_removed.",
			),
		time_from: rangeFrom,
		time_to: rangeTo,
		joints: z.array(z.string()).min(1).max(32).optional().describe("Default: every joint."),
		channels: z.array(z.enum(["rotation", "position"])).min(1).max(2).optional().describe("Default: both."),
	}),
	z.object({
		type: z
			.literal("place_on_floor")
			.describe(
				"Curve clips only. Move the hips up or down at every frame of a range so that the body's lowest part rests on the floor, the rig's lowest point at rest, as validate_animation measures it. The whole body moves with the hips, feet and hands included, so place the body first and pin the feet after. The hips' position keys in the range are replaced by one key a frame, with smooth tangents; outside the range the clip is unchanged. The result counts frames_moved, with largest_raise_studs and largest_drop_studs.",
			),
		time_from: time("Start of the range in seconds."),
		time_to: time("End of the range in seconds. Must not be past the end of the clip."),
		mode: z
			.enum(["lift", "touch"])
			.optional()
			.describe("lift (default) only raises a body that has gone into the floor, so a jump stays in the air. touch also brings a floating body down onto it: for lying, sitting, kneeling or a landing."),
		parts: z
			.array(r15Part)
			.min(1)
			.max(15)
			.optional()
			.describe("The parts that rest on the floor. Default: every part but the lower legs. Parts are measured as boxes, so for a body lying down, name the torso: the head's box is deeper than the torso and would hold the back off the floor."),
		blend_in: z.number().finite().min(0).max(2).optional().describe("Seconds before time_from over which the move eases in. Default 0."),
		blend_out: z.number().finite().min(0).max(2).optional().describe("Seconds after time_to over which it eases out. Default 0."),
	}),
	z.object({
		type: z.literal("restore_source").describe("Reset the working copy to the clip it was opened from."),
	}),
] as const;

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
	// The same for the counts of a validation that found nothing.
	const counted = drawn.payload as { counts?: unknown } | null;
	if (method === "validate_animation" && counted !== null && typeof counted === "object" && Array.isArray(counted.counts) && counted.counts.length === 0) {
		counted.counts = {};
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
				"Apply a batch of operations to a working copy atomically. A keyframe clip takes poses, easing, keyframes and smoothing; a curve clip takes keys, tangents, auto_tangents, clear_keys, mirror, pin, place_on_floor and reverse_time. Both take shift_time and scale_time (retiming), markers, the clip's settings and restore_source; each operation's description says which clips it is for. The operations apply in the order given, each to the clip as the ones before it leave it. The whole batch is tried first; if any operation cannot be done, nothing changes and the error names it by its place in the list. Requires the current revision. One Studio undo reverts the whole batch. Only what an operation names is changed.",
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
				"Check a working copy. Errors mean the clip is not structurally sound and cannot be saved: a pose for a joint the rig lacks, two keyframes at one time, two poses for one joint in a keyframe, numbers that are not finite or out of range. Warnings are measurements to look at and never stop a save: a looping clip whose last keyframe does not match its first, a joint moving faster than a limit between two keyframes, a joint driven through forces, content that is kept but not understood. In a curve clip, contact with the floor is also measured at every frame, the floor being the rig's lowest point at rest: a part below it (BELOW_FLOOR; parts are measured as boxes, so the lower legs, whose boxes dip below the floor in a crouch while the shins do not, are left out), and a foot on it for three frames or more that slides along it (FOOT_SLIDE; not reported in a looping clip when the foot moves back steadily, as in a cycle made on the spot). Each finding has a code, the joints and times, the measured value and the limit. At most 50 are listed, with counts of all of them. These are measurements, not a judgement of how the motion looks.",
			inputSchema: {
				studio_session: studioSession,
				clip_id: clipId,
				thresholds: z
					.object({
						loop_rotation_degrees: z.number().positive().optional().describe("How far a looping clip's last keyframe may be from its first, per joint. Default 2."),
						loop_position_studs: z.number().positive().optional().describe("The same for position. Default 0.02."),
						speed_degrees_per_second: z.number().positive().optional().describe("How fast a joint may turn between two keyframes. Default 2000."),
						speed_studs_per_second: z.number().positive().optional().describe("How fast a joint may move between two keyframes. Default 40."),
						floor_studs: z.number().positive().optional().describe("Curve clips: how far a part may go below the floor, and how close to it a foot counts as planted. Default 0.1."),
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
				"Sample a working copy at an exact time and report the joint transforms. The clip is evaluated on a disposable copy of the rig; the rig itself and the camera are never moved. To see the pose, pass render: true: the result then includes a schematic picture drawn from the sampled joint positions, with each part as a box, the rig's left side blue and its right side orange, and a dark mark on the front of the head. It shows the pose, not the rig's real appearance, and is not a Studio screenshot. Studio screenshots (capture: true) are off by default and return capture.status \"unavailable\" with the reason; they are possible only in a test fixture after a person in Studio has approved the scene and camera.",
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
						"In place of time or times: follow parts over the whole clip, at this many moments evenly spread. The parts are those in track, or the hands, feet, head and hips. The result has motion: for each part, how far it travels (path) and ends from where it began (net); its top speed and when; when it starts and stops moving; holds, the stretches in between where it stands still; the largest change of speed from one moment to the next and when; and bow, how far its path strays from a straight line. Parts that all start and stop together move as one block; a large speed jump is a corner in the motion; no bow is a straight line. With render, the picture shows each part's path over the rig, a dot at every sample, beside a chart of each part's speed across the clip.",
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
						"Parts whose place in the rig to report as numbers, for example LeftFoot and RightFoot. Each gets position (x toward the rig's right, y up, z toward its back; forward is negative z), in studs from the root part, and lowest, the height of its lowest point. With times, each frame after the first also has velocity (studs per second along x, y, z since the frame before) and speed, and the result has ranges: for each part, the least, greatest and difference of x, y, z and lowest over the frames. A foot that is planted keeps the same lowest; in a cycle made on the spot it moves steadily backward while planted.",
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
