--!strict
-- Timing: shifting, scaling and reversing ranges, and reducing a range to few keys.

local Frames = require("./Frames")
local Need = require("./Need")
local Store = require("./Store")
local Write = require("./Write")

local count = Frames.count
local currentBackend = Store.currentBackend
local isFinite = Need.isFinite
local milliseconds = Need.milliseconds
local near = Frames.near
local needJoints = Need.needJoints
local needRange = Need.needRange
local needTime = Need.needTime
local onFrame = Write.onFrame
local reduced = Write.reduced
local refuse = Need.refuse
local sortKeys = Store.sortKeys
local wrapped = Write.wrapped

type Changed = Frames.Changed
type Context = Frames.Context
type Key = Store.Key

local Ops = {}

-- Moves the keys of every channel, and the markers, that lie from `from` to `to` to the
-- times `place` gives, on the nearest whole frame. Tangents are divided by `rate`: how many
-- times faster the moved keys now go by. A moved key may not land on or pass a key that
-- stays; two moved keys that land on one frame become one, between the two.
local function retimeCurves(
	where: string,
	clip: Instance,
	from: number,
	to: number,
	place: (time: number) -> number,
	rate: (time: number) -> number,
	changed: Changed
)
	local tolerance = Store.TIME_TOLERANCE
	local function inside(time: number): boolean
		return time >= from - tolerance and time <= to + tolerance
	end
	local plans: { { curve: Instance, keys: { Key } } } = {}
	local moved, merged = 0, 0
	local mergedAt = math.huge
	for _, track in Store.tracks(clip) do
		local keys = Store.keys(track.curve)
		local still: { Key } = {}
		local going: { Key } = {}
		for _, key in keys do
			if inside(key.time) then
				local copy = table.clone(key)
				local speed = rate(key.time)
				copy.time = onFrame(place(key.time))
				copy.left = if key.left then key.left / speed else nil
				copy.right = if key.right then key.right / speed else nil
				if copy.time < -tolerance or copy.time > Store.MAX_TIME then
					refuse(
						where,
						`a key of "{track.joint}" at {milliseconds(key.time)} seconds would move to {milliseconds(
							copy.time
						)}, outside 0 to {Store.MAX_TIME}.`
					)
				end
				copy.time = math.max(0, copy.time)
				table.insert(going, copy)
				moved += 1
				-- Remember where it came from, to say what it would pass.
				(copy :: any).from = key.time
			else
				table.insert(still, key)
			end
		end
		if #going == 0 then
			continue
		end
		for _, key in going do
			for _, other in still do
				local origin = (key :: any).from
				if math.abs(key.time - other.time) < tolerance then
					refuse(
						where,
						`the key of "{track.joint}" {track.channel} at {milliseconds(origin)} seconds would land on the one at {milliseconds(
							other.time
						)}.`,
						"Widen the range to take that key along, or use ripple."
					)
				elseif (origin < other.time) ~= (key.time < other.time) then
					refuse(
						where,
						`the key of "{track.joint}" {track.channel} at {milliseconds(origin)} seconds would pass the one at {milliseconds(
							other.time
						)}.`,
						"Widen the range to take that key along, or use ripple."
					)
				end
			end
		end
		sortKeys(going)
		local joined: { Key } = {}
		for _, key in going do
			local last = joined[#joined]
			if last and math.abs(last.time - key.time) < tolerance then
				-- Two keys on one frame: one key, halfway between them.
				last.value = (last.value + key.value) / 2
				last.left = ((last.left or 0) + (key.left or 0)) / 2
				last.right = key.right
				last.interpolation = key.interpolation
				merged += 1
				mergedAt = math.min(mergedAt, key.time)
			else
				(key :: any).from = nil
				table.insert(joined, key)
			end
		end
		for _, key in still do
			table.insert(joined, key)
		end
		sortKeys(joined)
		table.insert(plans, { curve = track.curve, keys = joined })
	end
	local markersMoved = 0
	for _, curve in Store.markerCurves(clip) do
		local markers = currentBackend().markers(curve)
		local touched = false
		for _, marker in markers do
			if inside(marker.time) then
				marker.time = math.max(0, onFrame(place(marker.time)))
				touched = true
				markersMoved += 1
			end
		end
		if touched then
			table.sort(markers, function(a, b)
				return a.time < b.time
			end)
			currentBackend().setMarkers(curve, markers)
		end
	end
	if moved == 0 and markersMoved == 0 then
		refuse(where, `there are no keys from {milliseconds(from)} to {milliseconds(to)} seconds.`)
	end
	for _, plan in plans do
		Store.setKeys(plan.curve, plan.keys)
	end
	count(changed, "keys_moved", moved)
	if markersMoved > 0 then
		count(changed, "markers_moved", markersMoved)
	end
	if merged > 0 then
		count(changed, "keys_merged", merged)
		changed.first_merge_at = math.min(changed.first_merge_at or math.huge, milliseconds(mergedAt))
	end
end

-- ---------------------------------------------------------------------------------------
-- Reducing keys

Ops.shift_time = {
	check = function(where: string, operation: any)
		needRange(where, operation)
		if not isFinite(operation.offset) or operation.offset == 0 then
			refuse(where, "offset must be a number of seconds other than 0.")
		end
		if operation.wrap ~= nil and type(operation.wrap) ~= "boolean" then
			refuse(where, "wrap must be true or false.")
		end
	end,

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		if operation.wrap then
			-- A loop started elsewhere: everything moves on by the offset, and what goes past
			-- the end comes round to the start, the curves cut where the loop now begins.
			local duration = Store.duration(clip)
			if not (clip :: any).Loop then
				refuse(where, "wrap carries motion round from the end to the start, so it needs a looping clip.")
			end
			if not (near(operation.time_from, 0) and near(operation.time_to, duration)) then
				refuse(where, `with wrap, the range must be the whole clip, 0 to {milliseconds(duration)} seconds.`)
			end
			local moved = 0
			for _, track in Store.tracks(clip) do
				local keys = Store.keys(track.curve)
				if #keys > 0 then
					local out = wrapped(keys, operation.offset, duration)
					Store.setKeys(track.curve, out)
					moved += #keys
				end
			end
			for _, curve in Store.markerCurves(clip) do
				local markers = currentBackend().markers(curve)
				for _, marker in markers do
					marker.time = (marker.time + operation.offset) % duration
				end
				table.sort(markers, function(a, b)
					return a.time < b.time
				end)
				currentBackend().setMarkers(curve, markers)
			end
			count(changed, "keys_moved", moved)
			return
		end
		retimeCurves(where, clip, operation.time_from, operation.time_to, function(time)
			return time + operation.offset
		end, function()
			return 1
		end, changed)
	end,
}

Ops.scale_time = {
	check = function(where: string, operation: any)
		needRange(where, operation)
		local factor = operation.factor
		if not isFinite(factor) or factor < Store.MIN_SCALE or factor > Store.MAX_SCALE or factor == 1 then
			refuse(where, `factor must be from {Store.MIN_SCALE} to {Store.MAX_SCALE}, and not 1.`)
		end
		if operation.anchor ~= nil then
			needTime(where, operation.anchor, "anchor")
		end
		if operation.ripple ~= nil and type(operation.ripple) ~= "boolean" then
			refuse(where, "ripple must be true or false.")
		end
	end,

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local anchor = if operation.anchor ~= nil then operation.anchor else operation.time_from
		local factor = operation.factor
		local to = operation.time_to
		local function scaled(time: number): number
			return anchor + (time - anchor) * factor
		end
		-- With ripple, everything after the range moves by as much as its end does, at the
		-- speed it had.
		local stretch = scaled(to) - to
		local last = if operation.ripple then Store.MAX_TIME else to
		retimeCurves(where, clip, operation.time_from, last, function(time)
			return if time <= to + Store.TIME_TOLERANCE then scaled(time) else time + stretch
		end, function(time)
			return if time <= to + Store.TIME_TOLERANCE then factor else 1
		end, changed)
	end,
}

Ops.reverse_time = {
	check = function(where: string, operation: any)
		needRange(where, operation)
		if operation.time_to - operation.time_from < Store.TIME_TOLERANCE then
			refuse(where, "the range must have some length.")
		end
	end,

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local from, to = operation.time_from, operation.time_to
		local tolerance = Store.TIME_TOLERANCE
		local reversed = 0
		for _, track in Store.tracks(clip) do
			local keys = Store.keys(track.curve)
			local first, last = nil, nil
			for index, key in keys do
				if key.time >= from - tolerance and key.time <= to + tolerance then
					first = first or index
					last = index
				end
			end
			if not first then
				continue
			end
			local out: { Key } = {}
			for index, key in keys do
				if index < first or index > last then
					table.insert(out, key)
					continue
				end
				-- Played backward, the stretch that now leaves this key is the one that used
				-- to arrive at it, shaped by the key before; the last one in the range leaves
				-- toward the key after it, as the range's last key used to.
				local shape = if index > first then keys[index - 1].interpolation else keys[last].interpolation
				table.insert(out, {
					time = onFrame(from + to - key.time),
					value = key.value,
					interpolation = shape,
					left = -(key.right or 0),
					right = if shape == "Cubic" then -(key.left or 0) else nil,
				})
				reversed += 1
			end
			sortKeys(out)
			Store.setKeys(track.curve, out)
		end
		for _, curve in Store.markerCurves(clip) do
			local markers = currentBackend().markers(curve)
			for _, marker in markers do
				if marker.time >= from - tolerance and marker.time <= to + tolerance then
					marker.time = onFrame(from + to - marker.time)
				end
			end
			table.sort(markers, function(a, b)
				return a.time < b.time
			end)
			currentBackend().setMarkers(curve, markers)
		end
		if reversed == 0 then
			refuse(where, `there are no keys from {milliseconds(from)} to {milliseconds(to)} seconds.`)
		end
		count(changed, "keys_reversed", reversed)
	end,
}

Ops.reduce_keys = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needRange(where, operation)
		needJoints(where, operation.joints, joints)
		for _, field in { "rotation_degrees", "position_studs" } do
			local value = operation[field]
			if value ~= nil and (not isFinite(value) or value <= 0 or value > 10) then
				refuse(where, `{field} must be more than 0 and at most 10.`)
			end
		end
	end,

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		if operation.time_to - operation.time_from > Store.MAX_REDUCE then
			refuse(where, `at most {Store.MAX_REDUCE} seconds are reduced at once.`, "Reduce the clip in parts.")
		end
		local wanted: { [string]: boolean }? = nil
		if operation.joints then
			wanted = {}
			for _, name in operation.joints do
				(wanted :: { [string]: boolean })[name] = true
			end
		end
		local degrees = math.rad(operation.rotation_degrees or Store.REDUCE_DEGREES)
		local studs = operation.position_studs or Store.REDUCE_STUDS
		local before, after = 0, 0
		for _, track in Store.tracks(clip) do
			if wanted and not wanted[track.joint] then
				continue
			end
			local keys = Store.keys(track.curve)
			local tolerance = if string.sub(track.channel, 1, 8) == "rotation" then degrees else studs
			local out = reduced(keys, operation.time_from, operation.time_to, tolerance)
			if out then
				before += #keys
				after += #out
				Store.setKeys(track.curve, out)
			end
		end
		count(changed, "keys_removed", before - after)
	end,
}

return Ops
