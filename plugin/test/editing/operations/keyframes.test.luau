--!strict
-- Keyframes themselves and the clip: adding, removing, moving, duplicating, shifting and scaling, settings and markers.
-- Run with: lune run plugin/test/editing/operations/keyframes.test.luau

local Kit = require("./kit")

local blank = Kit.blank
local Enum = Kit.Enum
local near = Kit.near
local Operations = Kit.Operations
local pose = Kit.pose
local refusal = Kit.refusal
local refused = Kit.refused
local rich = Kit.rich
local run = Kit.run
local times = Kit.times
local yaw = Kit.yaw

local check, case, finish = Kit.suite("operation keyframes")
case("keyframes are added, removed, moved and duplicated", function()
	local sequence = rich()
	run(sequence, { { type = "add_keyframe", time = 0.5 } })
	check("added", times(sequence) == "0.000 0.500 1.000 2.000", times(sequence))
	refused("adding where one is", sequence, { { type = "add_keyframe", time = 1.0005 } }, "already a keyframe")

	local changed = run(sequence, { { type = "duplicate_keyframe", time = 1, to = 3 } })
	local copy = Operations.findKeyframe(sequence, 3) :: any
	check(
		"a duplicate is a new keyframe",
		changed.keyframes_created == 1 and times(sequence) == "0.000 0.500 1.000 2.000 3.000"
	)
	check("with the poses of the original", near(yaw(pose(sequence, "Head", 3).CFrame), 20))
	check("and its markers", copy:FindFirstChild("Step") ~= nil and copy:FindFirstChild("Step").Value == "left")
	check("as separate instances", pose(sequence, "Head", 3) ~= pose(sequence, "Head", 1))
	refused(
		"duplicating onto another",
		sequence,
		{ { type = "duplicate_keyframe", time = 1, to = 2 } },
		"already a keyframe"
	)
	refused(
		"duplicating what is not there",
		sequence,
		{ { type = "duplicate_keyframe", time = 7, to = 8 } },
		"no keyframe at 7"
	)

	local moving = Operations.findKeyframe(sequence, 3)
	run(sequence, { { type = "move_keyframe", time = 3, to = 2.5 } })
	check(
		"moved",
		Operations.findKeyframe(sequence, 2.5) == moving and times(sequence) == "0.000 0.500 1.000 2.000 2.500"
	)
	refused("moving onto another", sequence, { { type = "move_keyframe", time = 2.5, to = 2 } }, "already a keyframe")
	check(
		"moving onto itself is allowed",
		refusal(sequence, { { type = "move_keyframe", time = 2.5, to = 2.5004 } }) == nil
	)

	changed = run(sequence, { { type = "remove_keyframe", time = 0.5 }, { type = "remove_keyframe", time = 2.5 } })
	check("removed", changed.keyframes_removed == 2 and times(sequence) == "0.000 1.000 2.000", times(sequence))
	refused("removing what is not there", sequence, { { type = "remove_keyframe", time = 0.5 } }, "no keyframe at 0.5")
end)

case("a range of keyframes is shifted", function()
	local sequence = rich()
	local changed = run(sequence, { { type = "shift_time", time_from = 1, time_to = 2, offset = 0.5 } })
	check(
		"the range moved together",
		changed.keyframes_moved == 2 and times(sequence) == "0.000 1.500 2.500",
		times(sequence)
	)
	run(sequence, { { type = "shift_time", time_from = 1.5, time_to = 2.5, offset = -0.5 } })
	check("and back", times(sequence) == "0.000 1.000 2.000", times(sequence))
	refused(
		"onto a keyframe outside the range",
		sequence,
		{ { type = "shift_time", time_from = 1, time_to = 1, offset = 1 } },
		"would land on the one at 2"
	)
	refused(
		"past a keyframe outside the range",
		sequence,
		{ { type = "shift_time", time_from = 1, time_to = 1, offset = 1.5 } },
		"would pass the one at 2"
	)
	refused(
		"before zero",
		sequence,
		{ { type = "shift_time", time_from = 0, time_to = 2, offset = -1 } },
		"outside 0 to"
	)
	refused(
		"past the limit",
		sequence,
		{ { type = "shift_time", time_from = 0, time_to = 2, offset = 299 } },
		"outside 0 to"
	)
	refused(
		"an empty range",
		sequence,
		{ { type = "shift_time", time_from = 5, time_to = 6, offset = 1 } },
		"no keyframes from 5 to 6"
	)
	check("refusals changed nothing", times(sequence) == "0.000 1.000 2.000", times(sequence))
end)

