--!strict
-- The clip's own settings, its markers, and going back to the clip it was opened from.

local Frames = require("./Frames")
local Convert = require("./Convert")
local Need = require("./Need")
local Operations = require("../Operations")
local Roblox = require("../../Core/Roblox")
local Store = require("./Store")

local count = Frames.count
local currentBackend = Store.currentBackend
local markerCurve = Store.markerCurve
local near = Frames.near
local needOneOf = Need.needOneOf
local needText = Need.needText
local needTime = Need.needTime
local refuse = Need.refuse

type Changed = Frames.Changed
type Context = Frames.Context
type Marker = Store.Marker

local Ops = {}

Ops.set_properties = {
	check = function(where: string, operation: any)
		if operation.name == nil and operation.loop == nil and operation.priority == nil then
			refuse(where, "give name, loop or priority.")
		end
		if operation.name ~= nil then
			needText(where, operation.name, "name", Store.MAX_NAME)
		end
		if operation.loop ~= nil and type(operation.loop) ~= "boolean" then
			refuse(where, "loop must be true or false.")
		end
		if operation.priority ~= nil then
			needOneOf(where, operation.priority, "priority", Store.PRIORITIES)
		end
	end,

	apply = function(_where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local target = clip :: any
		if operation.name ~= nil then
			target.Name = operation.name
		end
		if operation.loop ~= nil then
			target.Loop = operation.loop
		end
		if operation.priority ~= nil then
			target.Priority = (Roblox.Enum.AnimationPriority :: any)[operation.priority]
		end
		count(changed, "properties_changed")
	end,
}

Ops.set_marker = {
	check = function(where: string, operation: any)
		needTime(where, operation.time, "time")
		needText(where, operation.name, "name", Store.MAX_NAME)
		if operation.value ~= nil then
			needText(where, operation.value, "value", Store.MAX_MARKER_VALUE, true)
		end
	end,

	apply = function(_where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local curve = markerCurve(clip, operation.name, true) :: Instance
		local markers = currentBackend().markers(curve)
		local found = false
		for _, marker in markers do
			if near(marker.time, operation.time) then
				marker.value = operation.value or ""
				found = true
			end
		end
		if not found then
			table.insert(markers, { time = operation.time, value = operation.value or "" })
		end
		table.sort(markers, function(a, b)
			return a.time < b.time
		end)
		currentBackend().setMarkers(curve, markers)
		count(changed, "markers_set")
	end,
}

Ops.remove_marker = {
	check = function(where: string, operation: any)
		needTime(where, operation.time, "time")
		needText(where, operation.name, "name", Store.MAX_NAME)
	end,

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local curve = markerCurve(clip, operation.name, false)
		local markers: { Marker } = if curve then currentBackend().markers(curve) else {}
		local kept = {}
		for _, marker in markers do
			if not near(marker.time, operation.time) then
				table.insert(kept, marker)
			end
		end
		if #kept == #markers then
			refuse(where, `there is no marker "{operation.name}" at {operation.time} seconds.`)
		end
		if #kept == 0 then
			(curve :: Instance).Parent = nil
		else
			currentBackend().setMarkers(curve :: Instance, kept)
		end
		count(changed, "markers_removed", #markers - #kept)
	end,
}

Ops.restore_source = {
	check = function() end,

	apply = function(_where: string, clip: Instance, _operation: any, context: Context, changed: Changed)
		for _, child in clip:GetChildren() do
			child.Parent = nil
		end
		local source = context.source :: any
		if source then
			-- A working copy converted from a keyframe clip is converted again.
			local from = if source:IsA("KeyframeSequence")
				then Convert.fromKeyframes(source, Operations.keyframes(source), Operations.findPose)
				else source
			for _, child in from:GetChildren() do
				child:Clone().Parent = clip
			end
			(clip :: any).Loop = source.Loop;
			(clip :: any).Priority = source.Priority
		end
		count(changed, "restored")
	end,
}

return Ops
