--!strict
-- Poses in keyframe clips: setting, removing, offsetting, easing, and holding the pose a clip already has.
-- Run with: lune run plugin/test/editing/operations/poses.test.luau

local Kit = require("./kit")

local blank = Kit.blank
local CFrame = Kit.CFrame
local Enum = Kit.Enum
local JOINTS = Kit.JOINTS
local near = Kit.near
local Operations = Kit.Operations
local pose = Kit.pose
local refusal = Kit.refusal
local refused = Kit.refused
local rich = Kit.rich
local run = Kit.run
local times = Kit.times
local yaw = Kit.yaw

local check, case, finish = Kit.suite("operation poses")
case("setting a pose creates what it needs and nothing more", function()
	local sequence = blank()
	local changed = run(sequence, { { type = "set_pose", joint = "Head", time = 1, rotation = { 0, 30, 0 } } })
	check("one keyframe and one pose are counted", changed.keyframes_created == 1 and changed.poses_created == 1)
	local head = pose(sequence, "Head", 1)
	check("the pose turns the head", head and near(yaw(head.CFrame), 30) and head.Weight == 1)
	local ancestors = {}
	local above = head.Parent
	while above:IsA("Pose") do
		table.insert(ancestors, 1, `{above.Name}:{above.Weight}`)
		above = above.Parent
	end
	check(
		"it is nested under weightless poses for the parts above it",
		table.concat(ancestors, " ") == "HumanoidRootPart:0 LowerTorso:0 UpperTorso:0",
		table.concat(ancestors, " ")
	)

	changed = run(sequence, { { type = "set_pose", joint = "Head", time = 1.0004, position = { 0, 2, 0 } } })
	check("a time within a millisecond is the same keyframe", times(sequence) == "1.000" and changed.poses_changed == 1)
	check("a position alone keeps the rotation", near(yaw(head.CFrame), 30) and near(head.CFrame.Position.Y, 2))
	run(sequence, { { type = "set_pose", joint = "Head", time = 1, rotation = { 0, -15, 0 } } })
	check("a rotation alone keeps the position", near(yaw(head.CFrame), -15) and near(head.CFrame.Position.Y, 2))
	run(sequence, { { type = "set_pose", joint = "Head", time = 1, rotation = { 0, 10, 0 }, relative = true } })
	check("a relative pose is applied on top", near(yaw(head.CFrame), -5), yaw(head.CFrame))

	changed = run(sequence, {
		{
			type = "set_pose",
			joint = "UpperTorso",
			time = 1,
			rotation = { 5, 0, 0 },
			easing_style = "Bounce",
			easing_direction = "Out",
		},
	})
	local torso = pose(sequence, "UpperTorso", 1)
	check("a placeholder that gets a pose counts as created", changed.poses_created == 1 and torso.Weight == 1)
	check("and still holds the pose under it", torso:FindFirstChild("Head") == head)
	check(
		"easing can be set with the pose",
		torso.EasingStyle == Enum.PoseEasingStyle.Bounce and torso.EasingDirection == Enum.PoseEasingDirection.Out
	)
end)

