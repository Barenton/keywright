--!strict
-- Writing a channel frame by frame: putting keys, smoothing, cutting exactly at the ends
-- of a range, carrying a loop round, and reducing a range again to few keys.

local Errors = require("../../Core/Errors")
local Frames = require("./Frames")
local Smooth = require("../Smooth")
local Store = require("./Store")

local count = Frames.count
local near = Frames.near
local sortKeys = Store.sortKeys

type Changed = Frames.Changed
type Key = Store.Key
type Span = Frames.Span

local Write = {}

-- Puts a value into a channel at a time: the key there is changed, or one is made.
local function putKey(curve: Instance, time: number, value: number, interpolation: string?, changed: Changed)
	local keys = Store.keys(curve)
	for _, key in keys do
		if near(key.time, time) then
			key.value = value
			if interpolation then
				key.interpolation = interpolation
				if interpolation ~= "Cubic" then
					key.right = nil
				end
			end
			Store.setKeys(curve, keys)
			count(changed, "keys_changed")
			return
		end
	end
	if #keys >= Store.MAX_KEYS then
		Errors.throw("LIMIT_EXCEEDED", `A curve holds at most {Store.MAX_KEYS} keys.`)
	end
	local mode = interpolation or "Cubic"
	if #keys == 0 and time > Store.TIME_TOLERANCE then
		-- A channel with no keys is at rest the whole clip. A curve holds its first key's
		-- value back to the start, so a first key later on would change everything before
		-- it too. A key at rest at the start keeps the time before as it was.
		table.insert(
			keys,
			{ time = 0, value = 0, interpolation = mode, left = 0, right = if mode == "Cubic" then 0 else nil }
		)
		count(changed, "keys_created")
	end
	table.insert(keys, {
		time = time,
		value = value,
		interpolation = mode,
		left = 0,
		right = if mode == "Cubic" then 0 else nil,
	})
	Store.setKeys(curve, keys)
	count(changed, "keys_created")
end

-- Writes tangents for every key of a channel that lies in a range: those a smooth curve
-- through the keys would have, as in smooth_motion. Keys in the range become Cubic.
local function smoothChannel(curve: Instance, from: number, to: number, snapTimes: { number }, loop: boolean): number
	local keys = Store.keys(curve)
	if #keys < 2 then
		return 0
	end
	local smoothKeys: { Smooth.Key } = {}
	local snap: { [number]: boolean } = {}
	for index, key in keys do
		smoothKeys[index] = { time = key.time, values = { key.value } }
		for _, at in snapTimes do
			if near(key.time, at) then
				snap[index] = true
			end
		end
	end
	local arriving, leaving = Smooth.tangents(smoothKeys, 1, { snap = snap, loop = loop })
	local written = 0
	for index, key in keys do
		if key.time >= from - Store.TIME_TOLERANCE and key.time <= to + Store.TIME_TOLERANCE then
			key.left = arriving[index]
			if index < #keys then
				key.interpolation = "Cubic"
				key.right = leaving[index]
			end
			written += 1
		end
	end
	Store.setKeys(curve, keys)
	return written
end

-- Every rotation has two sets of Euler angles that give it, and each angle can be taken a
-- whole turn either way. The set nearest the angles a curve is at already is the one it
-- should run to, or it would swing the long way round.
local function nearestAngles(x: number, y: number, z: number, previous: { number }): { number }
	local function placed(angles: { number }): ({ number }, number)
		local out, distance = {}, 0
		for index = 1, 3 do
			local angle, before = angles[index], previous[index]
			angle = before + ((angle - before + math.pi) % (2 * math.pi)) - math.pi
			out[index] = angle
			distance += math.abs(angle - before)
		end
		return out, distance
	end
	local first, firstDistance = placed({ x, y, z })
	local second, secondDistance = placed({ x + math.pi, math.pi - y, z + math.pi })
	return if secondDistance < firstDistance then second else first
end

-- Whole frames from `first` to `last`, with a value for each, in order.
export type FrameValues = { first: number, last: number, values: { number }, duration: number }

