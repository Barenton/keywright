// Operations for curve clips on keys and time: setting and shaping keys, clearing and copying, adding motion on top, reducing, reversing, mirroring.
import { z } from "zod";
import { vec3, time, joint, position, rotation, rangeFrom, rangeTo } from "./common.js";

export const curveOperations = [
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
			.literal("copy_pose")
			.describe(
				"Curve clips only. Copy the pose the clip has at one time to a key at another, for every joint or those named: end a loop in exactly the pose it starts with, come back to a guard pose, hold a pose. With mirror, the pose is copied as its mirror image, left onto right: a walk's left contact pose becomes the right one. A key already at `to` gets the new value and keeps its tangents; a new one starts flat, as with set_key, so run auto_tangents afterwards for smooth motion. The result counts keys_created and keys_changed.",
			),
		from: time("The time whose pose is copied, in seconds."),
		to: time("The time to put it at, in seconds."),
		joints: z.array(z.string()).min(1).max(32).optional().describe("The joints to key at `to`. Default: every joint. With mirror, each takes the pose of its counterpart on the other side."),
		mirror: z.boolean().optional().describe("Copy the pose as its mirror image. Default false."),
		channels: z.array(z.enum(["rotation", "position"])).min(1).max(2).optional().describe("Default: both."),
	}),
	z.object({
		type: z
			.literal("add_offset")
			.describe(
				"Curve clips only. Add a turn or a move to one joint over a time range, on top of the motion it has, easing in and out: lean the chest further forward through a punch, drop the hips lower while landing, without working out new angles at every key. The amounts are added to the joint's own angles, as set_key gives them, and its position. Written at every frame and then reduced to as few keys as keep it, so the curves stay editable. The joint's motion outside the range and its blends is unchanged.",
			),
		joint,
		time_from: time("Start of the range in seconds."),
		time_to: time("End of the range in seconds. Must not be past the end of the clip."),
		rotation: vec3.optional().describe("Degrees to add about X, Y and Z, as in set_key."),
		position: vec3.optional().describe("Studs to add, as in set_key."),
		blend_in: z.number().finite().min(0).max(2).optional().describe("Seconds before time_from over which it eases in. Default 0."),
		blend_out: z.number().finite().min(0).max(2).optional().describe("Seconds after time_to over which it eases out. Default 0."),
	}),
	z.object({
		type: z
			.literal("add_noise")
			.describe(
				"Curve clips only. Add a smooth, slow sway on top of the motion of the joints named: breathing and weight shifts in an idle, a tremble, the shake of a hit. Each joint and channel sways its own way, from three waves at chance phases, and the same seed always gives the same sway. Over the whole of a looping clip, the sway ends where it began. Written at every frame and then reduced to as few keys as keep it.",
			),
		joints: z.array(z.string()).min(1).max(32),
		time_from: time("Start of the range in seconds."),
		time_to: time("End of the range in seconds. Must not be past the end of the clip."),
		rotation_degrees: z.number().min(0).max(90).optional().describe("About how far each rotation channel sways either way, in degrees. Default 0."),
		position_studs: z.number().min(0).max(5).optional().describe("About how far each position channel sways either way, in studs. Default 0."),
		frequency: z.number().min(0.1).max(10).optional().describe("Waves a second of the slowest sway; the others are about twice and four times as fast. Default 1."),
		seed: z.number().int().optional().describe("Another seed gives another sway. Default 1."),
		blend_in: z.number().finite().min(0).max(2).optional().describe("Seconds before time_from over which it eases in. Default 0."),
		blend_out: z.number().finite().min(0).max(2).optional().describe("Seconds after time_to over which it eases out. Default 0."),
	}),
	z.object({
		type: z
			.literal("reduce_keys")
			.describe(
				"Curve clips only. Rebuild each channel in a range from as few keys as keep it within a tolerance of how it plays now, at every frame Studio shows. pin, place_on_floor and a squeeze leave a key on every frame; reducing them afterwards leaves curves a person can edit in the Curve Editor, and reads that are far shorter. The keys at the ends of the range stay as they are. At most 60 seconds at once. The result counts keys_removed.",
			),
		time_from: rangeFrom,
		time_to: rangeTo,
		joints: z.array(z.string()).min(1).max(32).optional().describe("Default: every joint."),
		rotation_degrees: z.number().positive().max(10).optional().describe("How far a rotation may stray, in degrees. Default 0.1."),
		position_studs: z.number().positive().max(10).optional().describe("How far a position may stray, in studs. Default 0.002."),
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
] as const;
