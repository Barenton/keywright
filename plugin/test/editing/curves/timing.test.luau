--!strict
-- Timing: clearing a range, shifting, scaling and reversing, starting a loop elsewhere, and reducing keys.
-- Run with: lune run plugin/test/editing/curves/timing.test.luau

local Kit = require("./kit")

local Curves = Kit.Curves
local difference = Kit.difference
local keysOf = Kit.keysOf
local lopsided = Kit.lopsided
local placedAt = Kit.placedAt
local realRun = Kit.realRun
local refusal = Kit.refusal
local sampleAll = Kit.sampleAll
local squat = Kit.squat

local check, case, finish = Kit.suite("timing")
case("clear_keys removes a range's keys, so a pin can be redone over another range", function()
	local clip = squat(0.6)
	realRun(clip, {
		{ type = "set_key", joint = "LeftUpperLeg", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LeftUpperLeg", time = 1, rotation = { 10, 0, 0 } },
		{ type = "pin", part = "LeftFoot", time_from = 0.2, time_to = 0.8, blend_out = 0.1 },
	})
	local function timesOf(joint: string, channel: string): { number }
		local times = {}
		for _, key in keysOf(clip, joint, channel) do
			table.insert(times, math.round(key.time * 30))
		end
		return times
	end
	check("the pin keyed every frame", #timesOf("LeftLowerLeg", "rotation.x") > 20)

	local changed = realRun(clip, {
		{
			type = "clear_keys",
			time_from = 0.2,
			time_to = 0.9,
			joints = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" },
			channels = { "rotation" },
		},
	})
	check("keys were removed", (changed.keys_removed or 0) > 60, changed.keys_removed)
	local upper = timesOf("LeftUpperLeg", "rotation.x")
	check("keys outside the range stay", upper[1] == 0 and upper[#upper] == 30, table.concat(upper, ","))
	check("keys inside it are gone", #upper <= 4, table.concat(upper, ","))
	check("the hips are not touched", #keysOf(clip, "LowerTorso", "position.y") == 3)

	realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0.3, time_to = 0.5 } })
	-- After the new range, only a key holding the knee's own value (it was never keyed, so
	-- straight) may remain: nothing the first pin solved.
	local stray = 0
	for _, key in keysOf(clip, "LeftLowerLeg", "rotation.x") do
		if key.time > 16 / 30 + 1e-6 and math.abs(key.value) > 1e-6 then
			stray += 1
		end
	end
	check("a pin redone over a shorter range leaves no keys of the first", stray == 0, stray)
	check(
		"clearing a range with no keys is not an error",
		(realRun(clip, { { type = "clear_keys", time_from = 0.95, time_to = 0.96 } }).keys_removed or 0) == 0
	)
end)

case("a curve clip is retimed: shifted, scaled with or without ripple, and reversed", function()
	local original = lopsided()
	local clip = lopsided()
	-- Twice as slow from 0 to 0.5, the rest moved on to match.
	local changed = realRun(clip, { { type = "scale_time", time_from = 0, time_to = 0.5, factor = 2, ripple = true } })
	check("keys moved", (changed.keys_moved or 0) > 0, changed.keys_moved)
	check("the clip is half a second longer", math.abs(Curves.duration(clip) - 1.5) < 1e-9, Curves.duration(clip))
	local worst = 0
	for step = 0, 10 do
		local time = step / 20
		worst = math.max(worst, difference(sampleAll(clip, time * 2), sampleAll(original, time)))
	end
	for step = 0, 10 do
		local time = 0.5 + step / 20
		worst = math.max(worst, difference(sampleAll(clip, time + 0.5), sampleAll(original, time)))
	end
	check("the motion is the same, only slower in the range", worst < 1e-6, worst)

	local shifted = lopsided()
	realRun(shifted, {
		{ type = "set_key", joint = "Head", time = 1.5, rotation = { 0, 0, 0 } },
		{ type = "shift_time", time_from = 0.4, time_to = 1.1, offset = 0.2 },
	})
	check("a shift moves the keys in the range", difference(sampleAll(shifted, 1.2), sampleAll(original, 1)) < 1e-6)
	local passing = refusal(shifted, { { type = "shift_time", time_from = 0, time_to = 0.6, offset = 0.8 } })
	check(
		"and is refused past a key outside it",
		passing and string.find(passing.message, "would pass", 1, true),
		passing and passing.message
	)

	local reversed = lopsided()
	realRun(reversed, { { type = "reverse_time", time_from = 0, time_to = 1 } })
	local back = 0
	for step = 0, 30 do
		local time = step / 30
		back = math.max(back, difference(sampleAll(reversed, time), sampleAll(original, 1 - time)))
	end
	check("a reversed range plays the motion backward", back < 1e-6, back)
end)

case("a looping clip can be started somewhere else with shift_time and wrap", function()
	-- A loop that closes: it ends in the pose it begins with.
	local function closed(): any
		local clip = lopsided()
		realRun(clip, { { type = "set_properties", loop = true }, { type = "copy_pose", from = 0, to = 1 } })
		return clip
	end
	local original = closed()
	local clip = closed()
	realRun(clip, { { type = "shift_time", time_from = 0, time_to = 1, offset = 0.25, wrap = true } })
	local worst = 0
	for step = 0, 40 do
		local time = step / 40
		worst = math.max(worst, difference(sampleAll(clip, time), sampleAll(original, (time - 0.25) % 1)))
	end
	check("each moment comes a quarter later, carried round", worst < 1e-4, worst)
	check("the clip is as long as it was", math.abs(Curves.duration(clip) - 1) < 1e-9, Curves.duration(clip))
	local plain = lopsided()
	check(
		"not in a clip that does not loop",
		refusal(plain, { { type = "shift_time", time_from = 0, time_to = 1, offset = 0.25, wrap = true } }) ~= nil
	)
	check(
		"nor over part of a clip",
		refusal(clip, { { type = "shift_time", time_from = 0, time_to = 0.5, offset = 0.25, wrap = true } }) ~= nil
	)
end)

case("squeezing keys onto fewer frames joins them, and says so", function()
	local clip = squat(0.5)
	realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1 } })
	local changed = realRun(clip, { { type = "scale_time", time_from = 0, time_to = 1, factor = 0.5 } })
	check("keys were joined", (changed.keys_merged or 0) > 0, changed.keys_merged)
	check("from when", changed.first_merge_at ~= nil, changed.first_merge_at)
	local onFrames = true
	for _, key in keysOf(clip, "LeftLowerLeg", "rotation.x") do
		onFrames = onFrames and math.abs(key.time * 30 - math.round(key.time * 30)) < 1e-6
	end
	check("every key is on a whole frame", onFrames)
