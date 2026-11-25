--!strict
-- Motion added on top of a clip: offsets, noise, aiming and overlap.
-- Run with: lune run plugin/test/editing/curves/motion.test.luau

local Kit = require("./kit")

local blank = Kit.blank
local Curves = Kit.Curves
local difference = Kit.difference
local hunch = Kit.hunch
local keysOf = Kit.keysOf
local lopsided = Kit.lopsided
local offAim = Kit.offAim
local placedAt = Kit.placedAt
local realRun = Kit.realRun
local refusal = Kit.refusal
local roblox = Kit.roblox
local sampleAll = Kit.sampleAll
local turnAndStop = Kit.turnAndStop
local turnBetween = Kit.turnBetween
local yaw = Kit.yaw

local check, case, finish = Kit.suite("motion")
case("aim turns a joint to face a point, or holds its facing", function()
	local target = roblox.Vector3.new(2, 1, -6)
	local clip = hunch()
	local changed =
		realRun(clip, { { type = "aim", joint = "Head", time_from = 0, time_to = 1, target = { 2, 1, -6 } } })
	check("every frame was aimed", changed.frames_aimed == 31, changed.frames_aimed)
	local worst = 0
	for frame = 0, 30 do
		worst = math.max(worst, offAim(placedAt(clip, frame / 30).Head, target))
	end
	check("the head faces the point at every frame", worst < 0.25, worst)

	local partial = hunch()
	local original = hunch()
	realRun(partial, { { type = "aim", joint = "Head", time_from = 0.3, time_to = 0.7, target = { 2, 1, -6 } } })
	local outside = 0
	for frame = 0, 30 do
		local time = frame / 30
		if time < 0.3 - 1 / 30 - 1e-6 or time > 0.7 + 1 / 30 + 1e-6 then
			outside = math.max(outside, difference(sampleAll(partial, time), sampleAll(original, time)))
		end
	end
	check("frames outside the range are unchanged", outside < 1e-6, outside)

	local half = hunch()
	realRun(half, { { type = "aim", joint = "Head", time_from = 0, time_to = 1, target = { 2, 1, -6 }, weight = 0.5 } })
	local before, after = offAim(placedAt(original, 0.5).Head, target), offAim(placedAt(half, 0.5).Head, target)
	check("half the weight turns it half way", math.abs(after - before / 2) < 0.5, `{before} to {after}`)

	local limited = hunch()
	realRun(limited, {
		{ type = "aim", joint = "Head", time_from = 0, time_to = 1, target = { 2, 1, -6 }, limit_degrees = 10 },
	})
	local most = 0
	for frame = 0, 30 do
		most = math.max(most, turnBetween(placedAt(limited, frame / 30).Head, placedAt(original, frame / 30).Head))
	end
	check("a limit caps the turn", most <= 10.3 and most > 9, most)

	local steady = hunch()
	local start = placedAt(steady, 0).Head
	realRun(steady, { { type = "aim", joint = "Head", time_from = 0, time_to = 1, hold = true } })
	local drift = 0
	for frame = 0, 30 do
		drift = math.max(drift, turnBetween(placedAt(steady, frame / 30).Head, start))
	end
	check("held, the head keeps its facing as the chest bends and turns", drift < 0.25, drift)
	check(
		"target and hold together are refused",
		refusal(
			steady,
			{ { type = "aim", joint = "Head", time_from = 0, time_to = 1, hold = true, target = { 0, 0, -1 } } }
		) ~= nil
	)
end)

