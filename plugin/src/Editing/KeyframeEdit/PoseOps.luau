--!strict
-- Poses: setting, removing and offsetting a joint's pose, and its easing.

local Need = require("./Need")
local Rig = require("../../Rigs/Rig")
local Sequence = require("./Sequence")
local Write = require("./Write")

local count = Write.count
local dropPose = Write.dropPose
local inRange = Write.inRange
local needEasing = Need.needEasing
local needJoint = Need.needJoint
local needKeyframe = Write.needKeyframe
local needOffset = Need.needOffset
local needRange = Need.needRange
local needTime = Need.needTime
local newKeyframe = Write.newKeyframe
local refuse = Need.refuse
local setEasing = Write.setEasing
local weighted = Write.weighted

type Changed = Sequence.Changed
type Context = Sequence.Context

local Ops = {}

Ops.set_pose = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needJoint(where, operation, joints)
		needTime(where, operation.time, "time")
		needOffset(where, operation)
		needEasing(where, operation, operation.easing_style, operation.easing_direction)
	end,

	apply = function(_where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local keyframe = Sequence.findKeyframe(sequence, operation.time)
			or newKeyframe(sequence, operation.time, changed)
		local pose, created = Sequence.ensurePose(keyframe, operation.joint)
		-- A pose that was only holding the nesting for its children starts to count now.
		count(changed, if created or pose.Weight == 0 then "poses_created" else "poses_changed")
		local target = Rig.decode(operation.position, operation.rotation, operation.quaternion)
		if operation.relative then
			pose.CFrame = pose.CFrame * target
		else
			local current = pose.CFrame
			if operation.position == nil then
				target = target.Rotation + current.Position
			elseif operation.rotation == nil and operation.quaternion == nil then
				target = current.Rotation + target.Position
			end
			pose.CFrame = target
		end
		pose.Weight = 1
		setEasing(pose, operation.easing_style, operation.easing_direction)
	end,
}

Ops.remove_pose = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needJoint(where, operation, joints)
		needTime(where, operation.time, "time")
	end,

	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local keyframe = needKeyframe(where, sequence, operation.time)
		local pose = weighted(keyframe, operation.joint)
		if not pose then
			refuse(where, `"{operation.joint}" has no pose at {operation.time} seconds.`)
		end
		dropPose(pose :: Pose)
		count(changed, "poses_removed")
	end,
}

Ops.offset_pose = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needJoint(where, operation, joints)
		needRange(where, operation)
		needOffset(where, operation)
	end,

	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local offset = Rig.decode(operation.position, operation.rotation, operation.quaternion)
		local found = 0
		for _, keyframe in Sequence.keyframes(sequence) do
			if inRange(keyframe.Time, operation.time_from, operation.time_to) then
				local pose = weighted(keyframe, operation.joint)
				if pose then
					pose.CFrame = pose.CFrame * offset
					found += 1
				end
			end
		end
		if found == 0 then
			refuse(where, `"{operation.joint}" has no pose from {operation.time_from} to {operation.time_to} seconds.`)
		end
		count(changed, "poses_changed", found)
	end,
}

Ops.set_easing = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needJoint(where, operation, joints)
		needRange(where, operation)
		if operation.easing_style == nil and operation.easing_direction == nil then
			refuse(where, "give easing_style, easing_direction or both.")
		end
		needEasing(where, operation, operation.easing_style, operation.easing_direction)
	end,

	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local found = 0
		for _, keyframe in Sequence.keyframes(sequence) do
			if inRange(keyframe.Time, operation.time_from, operation.time_to) then
				local pose = weighted(keyframe, operation.joint)
				if pose then
					setEasing(pose, operation.easing_style, operation.easing_direction)
					found += 1
				end
			end
		end
		if found == 0 then
			refuse(where, `"{operation.joint}" has no pose from {operation.time_from} to {operation.time_to} seconds.`)
		end
		count(changed, "poses_changed", found)
	end,
}

return Ops
