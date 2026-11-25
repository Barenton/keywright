--!strict
-- Mirroring a clip or copying one side onto the other, and copying a pose to another time.
-- Run with: lune run plugin/test/editing/curves/mirror.test.luau

local Kit = require("./kit")

local blank = Kit.blank
local BlockRig = Kit.BlockRig
local Curves = Kit.Curves
local difference = Kit.difference
local inMirror = Kit.inMirror
local keysOf = Kit.keysOf
local lopsided = Kit.lopsided
local mirrorName = Kit.mirrorName
local placedAt = Kit.placedAt
local REAL = Kit.REAL
local realRun = Kit.realRun
local refusal = Kit.refusal
local Rig = Kit.Rig
local roblox = Kit.roblox
local sampleAll = Kit.sampleAll
local turnBetween = Kit.turnBetween

local check, case, finish = Kit.suite("mirror")
case("mirror flip turns the whole clip into its mirror image", function()
	local clip = lopsided()
	local times = { 0, 0.1, 0.25, 0.5, 0.73, 1 }
	local before = {}
	for _, time in times do
		before[time] = placedAt(clip, time)
	end
	local changed = realRun(clip, { { type = "mirror", mode = "flip" } })
	check("every joint was mirrored", changed.joints_mirrored == 15, changed.joints_mirrored)
	local studs, degrees = 0, 0
	for _, time in times do
		local after = placedAt(clip, time)
		for name, cframe in before[time] do
			local wanted = inMirror(cframe)
			local got = after[mirrorName(name)]
			studs = math.max(studs, (got.Position - wanted.Position).Magnitude)
			degrees = math.max(degrees, turnBetween(got, wanted))
		end
	end
	check("every part is where its mirror image was", studs < 1e-4, studs)
	check("turned as its mirror image was", degrees < 0.01, degrees)
	local keysBefore = #keysOf(lopsided(), "LeftUpperArm", "rotation.y")
	check("with the keys it had, not one a frame", #keysOf(clip, "RightUpperArm", "rotation.y") == keysBefore)
	realRun(clip, { { type = "mirror", mode = "flip" } })
	local back = 0
	for _, time in times do
		local after = placedAt(clip, time)
		for name, cframe in before[time] do
			back = math.max(back, (after[name].Position - cframe.Position).Magnitude)
		end
	end
	check("flipping twice gives the clip back", back < 1e-6, back)
end)

case("mirror copies one side onto the other, leaving the middle", function()
	local clip = lopsided()
	local middleBefore = placedAt(clip, 0.5).Head
	realRun(clip, { { type = "mirror", mode = "left_to_right" } })
	local function at(joint: string, channel: string, time: number): number
		return Curves.evaluate(keysOf(clip, joint, channel), time)
	end
	local worst = 0
	for _, time in { 0.1, 0.3, 0.5, 0.8 } do
		for _, joint in { "UpperArm", "LowerArm" } do
			worst = math.max(
				worst,
				math.abs(at(`Right{joint}`, "rotation.x", time) - at(`Left{joint}`, "rotation.x", time)),
				math.abs(at(`Right{joint}`, "rotation.y", time) + at(`Left{joint}`, "rotation.y", time)),
				math.abs(at(`Right{joint}`, "rotation.z", time) + at(`Left{joint}`, "rotation.z", time))
			)
		end
	end
	check("the right arm moves as the left arm's mirror image", worst < 1e-9, worst)
	check(
		"the right leg, copied from a left leg that does not move, no longer moves",
		math.abs(at("RightUpperLeg", "rotation.x", 0.5)) < 1e-9
	)
	check("the middle is as it was", (placedAt(clip, 0.5).Head.Position - middleBefore.Position).Magnitude < 1e-9)
end)

case("mirror with an offset has one side trail the other in a loop", function()
	local clip = blank()
	realRun(clip, {
		{ type = "set_key", joint = "LeftUpperLeg", time = 0, rotation = { 30, 5, 0 } },
		{ type = "set_key", joint = "LeftUpperLeg", time = 0.4, rotation = { -30, 0, -5 } },
		{ type = "set_key", joint = "LeftUpperLeg", time = 1.2, rotation = { 30, 5, 0 } },
		{ type = "set_properties", loop = true },
		{ type = "auto_tangents", time_from = 0, time_to = 1.2 },
	})
	realRun(clip, { { type = "mirror", mode = "left_to_right", offset = 0.6 } })
	local left = keysOf(clip, "LeftUpperLeg", "rotation.x")
	local right = keysOf(clip, "RightUpperLeg", "rotation.x")
	local leftY = keysOf(clip, "LeftUpperLeg", "rotation.y")
	local rightY = keysOf(clip, "RightUpperLeg", "rotation.y")
	local worst = 0
	for step = 0, 120 do
		local time = step / 100
		local earlier = (time - 0.6) % 1.2
		worst = math.max(
			worst,
			math.abs(Curves.evaluate(right, time) - Curves.evaluate(left, earlier)),
			math.abs(Curves.evaluate(rightY, time) + Curves.evaluate(leftY, earlier))
		)
	end
	check("the right leg does at each moment what the left did half a cycle before", worst < 1e-4, worst)
	check("the clip is as long as it was", math.abs(Curves.duration(clip) - 1.2) < 1e-9, Curves.duration(clip))
end)

case("mirrors that cannot be done are refused", function()
	local clip = lopsided()
	local function refused(operation: any, joints: any?): any
		local ok, problem = pcall(function()
			Curves.check({ operation }, joints or REAL)
			Curves.run(clip, { operation }, { joints = joints or REAL })
		end)
		return if ok then nil else problem
	end
	check("an unknown mode", refused({ type = "mirror", mode = "sideways" }) ~= nil)
	check("an offset with flip", refused({ type = "mirror", mode = "flip", offset = 0.5 }) ~= nil)
	local once = refused({ type = "mirror", mode = "left_to_right", offset = 0.5 })
	check(
		"an offset in a clip that does not loop",
		once and string.find(once.message, "looping", 1, true),
		once and once.message
	)
	local model = BlockRig.build()
	model.LeftUpperArm.LeftShoulder.C0 = roblox.CFrame.new(-1.2, 0.5, 0)
	local crooked = refused({ type = "mirror", mode = "flip" }, Rig.scan(model).joints)
	check(
		"a rig whose sides differ",
		crooked and string.find(crooked.message, "mirror images", 1, true),
		crooked and crooked.message
	)
end)

case("copy_pose copies a pose to another time, as it is or mirrored", function()
	local clip = lopsided()
	realRun(clip, { { type = "copy_pose", from = 0, to = 1 } })
	check(
		"copied to the end, the clip ends in the pose it began with",
		difference(sampleAll(clip, 1), sampleAll(clip, 0)) < 1e-9,
		difference(sampleAll(clip, 1), sampleAll(clip, 0))
	)

	local mirrored = lopsided()
	local before = placedAt(mirrored, 0.5)
	realRun(mirrored, { { type = "copy_pose", from = 0.5, to = 0.75, mirror = true } })
	local after = placedAt(mirrored, 0.75)
	local studs, degrees = 0, 0
	for name, cframe in before do
		local wanted = inMirror(cframe)
		studs = math.max(studs, (after[mirrorName(name)].Position - wanted.Position).Magnitude)
		degrees = math.max(degrees, turnBetween(after[mirrorName(name)], wanted))
	end
	check("mirrored, every part is where its mirror image was", studs < 1e-4, studs)
	check("turned as its mirror image was", degrees < 0.01, degrees)

	local some = lopsided()
	local headBefore = #keysOf(some, "UpperTorso", "rotation.x")
	realRun(some, { { type = "copy_pose", from = 0.5, to = 0.25, joints = { "LeftUpperArm" } } })
	check(
		"only the joints named get a key",
		#keysOf(some, "UpperTorso", "rotation.x") == headBefore and #keysOf(some, "LeftUpperArm", "rotation.x") == 4
	)
	check(
		"with the pose from the other time",
		math.abs(
			Curves.evaluate(keysOf(some, "LeftUpperArm", "rotation.z"), 0.25)
				- Curves.evaluate(keysOf(lopsided(), "LeftUpperArm", "rotation.z"), 0.5)
		) < 1e-9
	)
	check(
		"a clip with no keys has no pose to copy",
		refusal(blank(), { { type = "copy_pose", from = 0, to = 1 } }) ~= nil
	)
end)

finish()
