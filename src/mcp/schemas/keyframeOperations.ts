// Operations for keyframe clips: poses, their easing, keyframes themselves, and smoothing.
import { z } from "zod";
import { time, joint, position, rotation, quaternion, rangeFrom, rangeTo, easingStyle, easingDirection } from "./common.js";

export const keyframeOperations = [
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
] as const;
