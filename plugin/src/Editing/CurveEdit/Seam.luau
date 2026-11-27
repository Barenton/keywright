--!strict
-- Ranges across a loop's seam. In a looping clip the end and the start are one moment, so
-- an operation whose range, or a blend of it, reaches either end has to change both alike,
-- and a range may run on past the end and round from the start: time_from after time_to,
-- as a step that lands just after the loop begins. Such an operation is run on the loop
-- started elsewhere, where its range lies whole inside it, and the loop is then started
-- where it was again. Starting a loop elsewhere cuts the curves exactly (Write.wrapped),
-- so the motion is the same; each channel the operation left alone is then put back key
-- for key, and the cut left in a channel it changed is taken out where it can be exactly.

local Frames = require("./Frames")
local Need = require("./Need")
local Store = require("./Store")
local Write = require("./Write")

type Key = Store.Key
type Context = Frames.Context
type Changed = Frames.Changed
export type Apply = (where: string, clip: Instance, operation: any, context: Context, changed: Changed) -> ()

local milliseconds = Need.milliseconds
local rounded = Need.rounded
local refuse = Need.refuse

local Seam = {}

-- How much of a loop a range across its seam must leave out, in frames: room for the cut
-- where the loop is started while the operation runs, and a frame either side of it.
local ROOM = 3

local function sameKey(a: Key, b: Key): boolean
	return math.abs(a.time - b.time) < Store.TIME_TOLERANCE
		and a.value == b.value
		and a.interpolation == b.interpolation
		and a.left == b.left
		and a.right == b.right
end

local function sameKeys(a: { Key }, b: { Key }): boolean
	if #a ~= #b then
		return false
	end
	for index, key in a do
		if not sameKey(key, b[index]) then
			return false
		end
	end
	return true
end

local function startElsewhere(clip: Instance, offset: number, duration: number)
	for _, track in Store.tracks(clip) do
		local keys = Store.keys(track.curve)
		if #keys > 0 then
			Store.setKeys(track.curve, Write.wrapped(keys, offset, duration))
		end
	end
end

-- The cut at `time` taken out of a channel, where the keys either side of it are the
-- channel's own as they were: the stretch between them is then the one it always was.
local function withoutCut(keys: { Key }, original: { Key }, time: number): { Key }
	local tolerance = Store.TIME_TOLERANCE
	local function own(key: Key?): boolean
		if not key then
			return false
		end
		for _, before in original do
			if sameKey(before, key) then
				return true
			end
		end
		return false
	end
	for _, before in original do
		if math.abs(before.time - time) < tolerance then
			return keys
		end
	end
	for index, key in keys do
		if math.abs(key.time - time) < tolerance then
			if own(keys[index - 1]) and own(keys[index + 1]) then
				local out = table.clone(keys)
				table.remove(out, index)
				return out
			end
			return keys
		end
	end
	return keys
end

-- What an operation reports, added to what the batch has reported so far, its times
-- given back on the loop as it was: counts add up, a largest keeps the largest, a time
-- where something begins (_from, _at) keeps the first and one where it ends (_to) the last;
-- anything else is replaced.
local function merge(changed: Changed, found: Changed, timeOf: (number) -> number)
	for name, value in found do
		local begins = string.sub(name, -5) == "_from" or string.sub(name, -3) == "_at"
		local ends = string.sub(name, -3) == "_to"
		if begins or ends then
			value = timeOf(value)
		end
		local before = changed[name]
		if before == nil then
			changed[name] = value
		elseif string.sub(name, 1, 8) == "largest_" or ends then
			changed[name] = math.max(before, value)
		elseif begins then
			changed[name] = math.min(before, value)
		elseif string.sub(name, 1, 7) == "travel_" then
			changed[name] = value
		else
			changed[name] = before + value
		end
	end
end