case("a range of keyframes is scaled", function()
	local sequence = rich()
	run(sequence, { { type = "scale_time", time_from = 0, time_to = 2, factor = 2 } })
	check("from the start of the range by default", times(sequence) == "0.000 2.000 4.000", times(sequence))
	run(sequence, { { type = "scale_time", time_from = 0, time_to = 4, factor = 0.5, anchor = 4 } })
	check("or about a chosen time", times(sequence) == "2.000 3.000 4.000", times(sequence))
	run(sequence, { { type = "add_keyframe", time = 5 }, { type = "add_keyframe", time = 2.05 } })
	refused(
		"past a keyframe outside the range",
		sequence,
		{ { type = "scale_time", time_from = 3, time_to = 4, factor = 4, anchor = 2 } },
		"would pass the one at 5"
	)
	refused(
		"onto a keyframe outside the range",
		sequence,
		{ { type = "scale_time", time_from = 3, time_to = 4, factor = 3, anchor = 2 } },
		"would land on the one at 5"
	)
	refused(
		"so small that keyframes meet",
		sequence,
		{ { type = "scale_time", time_from = 2, time_to = 2.05, factor = 0.01 } },
		"would land on each other"
	)
	check("refusals changed nothing", times(sequence) == "2.000 2.050 3.000 4.000 5.000", times(sequence))
end)

case("a scaled range can carry the rest of the clip along with ripple", function()
	local sequence = rich()
	run(sequence, { { type = "scale_time", time_from = 0, time_to = 1, factor = 2, ripple = true } })
	check(
		"the range grows and what follows moves on by as much",
		times(sequence) == "0.000 2.000 3.000",
		times(sequence)
	)
	run(sequence, { { type = "scale_time", time_from = 0, time_to = 2, factor = 0.5, ripple = true } })
	check("and back", times(sequence) == "0.000 1.000 2.000", times(sequence))
end)

case("the clip's own settings are changed", function()
	local sequence = blank()
	local changed = run(sequence, { { type = "set_properties", name = "Wave", loop = true, priority = "Movement" } })
	check("counted once", changed.properties_changed == 1)
	check(
		"all three are set",
		sequence.Name == "Wave" and sequence.Loop == true and sequence.Priority == Enum.AnimationPriority.Movement
	)
	run(sequence, { { type = "set_properties", loop = false } })
	check(
		"one alone leaves the others",
		sequence.Name == "Wave" and sequence.Loop == false and sequence.Priority == Enum.AnimationPriority.Movement
	)
end)

case("markers are set and removed", function()
	local sequence = rich()
	local changed = run(sequence, { { type = "set_marker", time = 1.5, name = "Clap" } })
	check(
		"a marker at a new time creates its keyframe",
		changed.keyframes_created == 1 and times(sequence) == "0.000 1.000 1.500 2.000"
	)
	local keyframe = Operations.findKeyframe(sequence, 1.5) :: any
	check("with an empty value by default", keyframe:FindFirstChild("Clap").Value == "")
	run(sequence, { { type = "set_marker", time = 1.5, name = "Clap", value = "loud" } })
	check(
		"setting it again updates it",
		#keyframe:GetChildren() == 1 and keyframe:FindFirstChild("Clap").Value == "loud"
	)
	run(sequence, { { type = "set_marker", time = 1.5, name = "Stomp", value = "" } })
	check("a second name is a second marker", #keyframe:GetChildren() == 2)
	changed = run(sequence, { { type = "remove_marker", time = 1.5, name = "Clap" } })
	check(
		"removed by name",
		changed.markers_removed == 1
			and keyframe:FindFirstChild("Clap") == nil
			and keyframe:FindFirstChild("Stomp") ~= nil
	)
	refused(
		"a marker that is not there",
		sequence,
		{ { type = "remove_marker", time = 1.5, name = "Clap" } },
		'no marker "Clap"'
	)
	check(
		"the marker made earlier is untouched",
		(Operations.findKeyframe(sequence, 1) :: any):FindFirstChild("Step").Value == "left"
	)
end)

finish()
