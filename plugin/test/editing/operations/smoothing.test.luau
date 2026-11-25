--!strict
-- smooth_motion: one smooth curve through each joint's keys.
-- Run with: lune run plugin/test/editing/operations/smoothing.test.luau

local Kit = require("./kit")

local blank = Kit.blank
local Enum = Kit.Enum
local near = Kit.near
local Operations = Kit.Operations
local pose = Kit.pose
local refusal = Kit.refusal
local refused = Kit.refused
local run = Kit.run
local Sequence = Kit.Sequence
local snapshot = Kit.snapshot
local sparse = Kit.sparse
local times = Kit.times
local yaw = Kit.yaw

local check, case, finish = Kit.suite("operation smoothing")
case("smoothing replaces a joint's keys by a curve through them", function()
	local sequence = sparse()
	local hand = pose(sequence, "LeftHand", 0.5)
	local handBefore = snapshot(sequence)[hand]
	local changed = run(sequence, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 10 } })
	check(
		"a keyframe at every step, and the one that holds a marker is kept",
		times(sequence) == "0.000 0.100 0.200 0.300 0.330 0.400 0.500 0.600 0.700 0.800 0.900 1.000",
		times(sequence)
	)
	check("the keys it was drawn through are gone", pose(sequence, "Head", 0.33) == nil)
	check("the marker is still there", (Operations.findKeyframe(sequence, 0.33) :: any):FindFirstChild("Hit") ~= nil)
	check(
		"what changed is counted",
		changed.poses_removed == 5 and changed.poses_created == 22 and changed.keyframes_created == 8,
		`{changed.poses_removed} {changed.poses_created} {changed.keyframes_created}`
	)

	local rising, last = true, -1
	for step = 0, 10 do
		local head = pose(sequence, "Head", step / 10)
		rising = rising and head ~= nil and head.Weight == 1 and yaw(head.CFrame) > last
		rising = rising and head.EasingStyle == Enum.PoseEasingStyle.Linear
		last = if head then yaw(head.CFrame) else last
	end
	check("the head turns steadily onwards through every step, by straight stretches", rising)
	check(
		"it starts and ends where it was keyed",
		near(yaw(pose(sequence, "Head", 0).CFrame), 0) and near(yaw(pose(sequence, "Head", 1).CFrame), 90)
	)
	check(
		"and passes its middle key on the way",
		yaw(pose(sequence, "Head", 0.3).CFrame) < 40 and yaw(pose(sequence, "Head", 0.4).CFrame) > 40,
		yaw(pose(sequence, "Head", 0.3).CFrame)
	)
	local chest = pose(sequence, "UpperTorso", 0.5)
	local pitch = math.deg((select(1, chest.CFrame:ToEulerAnglesXYZ())))
	check("a joint with two keys is eased between them", near(pitch, 5) and chest.Weight == 1, pitch)
	check("poses stay nested as the rig is", pose(sequence, "Head", 0.5).Parent == chest)
	check("a joint keyed once is left exactly as it was", snapshot(sequence)[hand] == handBefore and hand.Parent ~= nil)
end)

case("smoothing touches only the joints and the range it is given", function()
	local sequence = sparse()
	local chestStart, chestEnd = pose(sequence, "UpperTorso", 0), pose(sequence, "UpperTorso", 1)
	local before = snapshot(sequence)
	run(sequence, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 10, joints = { "Head" } } })
	local after = snapshot(sequence)
	check(
		"the other joint's keys are the same instances, unchanged",
		after[chestStart] == before[chestStart] and after[chestEnd] == before[chestEnd]
	)
	local between = pose(sequence, "UpperTorso", 0.5)
	check("and it gains no poses of its own, only placeholders", between ~= nil and between.Weight == 0)

	-- Keys off the steps: a pose at the first key, at each step between, and at the last.
	local offset = blank()
	run(offset, {
		{ type = "set_pose", joint = "RightFoot", time = 0.04, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "RightFoot", time = 0.96, rotation = { 30, 0, 0 } },
	})
	run(offset, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 10 } })
	check(
		"steps are counted from the start of the range",
		times(offset) == "0.040 0.100 0.200 0.300 0.400 0.500 0.600 0.700 0.800 0.900 0.960",
		times(offset)
	)

	local narrow = sparse()
	refused(
		"a range holding fewer than two keys of any joint",
		narrow,
		{ { type = "smooth_motion", time_from = 0.2, time_to = 0.8 } },
		"no joint has two or more poses"
	)
	check("which changes nothing", times(narrow) == "0.000 0.330 0.500 1.000", times(narrow))
end)

