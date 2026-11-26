// The pieces the tools' input schemas are built from: ids, times, vectors, joints and parts.
import { z } from "zod";

// Not named "session_id": Claude Desktop was seen to leave an argument of that name out of
// the calls it sends, while passing the others on. It stays required. A session id changes
// when the plugin reloads, and clip ids are numbered afresh then, so a call that names a
// session from before a reload is refused instead of reaching a different clip.
export const studioSession = z.string().describe("Which Studio window to act in: a session id from get_workspace.");
export const clipId = z.string().describe("Working copy id from open_animation or get_workspace.");
export const vec3 = z.array(z.number().finite()).length(3);

export const time = (what: string) => z.number().finite().min(0).max(300).describe(what);
export const joint = z.string().describe("Name of the driven part, for example RightUpperArm.");
// The parts of an R15 rig that a joint drives.
export const r15Part = z.enum(["LowerTorso", "UpperTorso", "Head", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot"]);
export const position = vec3.optional().describe("Joint-local offset from the rest pose, in studs.");
export const rotation = vec3.optional().describe("Joint-local rotation as Euler angles in degrees, applied in X, Y, Z order.");
export const quaternion = z
	.array(z.number().finite())
	.length(4)
	.optional()
	.describe("Joint-local rotation as a quaternion (x, y, z, w) of length 1, in place of rotation.");
export const rangeFrom = time("Start of the time range in seconds. Keyframes at the ends are included.");
export const rangeTo = time("End of the time range in seconds.");
// The range of a curve operation that writes frames. In a looping clip the end and the
// start are one moment, so its range may run across them.
export const spanFrom = time("Start of the range in seconds. In a looping clip it may be after time_to: the range then runs on past the end and round from the start, as a step that lands just after the loop begins (time_from 0.9, time_to 0.2), blends included.");
export const spanTo = time("End of the range in seconds. Must not be past the end of the clip. In a looping clip, a range or blend that reaches the end, or the start, changes both alike, so the loop stays closed.");
// As measured in Studio on a jump: Out covers most of the distance early and slows into
// the next pose; In starts slowly and arrives fast.
export const easingStyle = z
	.enum(["Linear", "Constant", "Elastic", "CubicV2", "Bounce"])
	.optional()
	.describe("How the joint moves from this pose to its next one. A pose's easing shapes the stretch that starts at it, not the one that ends at it. The deprecated Cubic style is kept where a clip has it but cannot be set.");
export const easingDirection = z
	.enum(["In", "Out", "InOut"])
	.optional()
	.describe("In starts slowly and ends fast; Out starts fast and ends slowly; InOut is slow at both ends. For a jump, the rise is Out and the fall is In.");
export const markerName = z.string().min(1).max(100).describe("The marker's name.");
