--!strict
-- Keyframes themselves: adding, removing, moving and duplicating them.

local Errors = require("../../Core/Errors")
local Need = require("./Need")
local Sequence = require("./Sequence")
local Write = require("./Write")

local count = Write.count
local needFree = Write.needFree
local needKeyframe = Write.needKeyframe
local needTime = Need.needTime
local newKeyframe = Write.newKeyframe
local refuse = Need.refuse
local weighted = Write.weighted

type Changed = Sequence.Changed
type Context = Sequence.Context

local Ops = {}

Ops.add_keyframe = {
	check = function(where: string, operation: any)
		needTime(where, operation.time, "time")
		if operation.hold ~= nil and type(operation.hold) ~= "boolean" then
			refuse(where, "hold must be true or false.")
		end
	end,

	apply = function(where: string, sequence: Instance, operation: any, context: Context, changed: Changed)
		needFree(where, sequence, operation.time)
		if operation.hold ~= true then
			newKeyframe(sequence, operation.time, changed)
			return
		end
		local index = tonumber(string.match(where, "%d+")) :: number
		local poses = context.held and context.held[index]
		if not poses then
			Errors.throw(
				"PREVIEW_UNAVAILABLE",
				`{where}: the clip's pose at {operation.time} seconds could not be worked out.`
			)
		end
		-- Easing belongs to the pose a stretch of motion starts from. The new keyframe
		-- starts the second half of a stretch, so it takes the easing of the pose before
		-- it. Found before the keyframe exists, so that it is not found itself.
		local easing: { [string]: Pose } = {}
		local later: { [string]: boolean } = {}
		for _, keyframe in Sequence.keyframes(sequence) do
			for name in poses :: { [string]: CFrame } do
				local found = weighted(keyframe, name)
				if found and keyframe.Time < operation.time then
					easing[name] = found
				elseif found then
					later[name] = true
				end
			end
		end
		local created = newKeyframe(sequence, operation.time, changed)
		local reshaped: { string } = {}
		local names: { string } = {}
		for name in poses :: { [string]: CFrame } do
			-- Only a joint that is between two of its own poses here is keyed. Before its
			-- first pose or after its last, a new pose would start or end a stretch of
			-- motion that was not there.
			if easing[name] and later[name] then
				table.insert(names, name)
			end
		end
		table.sort(names)
		for _, name in names do
			local pose = Sequence.ensurePose(created, name)
			pose.CFrame = (poses :: { [string]: CFrame })[name]
			pose.Weight = 1
			local before = easing[name]
			if before then
				pose.EasingStyle = before.EasingStyle
				pose.EasingDirection = before.EasingDirection
				-- Only a straight or a stepped stretch is the same motion once split in two.
				local style = before.EasingStyle.Name
				if style ~= "Linear" and style ~= "Constant" then
					table.insert(reshaped, name)
				end
			end
			count(changed, "poses_created")
		end
		if context.holds then
			table.insert(context.holds, {
				time = operation.time,
				joints = #names,
				-- Joints whose motion around the new keyframe is no longer what it was.
				motion_changed = if #reshaped > 0 then reshaped else nil,
			})
		end
	end,
}

Ops.remove_keyframe = {
	check = function(where: string, operation: any)
		needTime(where, operation.time, "time")
	end,

	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		needKeyframe(where, sequence, operation.time).Parent = nil
		count(changed, "keyframes_removed")
	end,
}

Ops.move_keyframe = {
	check = function(where: string, operation: any)
		needTime(where, operation.time, "time")
		needTime(where, operation.to, "to")
	end,

	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local keyframe = needKeyframe(where, sequence, operation.time)
		needFree(where, sequence, operation.to, keyframe)
		keyframe.Time = operation.to
		count(changed, "keyframes_moved")
	end,
}

Ops.duplicate_keyframe = {
	check = function(where: string, operation: any)
		needTime(where, operation.time, "time")
		needTime(where, operation.to, "to")
	end,

	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local keyframe = needKeyframe(where, sequence, operation.time)
		needFree(where, sequence, operation.to)
		if #Sequence.keyframes(sequence) >= Sequence.MAX_KEYFRAMES then
			Errors.throw("LIMIT_EXCEEDED", `A clip holds at most {Sequence.MAX_KEYFRAMES} keyframes.`)
		end
		local copy = keyframe:Clone()
		copy.Time = operation.to
		copy.Parent = sequence
		count(changed, "keyframes_created")
	end,
}

return Ops