end)

case("reduce_keys rebuilds a channel from few keys, the same at every frame", function()
	local clip = squat(0.6)
	realRun(clip, {
		{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 0, 0 }, interpolation = "Constant" },
		{ type = "set_key", joint = "Head", time = 0.4, rotation = { 20, 0, 0 }, interpolation = "Constant" },
		{ type = "set_key", joint = "Head", time = 0.7, rotation = { 0, 10, 0 }, interpolation = "Linear" },
		{ type = "set_key", joint = "Head", time = 1, rotation = { 0, 0, 0 } },
		{ type = "pin", part = "LeftFoot", time_from = 0, time_to = 1 },
	})
	local before = {}
	for frame = 0, 30 do
		before[frame] = sampleAll(clip, frame / 30)
	end
	local knee = #keysOf(clip, "LeftLowerLeg", "rotation.x")
	local changed = realRun(clip, { { type = "reduce_keys", time_from = 0, time_to = 1 } })
	local after = #keysOf(clip, "LeftLowerLeg", "rotation.x")
	check("keys were removed", (changed.keys_removed or 0) > 0, changed.keys_removed)
	check("the pinned knee needs well under half as many", after * 2 < knee, `{knee} to {after}`)
	local worst = 0
	for frame = 0, 30 do
		worst = math.max(worst, difference(sampleAll(clip, frame / 30), before[frame]))
	end
	check("every channel is within a tenth of a degree at every frame", worst <= math.rad(0.1) + 1e-9, math.deg(worst))
	local foot = 0
	local start = placedAt(clip, 0).LeftFoot.Position
	for frame = 0, 30 do
		foot = math.max(foot, (placedAt(clip, frame / 30).LeftFoot.Position - start).Magnitude)
	end
	check("so the pinned foot stays put", foot < 0.01, foot)

	local partial = squat(0.6)
	realRun(partial, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1 } })
	realRun(partial, { { type = "reduce_keys", time_from = 0.5, time_to = 1, joints = { "LeftLowerLeg" } } })
	local early = 0
	for _, key in keysOf(partial, "LeftLowerLeg", "rotation.x") do
		if key.time < 0.5 - 1e-6 then
			early += 1
		end
	end
	check("keys before the range are kept", early == 15, early)
	check(
		"joints not named are kept",
		#keysOf(partial, "LeftUpperLeg", "rotation.x") == 31,
		#keysOf(partial, "LeftUpperLeg", "rotation.x")
	)
	check(
		"a range too long is refused",
		refusal(partial, { { type = "reduce_keys", time_from = 0, time_to = 100 } }) ~= nil
	)
end)

finish()