case("a snap arrives fast, and a loop carries on across its join", function()
	local function punch(): any
		local sequence = blank()
		run(sequence, {
			{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
			{ type = "set_pose", joint = "Head", time = 0.2, rotation = { 0, 80, 0 } },
			{ type = "set_pose", joint = "Head", time = 0.6, rotation = { 0, 60, 0 } },
		})
		return sequence
	end
	local eased, snapped = punch(), punch()
	run(eased, { { type = "smooth_motion", time_from = 0, time_to = 0.6, rate = 20 } })
	run(snapped, { { type = "smooth_motion", time_from = 0, time_to = 0.6, rate = 20, snap_at = { 0.2 } } })
	local easedYaw, snappedYaw = yaw(pose(eased, "Head", 0.15).CFrame), yaw(pose(snapped, "Head", 0.15).CFrame)
	check("a step before the key, the eased move is most of the way there", easedYaw > 60, easedYaw)
	check("and the snapped one still has ground to cover", snappedYaw < easedYaw - 8, snappedYaw)
	check(
		"both land on the key",
		near(yaw(pose(eased, "Head", 0.2).CFrame), 80) and near(yaw(pose(snapped, "Head", 0.2).CFrame), 80)
	)

	local function cycle(): any
		local sequence = blank()
		run(sequence, {
			{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 5, 0 } },
			{ type = "set_pose", joint = "Head", time = 0.25, rotation = { 0, 9, 0 } },
			{ type = "set_pose", joint = "Head", time = 0.75, rotation = { 0, 1, 0 } },
			{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 5, 0 } },
			{ type = "set_properties", loop = true },
		})
		return sequence
	end
	local looping, stopping = cycle(), cycle()
	run(looping, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 20 } })
	run(stopping, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 20, loop = false } })
	local moving = yaw(pose(looping, "Head", 0.05).CFrame) - 5
	local resting = yaw(pose(stopping, "Head", 0.05).CFrame) - 5
	check(
		"a looping clip is already moving at its first step",
		moving > resting * 2 and moving > 0.5,
		`{moving} {resting}`
	)
end)

case("a long turn is smoothed the short way round and stays a rotation", function()
	local sequence = blank()
	run(sequence, {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, -85, 0 }, position = { 0, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 85, 0 }, position = { 0, 2, 0 } },
	})
	run(sequence, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 10 } })
	local middle = pose(sequence, "Head", 0.5).CFrame
	check("half way through it faces half way", near(yaw(middle), 0), yaw(middle))
	check("and is half way there", near(middle.Position.Y, 1), middle.Position.Y)
	local sound = true
	for step = 0, 10 do
		local parts = { pose(sequence, "Head", step / 10).CFrame:GetComponents() }
		-- Each of a rotation's three directions has a length of one.
		for column = 0, 2 do
			local length = math.sqrt(parts[4 + column] ^ 2 + parts[7 + column] ^ 2 + parts[10 + column] ^ 2)
			sound = sound and math.abs(length - 1) < 1e-4
		end
	end
	check("every pose written is a true rotation", sound)
end)

case("smoothing is held to its limits", function()
	local sequence = sparse()
	local bad: { [string]: any } = {
		["a rate that is too low"] = { type = "smooth_motion", time_from = 0, time_to = 1, rate = 5 },
		["a rate that is not whole"] = { type = "smooth_motion", time_from = 0, time_to = 1, rate = 30.5 },
		["a joint the rig lacks"] = { type = "smooth_motion", time_from = 0, time_to = 1, joints = { "Tail" } },
		["an empty list of joints"] = { type = "smooth_motion", time_from = 0, time_to = 1, joints = {} },
		["a range of no length"] = { type = "smooth_motion", time_from = 0.5, time_to = 0.5 },
		["a loop that is not a boolean"] = { type = "smooth_motion", time_from = 0, time_to = 1, loop = "yes" },
		["a snap time out of range"] = { type = "smooth_motion", time_from = 0, time_to = 1, snap_at = { -1 } },
	}
	for name, operation in bad do
		local problem = refusal(sequence, { operation }) :: any
		check(name, type(problem) == "table" and problem.code == "INVALID_ARGUMENT", problem)
	end
	local limit = Sequence.MAX_KEYFRAMES
	Sequence.MAX_KEYFRAMES = 8
	local scratch = sequence:Clone()
	local over = refusal(scratch, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 30 } }) :: any
	Sequence.MAX_KEYFRAMES = limit
	check("more keyframes than a clip may hold", type(over) == "table" and over.code == "LIMIT_EXCEEDED", over)
	check("the clip itself was not touched", times(sequence) == "0.000 0.330 0.500 1.000", times(sequence))
end)

finish()