case("removing a pose keeps what hangs from it", function()
	local sequence = blank()
	run(sequence, {
		{ type = "set_pose", joint = "UpperTorso", time = 0, rotation = { 5, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 30, 0 } },
		{ type = "set_pose", joint = "LeftHand", time = 0, rotation = { 0, 0, 10 } },
	})
	local keyframe = Operations.findKeyframe(sequence, 0) :: any
	local changed = run(sequence, { { type = "remove_pose", joint = "UpperTorso", time = 0 } })
	local torso = keyframe:FindFirstChild("UpperTorso", true)
	check("a pose with poses under it becomes a placeholder", changed.poses_removed == 1 and torso.Weight == 0)
	check("which no longer turns its joint", near(select(1, torso.CFrame:ToEulerAnglesXYZ()), 0))
	check("the pose under it is untouched", near(yaw(pose(sequence, "Head", 0).CFrame), 30))

	run(sequence, { { type = "remove_pose", joint = "LeftHand", time = 0 } })
	check("a pose at the end of a chain is removed", keyframe:FindFirstChild("LeftHand", true) == nil)
	check("with the placeholders that only held it", keyframe:FindFirstChild("LeftUpperArm", true) == nil)
	check("but not ones that hold something else", keyframe:FindFirstChild("UpperTorso", true) ~= nil)

	run(sequence, { { type = "remove_pose", joint = "Head", time = 0 } })
	check("removing the last pose empties the keyframe", #keyframe:GetChildren() == 0)
	check("and leaves the keyframe itself", times(sequence) == "0.000")
	refused("a pose that is not there", sequence, { { type = "remove_pose", joint = "Head", time = 0 } }, "has no pose")
	refused(
		"a keyframe that is not there",
		sequence,
		{ { type = "remove_pose", joint = "Head", time = 9 } },
		"no keyframe at 9"
	)
end)

case("an offset applies to every pose of the joint in the range", function()
	local sequence = rich()
	local changed = run(sequence, {
		{
			type = "offset_pose",
			joint = "Head",
			time_from = 1,
			time_to = 2,
			rotation = { 0, 5, 0 },
			position = { 0, 1, 0 },
		},
	})
	check("two poses changed", changed.poses_changed == 2, changed.poses_changed)
	check("outside the range is untouched", near(yaw(pose(sequence, "Head", 0).CFrame), 10))
	check(
		"inside is turned further",
		near(yaw(pose(sequence, "Head", 1).CFrame), 25) and near(yaw(pose(sequence, "Head", 2).CFrame), 35)
	)
	refused(
		"a range with no pose of that joint",
		sequence,
		{ { type = "offset_pose", joint = "RightFoot", time_from = 0, time_to = 2, rotation = { 0, 5, 0 } } },
		"has no pose from 0 to 2"
	)
end)

case("easing is set per pose, and the deprecated style is left where it is", function()
	local sequence = rich()
	run(sequence, {
		{
			type = "set_easing",
			joint = "Head",
			time_from = 0,
			time_to = 1,
			easing_style = "Elastic",
			easing_direction = "InOut",
		},
	})
	check(
		"poses in the range take the easing",
		pose(sequence, "Head", 0).EasingStyle == Enum.PoseEasingStyle.Elastic
			and pose(sequence, "Head", 1).EasingDirection == Enum.PoseEasingDirection.InOut
	)
	check("a pose outside does not", pose(sequence, "Head", 2).EasingStyle == Enum.PoseEasingStyle.Linear)
	check(
		"a pose with the deprecated style keeps it",
		pose(sequence, "LeftUpperArm", 0).EasingStyle == Enum.PoseEasingStyle.Cubic
	)
	run(sequence, { { type = "set_pose", joint = "LeftUpperArm", time = 0, rotation = { 0, 0, -50 } } })
	check(
		"even when the pose itself is edited",
		pose(sequence, "LeftUpperArm", 0).EasingStyle == Enum.PoseEasingStyle.Cubic
	)
	run(sequence, { { type = "set_easing", joint = "Head", time_from = 2, time_to = 2, easing_direction = "Out" } })
	check(
		"a direction alone leaves the style",
		pose(sequence, "Head", 2).EasingStyle == Enum.PoseEasingStyle.Linear
			and pose(sequence, "Head", 2).EasingDirection == Enum.PoseEasingDirection.Out
	)
end)

case("a keyframe can hold the pose the clip already has", function()
	local sequence = blank()
	run(sequence, {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 40, 0 } },
		{
			type = "set_pose",
			joint = "LeftHand",
			time = 0,
			rotation = { 0, 0, 0 },
			easing_style = "Bounce",
			easing_direction = "Out",
		},
		{ type = "set_pose", joint = "LeftHand", time = 1, rotation = { 0, 0, 60 } },
	})
	check("the joints a clip moves are found", table.concat(Operations.animated(sequence), " ") == "Head LeftHand")

	-- The engine supplies the poses; here they are given, as it would give them.
	local operations = { { type = "add_keyframe", time = 0.25 }, { type = "add_keyframe", time = 0.5, hold = true } }
	check("the places of such keyframes in a batch", table.concat(Operations.holds(operations), " ") == "2")
	Operations.check(operations, JOINTS)
	local holds = {}
	local changed = Operations.run(sequence, operations, {
		joints = JOINTS,
		held = { [2] = { Head = CFrame.Angles(0, math.rad(20), 0), LeftHand = CFrame.Angles(0, 0, math.rad(45)) } },
		holds = holds,
	})
	check(
		"a keyframe and a pose for each joint",
		changed.keyframes_created == 2 and changed.poses_created == 2,
		changed.poses_created
	)
	local head, hand = pose(sequence, "Head", 0.5), pose(sequence, "LeftHand", 0.5)
	check("each holds the pose it was given", near(yaw(head.CFrame), 20) and head.Weight == 1 and hand.Weight == 1)
	check(
		"each takes the easing of the pose before it",
		head.EasingStyle == Enum.PoseEasingStyle.Linear
			and hand.EasingStyle == Enum.PoseEasingStyle.Bounce
			and hand.EasingDirection == Enum.PoseEasingDirection.Out
	)
	check(
		"the plain keyframe added beside it is empty",
		#(Operations.findKeyframe(sequence, 0.25) :: any):GetChildren() == 0
	)
	check(
		"what is reported: the time and how many joints",
		#holds == 1 and holds[1].time == 0.5 and holds[1].joints == 2
	)
	check(
		"and the joints whose motion is no longer the same",
		holds[1].motion_changed and table.concat(holds[1].motion_changed, " ") == "LeftHand",
		holds[1].motion_changed and table.concat(holds[1].motion_changed, " ")
	)

	local straight = {}
	Operations.run(sequence, { { type = "add_keyframe", time = 0.75, hold = true } }, {
		joints = JOINTS,
		held = { [1] = { Head = CFrame.Angles(0, math.rad(30), 0) } },
		holds = straight,
	})
	check(
		"nothing is flagged when the easing is straight",
		straight[1].motion_changed == nil and straight[1].joints == 1
	)
	check("a joint not given a pose gets none", pose(sequence, "LeftHand", 0.75) == nil)

	-- A joint is keyed only between two of its own poses.
	run(sequence, { { type = "set_pose", joint = "RightFoot", time = 0.6, rotation = { 10, 0, 0 } } })
	local outside = {}
	Operations.run(
		sequence,
		{ { type = "add_keyframe", time = 0.4, hold = true }, { type = "add_keyframe", time = 0.9, hold = true } },
		{
			joints = JOINTS,
			held = {
				[1] = { Head = CFrame.Angles(0, math.rad(16), 0), RightFoot = CFrame.new() },
				[2] = { Head = CFrame.Angles(0, math.rad(36), 0), RightFoot = CFrame.Angles(math.rad(10), 0, 0) },
			},
			holds = outside,
		}
	)
	check("not before its first pose", pose(sequence, "RightFoot", 0.4) == nil and outside[1].joints == 1)
	check("nor after its last", pose(sequence, "RightFoot", 0.9) == nil and outside[2].joints == 1)
	check(
		"while a joint that is between two of its poses is",
		pose(sequence, "Head", 0.4) ~= nil and pose(sequence, "Head", 0.9) ~= nil
	)

	local missing = refusal(sequence, { { type = "add_keyframe", time = 0.95, hold = true } }) :: any
	check(
		"without poses from the engine it is refused",
		missing.code == "PREVIEW_UNAVAILABLE" and Operations.findKeyframe(sequence, 0.95) == nil,
		missing.code
	)
	refused(
		"onto an existing keyframe",
		sequence,
		{ { type = "add_keyframe", time = 0.5, hold = true } },
		"already a keyframe"
	)
	refused(
		"hold must be a boolean",
		sequence,
		{ { type = "add_keyframe", time = 0.95, hold = "yes" } },
		"hold must be true or false"
	)
	local many = {}
	for index = 1, Operations.MAX_HOLDS + 1 do
		many[index] = { type = "add_keyframe", time = 2 + index, hold = true }
	end
	check("a batch has a limit on them", (refusal(sequence, many) :: any).code == "LIMIT_EXCEEDED")
end)

finish()
