--!strict
-- Ranges that reach a looping clip's end, or run across it: the end and the start are one
-- moment, so both change alike, and the loop stays closed.

local Kit = require("./kit")

local Curves = Kit.Curves
local difference = Kit.difference
local keysOf = Kit.keysOf
local lopsided = Kit.lopsided
local placedAt = Kit.placedAt
local realRun = Kit.realRun
local refusal = Kit.refusal
local sampleAll = Kit.sampleAll

local check, case, finish = Kit.suite("seam")

-- A loop that closes: it ends in the pose it begins with.
local function closed(): any
	local clip = lopsided()
	realRun(clip, {
		{ type = "set_properties", loop = true },
		{ type = "copy_pose", from = 0, to = 1 },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	return clip
end

local function value(clip: any, joint: string, channel: string, time: number): number
	return Curves.evaluate(keysOf(clip, joint, channel), time)
end

local function sameKeys(a: { any }, b: { any }): boolean
	if #a ~= #b then
		return false
	end
	for index, key in a do
		local other = b[index]
		if
			math.abs(key.time - other.time) > 1e-9
			or key.value ~= other.value
			or key.left ~= other.left
			or key.right ~= other.right
		then
			return false
		end
	end
	return true
end

-- The largest difference between two clips over a stretch of frames.
local function apart(a: any, b: any, from: number, to: number): number
	local worst = 0
	for frame = math.round(from * 30), math.round(to * 30) do
		worst = math.max(worst, difference(sampleAll(a, frame / 30), sampleAll(b, frame / 30)))
	end
	return worst
end

case("a range that reaches the end of a loop changes its start alike", function()
	local original = closed()
	local clip = closed()
	realRun(clip, {
		{ type = "add_offset", joint = "UpperTorso", time_from = 0.7, time_to = 1, rotation = { 0, 30, 0 } },
	})
	local seam = difference(sampleAll(clip, 0), sampleAll(clip, 1))
	check("the loop stays closed", seam < 1e-6, seam)
	local start = value(clip, "UpperTorso", "rotation.y", 0) - value(original, "UpperTorso", "rotation.y", 0)
	check("the start has the offset too", math.abs(start - math.rad(30)) < 1e-4, math.deg(start))
	local middle = apart(clip, original, 0.0667, 0.6667)
	check("the motion outside the range is as it was", middle < 1e-6, middle)
	check(
		"a channel it does not change keeps its keys, key for key",
		sameKeys(keysOf(clip, "LeftUpperArm", "rotation.x"), keysOf(original, "LeftUpperArm", "rotation.x"))
	)
	local count = #keysOf(clip, "UpperTorso", "rotation.x")
	check(
		"one it changes gains no key where the loop was started meanwhile",
		count == #keysOf(original, "UpperTorso", "rotation.x"),
		count
	)
end)

case("in a loop, a range runs across the end when time_from is after time_to", function()
	local original = closed()
	local clip = closed()
	realRun(clip, {
		{ type = "add_offset", joint = "UpperTorso", time_from = 0.8, time_to = 0.2, rotation = { 0, 30, 0 } },
	})
	for _, time in { 0.9, 0, 0.1, 1 } do
		local added = value(clip, "UpperTorso", "rotation.y", time) - value(original, "UpperTorso", "rotation.y", time)
		-- Within what reducing the keys leaves, 0.1 degrees.
		check(`offset at {time}`, math.abs(added - math.rad(30)) < math.rad(0.1), math.deg(added))
	end
	local middle = apart(clip, original, 0.2333, 0.7667)
	check("not between", middle < 1e-6, middle)

	-- Blends run across it too: a range near the start eases in from before the end.
	local blended = closed()
	realRun(blended, {
		{
			type = "add_offset",
			joint = "UpperTorso",
			time_from = 0.1,
			time_to = 0.3,
			blend_in = 0.2,
			rotation = { 0, 30, 0 },
		},
	})
	local function added(time: number): number
		return math.deg(
			value(blended, "UpperTorso", "rotation.y", time) - value(original, "UpperTorso", "rotation.y", time)
		)
	end
	check("the blend starts before the end", math.abs(added(0.9)) < 1e-3, added(0.9))
	check("and is part of the way at it", added(0) > 5 and added(0) < 25, added(0))
	check("in full in the range", math.abs(added(0.2) - 30) < 1e-3, added(0.2))
	local seam = difference(sampleAll(blended, 0), sampleAll(blended, 1))
	check("and the loop stays closed", seam < 1e-6, seam)
end)

case("a planted foot is held across a loop's end", function()
	-- Hips that sway in a closed loop, and a foot held from 0.9 to 0.1 moving back with
	-- the floor of a cycle made on the spot.
	local function swaying(height: number): any
		local clip = Kit.blank()
		realRun(clip, {
			{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, height, 0 } },
			{ type = "set_key", joint = "LowerTorso", time = 0.5, position = { 0.3, height - 0.1, 0.2 } },
			{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, height, 0 } },
			{ type = "set_properties", loop = true },
			{ type = "auto_tangents", time_from = 0, time_to = 1 },
		})
		return clip
	end
	local held = {
		type = "pin",
		part = "LeftFoot",
		time_from = 0.9,
		time_to = 0.1,
		blend_in = 0.1,
		blend_out = 0.1,
		travel = { 0, 0, 1.5 },
	}
	-- Set on the floor, below hips lowered on straight legs, the knee bends and has room.
	local planted = table.clone(held)
	planted.on_floor = true
	local clip = swaying(-0.5)
	local changed = realRun(clip, { planted })
	check("every frame of the range and its blends is written", changed.frames_pinned == 13, changed.frames_pinned)
	check("all within reach", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local worst = 0
	local previous = placedAt(clip, 0.9).LeftFoot.Position
	-- Exact frames: 28/30 to 30/30, then 1/30 to 3/30.
	for _, frame in { 28, 29, 30, 1, 2, 3 } do
		local here = placedAt(clip, frame / 30).LeftFoot.Position
		worst = math.max(worst, (here - previous - Kit.roblox.Vector3.new(0, 0, 1.5 / 30)).Magnitude)
		previous = here
	end
	check("it moves back steadily, on through the end", worst < 1e-5, worst)
	local seam = difference(sampleAll(clip, 0), sampleAll(clip, 1))
	check("and the loop stays closed", seam < 1e-6, seam)

	-- Held where straight legs put it, the foot is out of reach as soon as it moves; the
	-- times reported are on the loop as it is, the first after the last since the frames
	-- run across the end.
	local reaching = realRun(swaying(-0.2), { held })
	check(
		"frames out of reach are reported where they are",
		reaching.out_of_reach_from ~= nil
			and reaching.out_of_reach_from > 0.85
			and reaching.out_of_reach_to ~= nil
			and reaching.out_of_reach_to < 0.15,
		`{reaching.out_of_reach_from} to {reaching.out_of_reach_to}`
	)
end)

case("a loop that ends just off a whole frame keeps its keys on frames across the end", function()
	-- Typed as 0.667 rather than exactly 20/30 seconds, as an agent did: near enough to a
	-- whole number of frames for a range to run across the end, but the loop must be cut
	-- and joined at the whole frame, or every key that comes round lands just off a frame.
	local function made(): any
		local clip = Kit.blank()
		local operations = {}
		for _, joint in { "UpperTorso", "LeftUpperArm" } do
			table.insert(operations, { type = "set_key", joint = joint, time = 0, rotation = { 0, 0, 0 } })
			table.insert(operations, { type = "set_key", joint = joint, time = 1 / 3, rotation = { 20, 10, 0 } })
			table.insert(operations, { type = "set_key", joint = joint, time = 0.667, rotation = { 0, 0, 0 } })
		end
		table.insert(operations, { type = "set_properties", loop = true })
		realRun(clip, operations)
		return clip
	end
	local original = made()
	local clip = made()
	realRun(clip, {
		{ type = "add_offset", joint = "UpperTorso", time_from = 0.6, time_to = 0.1, rotation = { 0, 30, 0 } },
	})
	local worst = 0
	for _, key in keysOf(clip, "UpperTorso", "rotation.y") do
		worst = math.max(worst, math.abs(key.time * 30 - math.round(key.time * 30)))
	end
	check("every key of the channel it changed is on a whole frame", worst < 1e-4, worst / 30)
	check(
		"a channel it does not change keeps its keys, the stray end key too",
		sameKeys(keysOf(clip, "UpperTorso", "rotation.x"), keysOf(original, "UpperTorso", "rotation.x"))
	)
	local added = value(clip, "UpperTorso", "rotation.y", 2 / 30) - value(original, "UpperTorso", "rotation.y", 2 / 30)
	check("the range across the end has the offset", math.abs(math.deg(added) - 30) < 0.1, math.deg(added))
end)

case("what a range across a loop's end cannot be", function()
	local plain = lopsided()
	check(
		"time_from after time_to in a clip that does not loop",
		refusal(plain, { { type = "add_offset", joint = "UpperTorso", time_from = 0.8, time_to = 0.2 } }) ~= nil
	)
	local clip = closed()
	check("so long that no room is left in the loop", refusal(clip, {
		{ type = "add_offset", joint = "UpperTorso", time_from = 0.5, time_to = 0.45, rotation = { 0, 10, 0 } },
	}) ~= nil)
	check(
		"for an operation that does not write frames",
		refusal(clip, { { type = "reduce_keys", time_from = 0.8, time_to = 0.2 } }) ~= nil
	)
	check("the whole loop is still the whole loop", refusal(clip, {
		{ type = "add_offset", joint = "UpperTorso", time_from = 0, time_to = 1, rotation = { 0, 10, 0 } },
	}) == nil)
end)

finish()
