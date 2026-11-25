--!strict
-- The clip's own settings, its markers, and going back to the clip it was opened from.

local Need = require("./Need")
local Roblox = require("../../Core/Roblox")
local Sequence = require("./Sequence")
local Write = require("./Write")

local count = Write.count
local needKeyframe = Write.needKeyframe
local needOneOf = Need.needOneOf
local needText = Need.needText
local needTime = Need.needTime
local newKeyframe = Write.newKeyframe
local refuse = Need.refuse

type Changed = Sequence.Changed
type Context = Sequence.Context

local Ops = {}

Ops.set_properties = {
	check = function(where: string, operation: any)
		if operation.name == nil and operation.loop == nil and operation.priority == nil then
			refuse(where, "give name, loop or priority.")
		end
		if operation.name ~= nil then
			needText(where, operation.name, "name", Sequence.MAX_NAME)
		end
		if operation.loop ~= nil and type(operation.loop) ~= "boolean" then
			refuse(where, "loop must be true or false.")
		end
		if operation.priority ~= nil then
			needOneOf(where, operation.priority, "priority", Sequence.PRIORITIES)
		end
	end,

	apply = function(_where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local clip = sequence :: any
		if operation.name ~= nil then
			clip.Name = operation.name
		end
		if operation.loop ~= nil then
			clip.Loop = operation.loop
		end
		if operation.priority ~= nil then
			clip.Priority = (Roblox.Enum.AnimationPriority :: any)[operation.priority]
		end
		count(changed, "properties_changed")
	end,
}

Ops.set_marker = {
	check = function(where: string, operation: any)
		needTime(where, operation.time, "time")
		needText(where, operation.name, "name", Sequence.MAX_NAME)
		if operation.value ~= nil then
			needText(where, operation.value, "value", Sequence.MAX_MARKER_VALUE, true)
		end
	end,

	apply = function(_where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local keyframe = Sequence.findKeyframe(sequence, operation.time)
			or newKeyframe(sequence, operation.time, changed)
		local marker: any = nil
		for _, child in keyframe:GetChildren() do
			if child:IsA("KeyframeMarker") and child.Name == operation.name then
				marker = child
			end
		end
		if not marker then
			marker = Roblox.Instance.new("KeyframeMarker")
			marker.Name = operation.name
			marker.Parent = keyframe
		end
		marker.Value = operation.value or ""
		count(changed, "markers_set")
	end,
}

Ops.remove_marker = {
	check = function(where: string, operation: any)
		needTime(where, operation.time, "time")
		needText(where, operation.name, "name", Sequence.MAX_NAME)
	end,

	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local keyframe = needKeyframe(where, sequence, operation.time)
		local removed = 0
		for _, child in keyframe:GetChildren() do
			if child:IsA("KeyframeMarker") and child.Name == operation.name then
				child.Parent = nil
				removed += 1
			end
		end
		if removed == 0 then
			refuse(where, `there is no marker "{operation.name}" at {operation.time} seconds.`)
		end
		count(changed, "markers_removed", removed)
	end,
}

Ops.restore_source = {
	check = function() end,

	apply = function(_where: string, sequence: Instance, _operation: any, context: Context, changed: Changed)
		if context.source then
			Sequence.copyContent(context.source, sequence)
		else
			-- Opened blank: back to holding nothing.
			for _, child in sequence:GetChildren() do
				child.Parent = nil
			end
		end
		count(changed, "restored")
	end,
}

return Ops