-- Replaces a channel's keys from one whole frame to another with one key a frame, with
-- smooth tangents, and leaves the rest of the channel exactly as it was. To do that, the
-- curve is cut a frame either side of the range, with a key there on the original curve,
-- at its slope: a stretch of curve cut at a point with its own value and slope keeps its
-- shape, so the motion outside the range does not change. `original` is the channel's keys
-- before the change.
local function writeFrames(
	clip: Instance,
	joint: string,
	channel: string,
	original: { Key },
	frames: FrameValues,
	changed: Changed
)
	local rate = Store.FRAME_RATE
	local tolerance = Store.TIME_TOLERANCE
	local startTime, endTime = frames.first / rate, frames.last / rate
	local kept: { Key } = {}
	for _, key in original do
		if key.time < startTime - tolerance or key.time > endTime + tolerance then
			table.insert(kept, table.clone(key))
		end
	end
	-- A step small enough that a slope measured over it is the slope at the point.
	local h = 1e-6
	local function cut(time: number): Key?
		for _, key in original do
			if math.abs(key.time - time) < tolerance then
				return nil
			end
		end
		-- The stretch the cut falls in keeps its shape on both sides of it.
		local mode = "Cubic"
		for _, key in original do
			if key.time < time then
				mode = key.interpolation
			end
		end
		local value = Store.evaluate(original, time)
		return {
			time = time,
			value = value,
			interpolation = mode,
			left = (value - Store.evaluate(original, time - h)) / h,
			right = if mode == "Cubic" then (Store.evaluate(original, time + h) - value) / h else nil,
		}
	end
	local guards = 0
	if frames.first > 0 then
		local before = cut((frames.first - 1) / rate)
		if before then
			-- The new keys start right after it, so it leads into them smoothly.
			before.interpolation = "Cubic"
			before.right = before.right or before.left
			table.insert(kept, before)
			guards += 1
		end
	end
	if endTime < frames.duration - tolerance then
		local after = cut((frames.last + 1) / rate)
		if after then
			table.insert(kept, after)
			guards += 1
		end
	end
	for index, value in frames.values do
		table.insert(kept, {
			time = (frames.first + index - 1) / rate,
			value = value,
			interpolation = "Cubic",
			left = 0,
			right = 0,
		})
	end
	if #kept > Store.MAX_KEYS then
		Errors.throw("LIMIT_EXCEEDED", `A curve holds at most {Store.MAX_KEYS} keys.`)
	end
	sortKeys(kept)
	local curve = Store.channel(clip, joint, channel, true) :: Instance
	Store.setKeys(curve, kept)
	-- Only the new keys' tangents are worked out; the cuts keep the original's slopes.
	smoothChannel(curve, startTime, endTime, {}, false)
	count(changed, "keys_written", #frames.values + guards)
end

-- A channel's keys moved later by `offset` within a looping clip of length `duration`,
-- those carried past the end coming round to the start. The curve is cut where the clip
-- now starts, with a key there and at the end on the curve, at its slope, so that the
-- motion is the same, only later.
local function wrapped(keys: { Key }, offset: number, duration: number): { Key }
	local tolerance = Store.TIME_TOLERANCE
	if #keys <= 1 or duration <= tolerance then
		local out = {}
		for _, key in keys do
			local copy = table.clone(key)
			copy.time = 0
			table.insert(out, copy)
		end
		return out
	end
	local shift = offset % duration
	local out: { Key } = {}
	for _, key in keys do
		if key.time < duration - tolerance then
			local copy = table.clone(key)
			copy.time = (key.time + shift) % duration
			table.insert(out, copy)
		end
	end
	-- What used to be played at `cut` is now played at the start, and again at the end.
	local cut = (duration - shift) % duration
	local function edge(time: number): Key
		local h = 1e-4
		local slope = (Store.evaluate(keys, math.min(cut + h, duration)) - Store.evaluate(keys, math.max(cut - h, 0)))
			/ (math.min(cut + h, duration) - math.max(cut - h, 0))
		local mode = keys[1].interpolation
		for _, key in keys do
			if key.time <= cut + tolerance then
				mode = key.interpolation
			end
		end
		return {
			time = time,
			value = Store.evaluate(keys, cut),
			interpolation = mode,
			left = slope,
			right = if mode == "Cubic" then slope else nil,
		}
	end
	local hasStart = false
	for _, key in out do
		if key.time < tolerance then
			hasStart = true
		end
	end
	if not hasStart then
		table.insert(out, edge(0))
	end
	table.insert(out, edge(duration))
	sortKeys(out)
	return out
end

-- ---------------------------------------------------------------------------------------
-- Retiming

-- The nearest whole frame to a time: Studio shows a curve clip only at whole frames.
local function onFrame(time: number): number
	return math.round(time * Store.FRAME_RATE) / Store.FRAME_RATE
end

-- The keys of one channel from its first to its last key in a range, rebuilt from as few
-- keys as keep the curve within `tolerance` of the original at every whole frame, which is
-- all Studio shows of it. The two end keys stay as they are, so the curve meets the rest
-- of the channel as before. Each key added is put on the original curve at a whole frame,
-- with the original's slope there on each side; the frame furthest from the original is
-- added first, until none is too far. Returns nil when the channel has nothing to reduce.
local function reduced(keys: { Key }, from: number, to: number, tolerance: number): { Key }?
	local tol = Store.TIME_TOLERANCE
	local first, last = nil, nil
	for index, key in keys do
		if key.time >= from - tol and key.time <= to + tol then
			first = first or index
			last = index
		end
	end
	if not first or not last or last - first < 2 then
		return nil
	end
	local rate = Store.FRAME_RATE
	local startFrame = math.ceil(keys[first].time * rate - 1e-6)
	local endFrame = math.floor(keys[last].time * rate + 1e-6)
	local frames: { number } = {}
	local values: { number } = {}
	for frame = startFrame, endFrame do
		table.insert(frames, frame / rate)
		table.insert(values, Store.evaluate(keys, frame / rate))
	end
	local h = 1e-4
	local function keyAt(time: number): Key
		local value = Store.evaluate(keys, time)
		return {
			time = time,
			value = value,
			interpolation = "Cubic",
			left = (value - Store.evaluate(keys, time - h)) / h,
			right = (Store.evaluate(keys, time + h) - value) / h,
		}
	end
	local kept: { Key } = { table.clone(keys[first]), table.clone(keys[last]) }
	-- The first key's stretch is now shaped by the keys added after it; it is made Cubic
	-- with the slope the original leaves it with, unless it held still.
	local function fixFirst()
		local head = kept[1]
		if head.interpolation ~= "Cubic" and #kept > 2 then
			head.right = (Store.evaluate(keys, head.time + h) - head.value) / h
			head.interpolation = "Cubic"
		end
	end
	for _ = 1, #frames do
		local worst, at = 0, nil
		for index, time in frames do
			local miss = math.abs(Store.evaluate(kept, time) - values[index])
			if miss > worst then
				worst, at = miss, time
			end
		end
		if worst <= tolerance or not at then
			break
		end
		table.insert(kept, keyAt(at))
		sortKeys(kept)
		fixFirst()
	end
	if #kept >= last - first + 1 then
		return nil
	end
	local out: { Key } = {}
	for index, key in keys do
		if index < first or index > last then
			table.insert(out, key)
		end
	end
	for _, key in kept do
		table.insert(out, key)
	end
	sortKeys(out)
	return out
end

-- Writes a joint's rotation at every frame from `first` to `last` from the transforms
-- given, one a frame, keeping each angle near the one before so that a curve never swings
-- the long way round. With `reduce`, the keys there are then reduced again to as few as
-- keep the result, so the curves stay ones a person can edit. `own` is the joint's
-- channels before the change.
local function writeTurns(
	clip: Instance,
	joint: string,
	own: { [string]: { Key } },
	first: number,
	last: number,
	turns: { CFrame },
	duration: number,
	changed: Changed,
	reduce: boolean
)
	local rate = Store.FRAME_RATE
	local before: { number } = {}
	for axis, letter in { "x", "y", "z" } do
		local keys = own[`rotation.{letter}`]
		before[axis] = if keys then Store.evaluate(keys, first / rate) else 0
	end
	local angles: { { number } } = {}
	local previous = before
	for _, turn in turns do
		local x, y, z = turn:ToEulerAnglesXYZ()
		previous = nearestAngles(x, y, z, previous)
		table.insert(angles, previous)
	end
	for axis, letter in { "x", "y", "z" } do
		local channel = `rotation.{letter}`
		local values = {}
		for frame in turns do
			values[frame] = angles[frame][axis]
		end
		local frames = { first = first, last = last, values = values, duration = duration }
		if not reduce then
			writeFrames(clip, joint, channel, own[channel] or {}, frames, changed)
			continue
		end
		writeFrames(clip, joint, channel, own[channel] or {}, frames, {})
		local curve = Store.channel(clip, joint, channel, false) :: Instance
		local keys = Store.keys(curve)
		local out = reduced(keys, (first - 1) / rate, (last + 1) / rate, math.rad(Store.REDUCE_DEGREES)) or keys
		Store.setKeys(curve, out)
		count(changed, "keys_written", #out)
	end
end

-- ---------------------------------------------------------------------------------------
-- Adding motion on top of a clip

-- Adds `amount(time)` to one channel at every frame of a span, then reduces the keys there
-- again to as few as keep the result, so the curve stays one a person can edit.
local function addToChannel(
	clip: Instance,
	joint: string,
	channel: string,
	span: Span,
	amount: (time: number) -> number,
	changed: Changed
)
	local curve = Store.channel(clip, joint, channel, false)
	local original = if curve then Store.keys(curve) else {}
	local rate = Store.FRAME_RATE
	local values = {}
	for frame = span.first, span.last do
		local time = frame / rate
		table.insert(values, Store.evaluate(original, time) + amount(time))
	end
	-- Counted once below, as the keys the channel ends up with.
	local scratch: Changed = {}
	writeFrames(clip, joint, channel, original, {
		first = span.first,
		last = span.last,
		values = values,
		duration = Store.duration(clip),
	}, scratch)
	local written = Store.channel(clip, joint, channel, false) :: Instance
	local tolerance = if string.sub(channel, 1, 8) == "rotation"
		then math.rad(Store.REDUCE_DEGREES)
		else Store.REDUCE_STUDS
	local keys = Store.keys(written)
	local out = reduced(keys, (span.first - 1) / rate, (span.last + 1) / rate, tolerance) or keys
	Store.setKeys(written, out)
	count(changed, "keys_written", #out)
end

Write.putKey = putKey
Write.smoothChannel = smoothChannel
Write.nearestAngles = nearestAngles
Write.writeFrames = writeFrames
Write.wrapped = wrapped
Write.onFrame = onFrame
Write.reduced = reduced
Write.writeTurns = writeTurns
Write.addToChannel = addToChannel

return Write