-- Runs `apply` for an operation with a range (time_from, time_to and any blend_in,
-- blend_out and at), across the seam of a looping clip where its range reaches it.
function Seam.apply(where: string, clip: Instance, operation: any, context: Context, changed: Changed, apply: Apply)
	local from, to = operation.time_from, operation.time_to
	local across = to < from
	local looping = (clip :: any).Loop == true
	if not looping then
		if across then
			refuse(
				where,
				"time_to is before time_from. A range runs on past the end and round from the start only in a looping clip."
			)
		end
		apply(where, clip, operation, context, changed)
		return
	end
	local duration = Store.duration(clip)
	local tolerance = Store.TIME_TOLERANCE
	local rate = Store.FRAME_RATE
	local reach = if across then to + duration else to
	local first = from - (operation.blend_in or 0)
	local last = reach + (operation.blend_out or 0)
	local whole = not across and Frames.near(from, 0) and Frames.near(to, duration)
	local inside = first > tolerance and last < duration - tolerance
	-- A range past the end is left to the operation to refuse, in its own words.
	if whole or inside or to > duration + tolerance then
		apply(where, clip, operation, context, changed)
		return
	end
	if from > duration + tolerance then
		refuse(where, `the clip ends at {milliseconds(duration)} seconds, before time_from.`)
	end
	local frames = duration * rate
	if math.abs(frames - math.round(frames)) > Frames.FRAME_SLACK then
		refuse(
			where,
			"the range reaches the end of the loop, but the loop is not a whole number of frames long, so its end and start cannot be lined up.",
			"Key the loop's end on a whole frame."
		)
	end
	if last - first > duration - ROOM / rate + tolerance then
		refuse(
			where,
			`the range with its blends spans {milliseconds(last - first)} seconds, too much of the {milliseconds(
				duration
			)}-second loop to run across its end.`,
			`Leave at least {milliseconds(ROOM / rate)} seconds of the loop out, or use the whole loop: 0 to {milliseconds(
				duration
			)} seconds.`
		)
	end

	-- The loop must close: each channel ending where it starts. A loop that doesn't, such
	-- as one turning from 0 to 360 degrees, can't have its end joined to its start without
	-- changing its motion, which the operation would then be worked out from.
	for _, track in Store.tracks(clip) do
		local keys = Store.keys(track.curve)
		if #keys > 0 then
			local opening, closing = Store.evaluate(keys, 0), Store.evaluate(keys, duration)
			if math.abs(opening - closing) > 1e-3 then
				refuse(
					where,
					`the range reaches the end of the loop, but the loop doesn't close: {track.joint} {track.channel} starts at {rounded(
						opening,
						4
					)} and ends at {rounded(closing, 4)}, so its end can't be joined to its start.`,
					"Close the loop first: copy_pose from 0 to its end."
				)
			end
		end
	end
	-- The loop is cut and joined at its whole number of frames. A loop that ends a little
	-- off a frame (0.667 typed for 20/30 of a second) would otherwise put every key that
	-- comes round the end that little off a frame too. Its stray end key, within a
	-- millisecond of the frame, is taken as the loop's end and put back on the frame. But
	-- only where no other key is that near the frame: a key just before an end that is
	-- just after the frame is a key of its own, and would be lost as the end. Such a loop
	-- is cut at its own length, as it is; keys that come round it may then land a little
	-- off a frame, which validation points out, but no motion is lost.
	local period = math.round(frames) / rate
	for _, track in Store.tracks(clip) do
		local keys = Store.keys(track.curve)
		for index = 1, #keys - 1 do
			if keys[index].time >= period - tolerance then
				period = duration
			end
		end
	end
	-- The loop started so that the range and its blends lie in its middle, on whole frames.
	local offset = math.round((period / 2 - (first + last) / 2) * rate) / rate
	local function onLoop(time: number): number
		local placed = time % period
		return if placed > period - tolerance then placed - period else placed
	end
	local moved = table.clone(operation)
	moved.time_from = from + offset
	moved.time_to = reach + offset
	if operation.at ~= nil then
		moved.at = onLoop(operation.at + offset)
	end

	local own: { [Instance]: { Key } } = {}
	for _, track in Store.tracks(clip) do
		own[track.curve] = Store.keys(track.curve)
	end
	startElsewhere(clip, offset, period)
	local started: { [Instance]: { Key } } = {}
	for curve in own do
		started[curve] = Store.keys(curve)
	end
	local found: Changed = {}
	apply(where, clip, moved, context, found)
	local left: { [Instance]: boolean } = {}
	for curve, keys in started do
		left[curve] = sameKeys(Store.keys(curve), keys)
	end
	startElsewhere(clip, -offset, period)
	-- Where the loop was started while the operation ran; a channel it changed is cut there.
	local cut = onLoop(-offset)
	for curve, keys in own do
		if left[curve] then
			Store.setKeys(curve, keys)
		else
			Store.setKeys(curve, withoutCut(Store.keys(curve), keys, cut))
		end
	end
	merge(changed, found, function(time: number): number
		return milliseconds(onLoop(time - offset))
	end)
end

return Seam
