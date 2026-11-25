// Operations for both kinds of clip: retiming, the clip's settings and markers, and restoring.
import { z } from "zod";
import { time, rangeFrom, rangeTo, markerName } from "./common.js";

export const sharedOperations = [
	z.object({
		type: z
			.literal("shift_time")
			.describe(
				"Move every keyframe in a time range by the same amount; in a curve clip, every key of every joint and every marker, each onto the nearest whole frame. Refused if one would land on or pass a key or keyframe outside the range.",
			),
		time_from: rangeFrom,
		time_to: rangeTo,
		offset: z.number().finite().describe("Seconds to move by; negative moves earlier."),
		wrap: z
			.boolean()
			.optional()
			.describe("Curve clips that loop, over the whole clip only: start the loop somewhere else. Everything moves on by the offset and what goes past the end comes round to the start, the curves cut exactly where the loop now begins; the loop should close (end in the pose it begins with, as copy_pose makes it). For room before a moment at the start, as a step eased into a heel strike at 0. Use whole frames."),
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
		type: z.literal("restore_source").describe("Reset the working copy to the clip it was opened from."),
	}),
] as const;