case("overlap has a chain trail the body, swing on and settle", function()
	local arm = { "LeftHand", "LeftUpperArm", "LeftLowerArm" }
	local rigid = turnAndStop()
	local clip = turnAndStop()
	realRun(clip, { { type = "overlap", joints = arm, time_from = 0, time_to = 1.2, lag = 0.1, bounce = 0.5 } })
	local during, stiff = yaw(placedAt(clip, 0.15).LeftHand), yaw(placedAt(rigid, 0.15).LeftHand)
	check("mid-turn, the hand trails behind", math.abs(during) < math.abs(stiff) - 2, `{during} against {stiff}`)
	local furthest = 0
	for frame = 9, 30 do
		furthest = math.max(furthest, math.abs(yaw(placedAt(clip, frame / 30).LeftHand)))
	end
	check("after the chest stops, it swings past", furthest > 60.5, furthest)
	local settled = math.abs(math.abs(yaw(placedAt(clip, 1.2).LeftHand)) - 60)
	check("and settles where the chest left it", settled < 0.5, settled)
	check(
		"the chest itself is not touched",
		difference(
			{ Curves.evaluate(keysOf(clip, "UpperTorso", "rotation.y"), 0.2) },
			{ Curves.evaluate(keysOf(rigid, "UpperTorso", "rotation.y"), 0.2) }
		) < 1e-12
	)

	local calm = turnAndStop()
	realRun(calm, { { type = "overlap", joints = arm, time_from = 0, time_to = 1.2, lag = 0.1, bounce = 0 } })
	local most = 0
	for frame = 9, 36 do
		most = math.max(most, math.abs(yaw(placedAt(calm, frame / 30).LeftHand)))
	end
	check("with no bounce, it trails but does not swing past", most < 60.3, most)

	local loop = blank()
	realRun(loop, {
		{ type = "set_key", joint = "UpperTorso", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 0.5, rotation = { 0, 35, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 1, rotation = { 0, 0, 0 } },
		{ type = "set_properties", loop = true },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
		{ type = "overlap", joints = arm, time_from = 0, time_to = 1, lag = 0.15, bounce = 0.3 },
	})
	local seam = turnBetween(placedAt(loop, 0).LeftHand, placedAt(loop, 1).LeftHand)
	check("in a looping clip, it ends where it began", seam < 0.3, seam)
	local behind = turnBetween(placedAt(loop, 0).LeftHand, placedAt(loop, 0).UpperTorso)
	check("which, in a loop, is still trailing at the start", behind > 1, behind)
	check(
		"a lag out of bounds is refused",
		refusal(loop, { { type = "overlap", joints = arm, time_from = 0, time_to = 1, lag = 3 } }) ~= nil
	)
end)

case("add_offset adds a turn over a range, easing in and out", function()
	local original = lopsided()
	local clip = lopsided()
	realRun(clip, {
		{
			type = "add_offset",
			joint = "UpperTorso",
			time_from = 0.3,
			time_to = 0.6,
			rotation = { 15, 0, 0 },
			blend_in = 0.1,
			blend_out = 0.1,
		},
	})
	local function torso(c: any, time: number): number
		return Curves.evaluate(keysOf(c, "UpperTorso", "rotation.x"), time)
	end
	local inside, outside = 0, 0
	for frame = 0, 30 do
		local time = frame / 30
		local added = math.deg(torso(clip, time) - torso(original, time))
		if time >= 0.3 - 1e-6 and time <= 0.6 + 1e-6 then
			inside = math.max(inside, math.abs(added - 15))
		elseif time <= 0.2 + 1e-6 or time >= 0.7 - 1e-6 then
			outside = math.max(outside, math.abs(added))
		end
	end
	check("all of it inside the range", inside < 0.11, inside)
	check("none of it outside the blends", outside < 0.11, outside)
	local halfway = math.deg(torso(clip, 0.25) - torso(original, 0.25))
	check("part of it halfway into the blend", halfway > 3 and halfway < 12, halfway)
	check("other channels and joints are untouched", difference({
		Curves.evaluate(keysOf(clip, "UpperTorso", "rotation.y"), 0.5),
		Curves.evaluate(keysOf(clip, "Head", "rotation.x"), 0.5),
	}, { Curves.evaluate(keysOf(original, "UpperTorso", "rotation.y"), 0.5), 0 }) < 1e-9)
	check("and the result is not a key a frame", #keysOf(clip, "UpperTorso", "rotation.x") < 20)
end)

case("add_noise sways joints, the same for a seed, and loops in a looping clip", function()
	local function noisy(seed: number, loop: boolean): any
		local clip = blank()
		realRun(clip, {
			{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
			{ type = "set_key", joint = "Head", time = 2, rotation = { 0, 0, 0 } },
			{ type = "set_properties", loop = loop },
			{
				type = "add_noise",
				joints = { "Head", "UpperTorso" },
				time_from = 0,
				time_to = 2,
				rotation_degrees = 5,
				frequency = 1,
				seed = seed,
			},
		})
		return clip
	end
	local clip = noisy(3, true)
	local largest = 0
	for frame = 0, 60 do
		for _, channel in { "rotation.x", "rotation.y", "rotation.z" } do
			largest = math.max(largest, math.abs(math.deg(Curves.evaluate(keysOf(clip, "Head", channel), frame / 30))))
		end
	end
	check("it moves", largest > 1, largest)
	check("no further than asked", largest <= 5.11, largest)
	local seam = 0
	for _, joint in { "Head", "UpperTorso" } do
		for _, channel in { "rotation.x", "rotation.y", "rotation.z" } do
			local keys = keysOf(clip, joint, channel)
			seam = math.max(seam, math.abs(math.deg(Curves.evaluate(keys, 0) - Curves.evaluate(keys, 2))))
		end
	end
	check("in a loop, it ends where it began", seam < 0.11, seam)
	check("the same seed gives the same sway", difference(sampleAll(noisy(3, true), 0.7), sampleAll(clip, 0.7)) < 1e-9)
	check("another seed another", difference(sampleAll(noisy(4, true), 0.7), sampleAll(clip, 0.7)) > 1e-3)
	check(
		"each joint sways its own way",
		math.abs(
			Curves.evaluate(keysOf(clip, "Head", "rotation.x"), 0.7)
				- Curves.evaluate(keysOf(clip, "UpperTorso", "rotation.x"), 0.7)
		) > 1e-4
	)
	check(
		"with nothing to add, it is refused",
		refusal(clip, { { type = "add_noise", joints = { "Head" }, time_from = 0, time_to = 1 } }) ~= nil
	)
end)

finish()
