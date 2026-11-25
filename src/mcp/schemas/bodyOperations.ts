// Operations for curve clips that work through the rig's body: holding a hand or foot, aiming, overlap, and the floor.
import { z } from "zod";
import { vec3, time, joint, r15Part, position } from "./common.js";

export const bodyOperations = [
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
		pivot: z
			.enum(["ankle", "toe", "heel"])
			.optional()
			.describe("Feet only. The point of the foot that stays put. ankle (default) holds the foot as hold says. toe or heel holds that point, the middle of the sole's front or back edge, and the foot turns about it by roll, keeping its facing across the floor whatever the hips and leg above it do. With position or on_floor, those place the point; on_floor also sets the foot flat before it rolls. Not with hold position."),
		roll: z
			.array(z.number().min(0).max(90))
			.length(2)
			.optional()
			.describe("With a toe or heel pivot: how far, in degrees, the foot's other end is lifted off the floor at time_from and at time_to, easing between: toe with [0, 40] peels up onto the toe as a step pushes off; heel with [25, 0] lands heel first and rolls down onto the sole. At time_from the foot is taken to be lifted by the first angle already, so rolls one after another join up: up with [0, 30], back down with [30, 0]. Default [0, 0]."),
		travel: z
			.union([vec3, z.literal("match")])
			.optional()
			.describe("Studs a second the held point moves, in the same space as position, starting from where it is at `at`: a foot planted on a floor that moves, as in a walk or run cycle made on the spot, where the planted foot moves back steadily under the body. For a cycle facing forward, a positive z (toward the back). \"match\" takes the speed from the clip's own motion of the held point over the range, where it is at time_from and at time_to, before the pin (across the floor only with on_floor), and the result gives it as travel_x, travel_y and travel_z. The point moves on through blend_in and blend_out as well, so a foot eased in lands already moving with the floor, and one eased out leaves with it. A toe or heel pivot moves with it."),
		fit_hips: z
			.boolean()
			.optional()
			.describe("Where the held point is beyond the limb's reach (less soft), lower the hips straight down by just enough for it to be reached, at that frame only: a crouch to pick something up, a lunge, a long stride. The result counts frames_hips_lowered with largest_hip_drop_studs. Not with relative_to."),
		keep: z
			.array(z.enum(["LeftFoot", "RightFoot", "LeftHand", "RightHand"]))
			.max(3)
			.optional()
			.describe("With fit_hips: the other hands or feet to keep exactly where they were while the hips move, as the other foot planted on the floor."),
		soft: z
			.number()
			.min(0)
			.max(0.5)
			.optional()
			.describe("Soften the limb's reach over this last share of it, from 0 to 0.5: near full stretch the point is reached for ever more slowly and never quite reached, so the knee or elbow never locks straight or snaps through its last degrees, as hips rising off a planted foot. 0.02 to 0.05 suits a planted foot; 0.1 keeps the knee well bent. The result gives largest_soft_studs, how far short of the point that left the part; such frames are not out of reach. Default 0."),
		on_floor: z
			.boolean()
			.optional()
			.describe("Hold the part where it is across the floor, but set flat, turned only about the vertical, with its underside on the floor: plants a foot properly even where the clip has it sunk or lifted at `at`, as after lowering the hips on straight legs. Not with relative_to; position's height is replaced."),
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
			.literal("aim")
			.describe(
				"Curve clips only. Turn one joint so the front of its part faces a point over a time range, by the smallest turn from how it is animated: a head that watches an opponent through a whole combo, a chest that squares up to a target. With hold instead, the part keeps the facing it has at `at` while the body moves under it, as a head stays level through a run. To turn the chest part of the way and the head the rest, aim the chest first with a weight, then the head. Written at every frame and then reduced to as few keys as keep it; the joint's motion outside the range and its blends is unchanged.",
			),
		joint,
		time_from: time("Start of the range in seconds."),
		time_to: time("End of the range in seconds. Must not be past the end of the clip."),
		target: vec3.optional().describe("The point to face, in studs from the root part: x toward the rig's right, y up, z toward its back."),
		hold: z.boolean().optional().describe("Keep the facing the part has at `at` instead of facing a point."),
		at: time("With hold: the time whose facing is kept. Default time_from.").optional(),
		weight: z.number().min(0).max(1).optional().describe("How much of the turn to make, from 0 to 1. Default 1."),
		limit_degrees: z.number().positive().max(180).optional().describe("The most the joint is turned from its own motion, in degrees: a head that does not turn past its shoulder."),
		blend_in: z.number().finite().min(0).max(2).optional().describe("Seconds before time_from over which it eases in. Default 0."),
		blend_out: z.number().finite().min(0).max(2).optional().describe("Seconds after time_to over which it eases out. Default 0."),
	}),
	z.object({
		type: z
			.literal("overlap")
			.describe(
				"Curve clips only. Follow-through and overlapping action: the joints named trail the motion they are given, through a damped spring, so a fast move pulls them along late and, with bounce, they swing on past where it stops before settling. An arm that trails a punch's turn, a head that lags a landing, hands that flap after a stop. Joints are taken from the body outward, each trailing a parent that already trails, and the lag is shared along them so the end of the chain trails by about `lag`. Over the whole of a looping clip, the motion comes back round to where it began. Written at every frame and then reduced to as few keys as keep it.",
			),
		joints: z.array(z.string()).min(1).max(32).describe("The joints that trail, for example LeftUpperArm, LeftLowerArm and LeftHand, or Head."),
		time_from: time("Start of the range in seconds."),
		time_to: time("End of the range in seconds. Must not be past the end of the clip."),
		lag: z.number().min(0.02).max(0.5).optional().describe("About how many seconds the end of the chain trails behind. Default 0.1."),
		bounce: z.number().min(0).max(0.9).optional().describe("How far it swings past where the motion stops: 0 trails without swinging past, 0.9 is very springy. Default 0.3."),
		weight: z.number().min(0).max(1).optional().describe("How much of the trailing to use, from 0 to 1. Default 1."),
		blend_in: z.number().finite().min(0).max(2).optional().describe("Seconds before time_from over which it eases in. Default 0."),
		blend_out: z.number().finite().min(0).max(2).optional().describe("Seconds after time_to over which it eases out. Default 0."),
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
			.describe("The parts that rest on the floor. Default: every part but the lower legs. Parts are measured as boxes of their size with rounded corners, so for a body lying down, name the torso: the head's box is deeper than the torso and would hold the back off the floor."),
		blend_in: z.number().finite().min(0).max(2).optional().describe("Seconds before time_from over which the move eases in. Default 0."),
		blend_out: z.number().finite().min(0).max(2).optional().describe("Seconds after time_to over which it eases out. Default 0."),
	}),
	z.object({
		type: z
			.literal("clear_floor")
			.describe(
				"Curve clips only. Keep a hand or foot off the floor over a time range: at every frame where its lowest point is nearer the floor than clearance, its limb lifts it straight up by the shortfall, turned as it was and where it was across the floor; frames where it is clear already are left as they are. A swinging foot that scuffs on its way to the next step, a hand that brushes the ground in a crawl or cartwheel. The floor is validate_animation's. Written at every frame and then reduced to as few keys as keep it. The result counts frames_lifted with largest_lift_studs.",
			),
		part: z.enum(["LeftFoot", "RightFoot", "LeftHand", "RightHand"]),
		time_from: time("Start of the range in seconds."),
		time_to: time("End of the range in seconds. Must not be past the end of the clip."),
		clearance: z.number().min(0).max(2).optional().describe("The least height of the part's lowest point above the floor, in studs. Default 0.05."),
		blend_in: z.number().finite().min(0).max(2).optional().describe("Seconds before time_from over which it eases in. Default 0."),
		blend_out: z.number().finite().min(0).max(2).optional().describe("Seconds after time_to over which it eases out. Default 0."),
	}),
] as const;
