--!strict
-- The edits that can be made to a clip, each as an operation applied to a
-- KeyframeSequence.
--
-- Nothing here knows about working copies, revisions or undo; that is Edit's part. This
-- module only changes the instance tree it is handed, so that it can be run first on a
-- scratch copy (to find out whether a whole batch succeeds) and then on the real clip.
--
-- Three rules hold for every operation:
--   * It touches only the keyframes, poses and markers it names. Everything else in the
--     clip keeps its instances and its property values.
--   * Content this module does not understand (a NumberPose, a Folder, anything that is
--     not a Pose or a KeyframeMarker) is never changed or removed, except when the
--     keyframe that holds it is itself removed on request.
--   * Two keyframes closer together than a millisecond count as the same keyframe.

local ClipOps = require("./KeyframeEdit/ClipOps")
local Errors = require("../Core/Errors")
local KeyframeOps = require("./KeyframeEdit/KeyframeOps")
local Need = require("./KeyframeEdit/Need")
local PoseOps = require("./KeyframeEdit/PoseOps")
local Sequence = require("./KeyframeEdit/Sequence")
local SmoothOp = require("./KeyframeEdit/SmoothOp")
local TimeOps = require("./KeyframeEdit/TimeOps")

export type Context = Sequence.Context
export type Changed = Sequence.Changed

local refuse = Need.refuse

local Operations = {}

-- The limits and names, and finding keyframes and poses.
Operations.MAX_OPERATIONS = Sequence.MAX_OPERATIONS
Operations.MAX_TIME = Sequence.MAX_TIME
Operations.MAX_POSITION = Sequence.MAX_POSITION
Operations.MAX_KEYFRAMES = Sequence.MAX_KEYFRAMES
Operations.MAX_NAME = Sequence.MAX_NAME
Operations.MAX_MARKER_VALUE = Sequence.MAX_MARKER_VALUE
Operations.MAX_HOLDS = Sequence.MAX_HOLDS
Operations.MIN_RATE = Sequence.MIN_RATE
Operations.MAX_RATE = Sequence.MAX_RATE
Operations.DEFAULT_RATE = Sequence.DEFAULT_RATE
Operations.MAX_SNAPS = Sequence.MAX_SNAPS
Operations.MAX_JOINTS = Sequence.MAX_JOINTS
Operations.MIN_SCALE = Sequence.MIN_SCALE
Operations.MAX_SCALE = Sequence.MAX_SCALE
Operations.TIME_TOLERANCE = Sequence.TIME_TOLERANCE
Operations.EASING_STYLES = Sequence.EASING_STYLES
Operations.EASING_DIRECTIONS = Sequence.EASING_DIRECTIONS
Operations.PRIORITIES = Sequence.PRIORITIES
Operations.keyframes = Sequence.keyframes
Operations.findKeyframe = Sequence.findKeyframe
Operations.findPose = Sequence.findPose
Operations.ensurePose = Sequence.ensurePose
Operations.copyContent = Sequence.copyContent
Operations.animated = Sequence.animated

-- Every operation for keyframe clips, by name: how it is checked and how it is applied.
type Operation = {
	check: (where: string, operation: any, joints: { [string]: any }) -> (),
	apply: (where: string, sequence: Instance, operation: any, context: Context, changed: Changed) -> (),
}
type Check = (where: string, operation: any, joints: { [string]: any }) -> ()
local operations_: { [string]: Operation } = {}
for _, family in { PoseOps, KeyframeOps, TimeOps, ClipOps, SmoothOp } :: { any } do
	for name, operation in family do
		operations_[name] = operation
	end
end

-- The names of every operation, sorted.
function Operations.types(): { string }
	local names = {}
	for name in operations_ do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- Checks everything about a batch that does not depend on what the clip holds. Raises on
-- the first problem, naming the operation by its place in the list.
function Operations.check(operations: any, joints: { [string]: any })
	if type(operations) ~= "table" or #operations == 0 then
		Errors.throw("INVALID_ARGUMENT", "operations must be a non-empty list.")
	end
	if #operations > Operations.MAX_OPERATIONS then
		Errors.throw("LIMIT_EXCEEDED", `A batch holds at most {Operations.MAX_OPERATIONS} operations.`)
	end
	for index, operation in operations do
		local where = `operations[{index}]`
		if type(operation) ~= "table" then
			refuse(where, "is not an object.")
		end
		local check = if type(operation.type) == "string"
			then operations_[operation.type] and operations_[operation.type].check
			else nil
		if not check then
			refuse(
				where,
				`unknown operation type "{tostring(operation.type)}".`,
				`The types are: {table.concat(Operations.types(), ", ")}.`
			)
		end
		(check :: Check)(where, operation, joints)
	end
	if #Operations.holds(operations) > Operations.MAX_HOLDS then
		Errors.throw(
			"LIMIT_EXCEEDED",
			`A batch adds at most {Operations.MAX_HOLDS} keyframes that hold the current pose.`
		)
	end
end

-- The places in a batch of the keyframes that are to hold the clip's current pose.
function Operations.holds(operations: { any }): { number }
	local places = {}
	for index, operation in operations do
		if type(operation) == "table" and operation.type == "add_keyframe" and operation.hold == true then
			table.insert(places, index)
		end
	end
	return places
end

-- ---------------------------------------------------------------------------------------
-- Applying

-- Applies a checked batch to a clip, one operation after another, and returns counts of
-- what changed. Raises at the first operation that cannot be done, leaving the earlier
-- ones applied: run it on a scratch copy first if that matters.
function Operations.run(
	sequence: Instance,
	operations: { any },
	context: Context,
	before: ((index: number) -> ())?
): Changed
	local changed: Changed = {}
	for index, operation in operations do
		if before then
			before(index)
		end
		operations_[operation.type].apply(`operations[{index}]`, sequence, operation, context, changed)
	end
	return changed
end

return Operations
