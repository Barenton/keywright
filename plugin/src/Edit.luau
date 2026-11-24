--!strict
-- Atomic edit batches. Every operation is validated before anything is written, the
-- batch is one undo recording, and a failure cancels the recording so nothing remains.

local RunService = game:GetService("RunService")

local Clips = require("./Clips")
local Errors = require("./Errors")
local Recording = require("./Recording")
local Rig = require("./Rig")

local Edit = {}

Edit.MAX_OPERATIONS = 256
Edit.MAX_TIME = 300
Edit.MAX_POSITION = 1000
Edit.MAX_KEYFRAMES = 2000

-- Test hook: when set, called inside the undo recording before each operation is applied,
-- with the number of that operation. Nothing in the plugin sets it; a test build does, to
-- make a batch fail or stop partway.
Edit.fault = nil :: ((working: Clips.Working, index: number) -> ())?

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function isVector(value: any, limit: number?): boolean
	if type(value) ~= "table" or #value ~= 3 then
		return false
	end
	for i = 1, 3 do
		if not isFiniteNumber(value[i]) or (limit and math.abs(value[i]) > limit) then
			return false
		end
	end
	return true
end

local function validate(operations: any, joints: { [string]: Rig.Joint })
	if type(operations) ~= "table" or #operations == 0 then
		Errors.throw("INVALID_ARGUMENT", "operations must be a non-empty list.")
	end
	if #operations > Edit.MAX_OPERATIONS then
		Errors.throw("LIMIT_EXCEEDED", `A batch holds at most {Edit.MAX_OPERATIONS} operations.`)
	end
	for index, operation in operations do
		local where = `operations[{index}]`
		if type(operation) ~= "table" then
			Errors.throw("INVALID_ARGUMENT", `{where} is not an object.`)
		end
		if operation.type == "set_pose" then
			if type(operation.joint) ~= "string" or not joints[operation.joint] then
				Errors.throw(
					"INVALID_ARGUMENT",
					`{where}: the rig has no joint "{tostring(operation.joint)}".`,
					"Call inspect_rig for the joint names."
				)
			end
			if not isFiniteNumber(operation.time) or operation.time < 0 or operation.time > Edit.MAX_TIME then
				Errors.throw("INVALID_ARGUMENT", `{where}: time must be from 0 to {Edit.MAX_TIME} seconds.`)
			end
			if operation.position ~= nil and not isVector(operation.position, Edit.MAX_POSITION) then
				Errors.throw(
					"INVALID_ARGUMENT",
					`{where}: position must be three finite numbers within {Edit.MAX_POSITION} studs.`
				)
			end
			if operation.rotation ~= nil and not isVector(operation.rotation) then
				Errors.throw("INVALID_ARGUMENT", `{where}: rotation must be three finite numbers in degrees.`)
			end
			if operation.position == nil and operation.rotation == nil then
				Errors.throw("INVALID_ARGUMENT", `{where}: give position, rotation or both.`)
			end
		elseif operation.type ~= "restore_source" then
			Errors.throw("INVALID_ARGUMENT", `{where}: unknown operation type "{tostring(operation.type)}".`)
		end
	end
end

local function apply(working: Clips.Working, operation: any, changed: { [string]: number })
	local sequence = working.instance
	if operation.type == "restore_source" then
		sequence:ClearAllChildren()
		if working.source then
			for _, child in working.source:GetChildren() do
				child:Clone().Parent = sequence
			end
			sequence.Loop = working.source.Loop
			sequence.Priority = working.source.Priority
		end
		changed.restored += 1
		return
	end

	local keyframe = Clips.findKeyframe(sequence, operation.time)
	if not keyframe then
		if #Clips.sortedKeyframes(sequence) >= Edit.MAX_KEYFRAMES then
			Errors.throw("LIMIT_EXCEEDED", `A clip holds at most {Edit.MAX_KEYFRAMES} keyframes.`)
		end
		local created = Instance.new("Keyframe")
		created.Time = operation.time
		created.Parent = sequence
		keyframe = created
		changed.keyframes_created += 1
	end

	local pose, created = Clips.ensurePose(keyframe :: Keyframe, operation.joint)
	if created then
		changed.poses_created += 1
	else
		changed.poses_changed += 1
	end
	local target = Rig.decode(operation.position, operation.rotation)
	if operation.relative then
		pose.CFrame = pose.CFrame * target
	else
		local current = pose.CFrame
		if operation.position == nil then
			target = target.Rotation + current.Position
		elseif operation.rotation == nil then
			target = current.Rotation + target.Position
		end
		pose.CFrame = target
	end
	pose.Weight = 1
end

function Edit.apply(
	working: Clips.Working,
	joints: { [string]: Rig.Joint },
	expectedRevision: any,
	operations: any
): any
	if not RunService:IsEdit() then
		Errors.throw("STUDIO_NOT_IN_EDIT_MODE", "Studio is running a playtest.", "Stop the playtest and try again.")
	end
	local current = Clips.revisionOf(working)
	if expectedRevision ~= current then
		Errors.throw(
			"REVISION_CONFLICT",
			`Expected revision {tostring(expectedRevision)}, but the clip is at {current}.`,
			"Read the clip again and reapply the change to the current revision."
		)
	end
	validate(operations, joints)

	local recording = Recording.begin("MotionBridgeEdit", "Motion Bridge edit")

	local changed = { keyframes_created = 0, poses_created = 0, poses_changed = 0, restored = 0 }
	Clips.mutate(working, function()
		for index, operation in operations do
			if Edit.fault then
				Edit.fault(working, index)
			end
			apply(working, operation, changed)
		end
	end, function(ok)
		Recording.finish(recording, ok)
	end)

	return { revision = Clips.revisionOf(working), changed = changed }
end

return Edit
