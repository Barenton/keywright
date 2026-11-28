--!strict
-- Curve clips' layout, keys, tangents, settings and markers, reading, fingerprints, conversion from keyframes and the general checks.
-- Run with: lune run plugin/test/editing/curves/basics.test.luau

local Kit = require("./kit")

local blank = Kit.blank
local Curves = Kit.Curves
local CurveStore = Kit.CurveStore
local Digest = Kit.Digest
local Enum = Kit.Enum
local JOINTS = Kit.JOINTS
local keyframed = Kit.keyframed
local keysOf = Kit.keysOf
local near = Kit.near
local Operations = Kit.Operations
local Reading = Kit.Reading
local refusal = Kit.refusal
local run = Kit.run
local Validate = Kit.Validate

local check, case, finish = Kit.suite("basics")
case("a key is laid out as the Animation Editor lays it out", function()
	local clip = blank()
	local changed = run(clip, { { type = "set_key", joint = "RightUpperArm", time = 0.5, rotation = { 30, 0, -10 } } })
	local folder = clip:FindFirstChild("HumanoidRootPart")
	check("folders nested from the root part", folder and folder:FindFirstChild("LowerTorso"))
	local arm = Curves.folder(clip, "RightUpperArm", false)
	check(
		"down to the joint's own folder",
		arm and arm.Parent.Name == "UpperTorso" and arm.Parent.Parent.Name == "LowerTorso"
	)
	local rotation = arm:FindFirstChild("Rotation")
	check("an EulerRotationCurve named Rotation", rotation and rotation.ClassName == "EulerRotationCurve")
	check("in X, Y, Z order", rotation.RotationOrder == Enum.RotationOrder.XYZ)
	check(
		"with a FloatCurve for each axis",
		rotation:FindFirstChild("X") and rotation:FindFirstChild("Y") and rotation:FindFirstChild("Z")
	)
	check("and no position curve, since none was given", arm:FindFirstChild("Position") == nil)
	local x = keysOf(clip, "RightUpperArm", "rotation.x")
	check("rotation is kept in radians", #x == 2 and near(x[2].value, math.rad(30)) and near(x[2].time, 0.5))
	-- The channel was at rest the whole clip; a key at rest at the start keeps it so before 0.5.
	check("a channel's first key, later on, comes with one at rest at the start", x[1].time == 0 and x[1].value == 0)
	check("a new key is cubic with flat tangents", x[2].interpolation == "Cubic" and x[2].left == 0 and x[2].right == 0)
	check("so early on the joint is still at rest", Curves.evaluate(x, 0.1) < math.rad(5))
	check("six keys made", changed.keys_created == 6, changed.keys_created)

	changed = run(clip, { { type = "set_key", joint = "RightUpperArm", time = 0.5004, rotation = { 45, 0, 0 } } })
	check(
		"a time within a millisecond changes the key there",
		changed.keys_changed == 3 and #keysOf(clip, "RightUpperArm", "rotation.x") == 2
	)
	run(
		clip,
		{ { type = "set_key", joint = "RightUpperArm", time = 0.2, position = { 0, 1, 0 }, interpolation = "Linear" } }
	)
	local y = keysOf(clip, "RightUpperArm", "position.y")
	check(
		"position goes in its own curves",
		#y == 2 and y[2].value == 1 and y[2].interpolation == "Linear" and y[2].right == nil
	)
	check("rotation curves are untouched by it", #keysOf(clip, "RightUpperArm", "rotation.x") == 2)
end)

case("the track list finds every channel with its joint", function()
	local clip = blank()
	run(clip, {
		{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 10, 0 } },
		{ type = "set_key", joint = "LeftFoot", time = 0, position = { 0, 0.5, 0 } },
	})
	local seen = {}
	for _, track in Curves.tracks(clip) do
		table.insert(seen, `{track.joint}:{track.channel}`)
	end
	check(
		"three of each, sorted by path",
		table.concat(seen, " ")
			== "LeftFoot:position.x LeftFoot:position.y LeftFoot:position.z Head:rotation.x Head:rotation.y Head:rotation.z",
		table.concat(seen, " ")
	)
end)

case("a curve is played as Studio plays it", function()
	local keys = {
		{ time = 0, value = 0, interpolation = "Cubic", left = 0, right = 2 },
		{ time = 1, value = 1, interpolation = "Linear", left = 0 },
		{ time = 2, value = 3, interpolation = "Constant", left = 0 },
		{ time = 3, value = 5, interpolation = "Cubic", left = 0 },
	}
	check("before the first key, its value", Curves.evaluate(keys, -1) == 0)
	-- Hermite with an outgoing tangent of 2 and an incoming one of 0, half way.
	check("a cubic stretch follows its tangents", near(Curves.evaluate(keys, 0.5), 0.75), Curves.evaluate(keys, 0.5))
	check("a linear stretch is straight", near(Curves.evaluate(keys, 1.5), 2))
	check("a constant stretch holds", Curves.evaluate(keys, 2.9) == 3)
	check("after the last key, its value", Curves.evaluate(keys, 9) == 5)
	check("no keys means rest", Curves.evaluate({}, 1) == 0)
end)

case("tangents are set by hand in degrees per second, or worked out", function()
	local clip = blank()
	run(clip, {
		{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "Head", time = 0.5, rotation = { 0, 40, 0 } },
		{ type = "set_key", joint = "Head", time = 1, rotation = { 0, 90, 0 } },
	})
	run(clip, { { type = "set_tangent", joint = "Head", time = 0.5, channel = "rotation.y", ["in"] = 90, out = 180 } })
	local y = keysOf(clip, "Head", "rotation.y")
	check("stored in radians per second", near(y[2].left, math.rad(90)) and near(y[2].right, math.rad(180)))
	local problem =
		refusal(clip, { { type = "set_tangent", joint = "Head", time = 1, channel = "rotation.y", out = 10 } })
	check("the last key has no outgoing tangent", problem and string.find(problem.message, "last key", 1, true))

	local changed = run(clip, { { type = "auto_tangents", time_from = 0, time_to = 1 } })
	y = keysOf(clip, "Head", "rotation.y")
	check("the middle key is passed at speed", y[2].left > 1 and near(y[2].left, y[2].right), y[2].left)
	check("the ends are come to rest at", y[1].right == 0 and y[3].left == 0)
	check("keys in the range become cubic", y[1].interpolation == "Cubic" and y[2].interpolation == "Cubic")
	-- Three channels of three keys each; the two that do not move are smoothed too, flat.
	check("every key of every channel in the range", changed.keys_changed == 9, changed.keys_changed)
	-- Played through: the head turns on past 40 degrees without stopping there.
	local before, at, after = Curves.evaluate(y, 0.45), Curves.evaluate(y, 0.5), Curves.evaluate(y, 0.55)
	check("and keeps turning through it", at - before > 0.02 and after - at > 0.02)

	run(clip, { { type = "auto_tangents", time_from = 0, time_to = 1, snap_at = { 0.5 } } })
	y = keysOf(clip, "Head", "rotation.y")
	check("a snap arrives fast and leaves from rest", y[2].left > 2 and y[2].right == 0, y[2].left)
	local narrow = refusal(blank(), { { type = "auto_tangents", time_from = 0, time_to = 1 } })
	check("a range with nothing to smooth is refused", narrow and narrow.code == "INVALID_ARGUMENT")
end)

case("keys are removed by time, from the channels named", function()
	local clip = blank()
	run(clip, {
		{ type = "set_key", joint = "Head", time = 0.5, rotation = { 0, 40, 0 }, position = { 0, 1, 0 } },
		{ type = "set_key", joint = "Head", time = 1, rotation = { 0, 90, 0 } },
	})
	local changed = run(clip, { { type = "remove_key", joint = "Head", time = 0.5, channels = { "position" } } })
	-- Each channel also has the key at rest at 0 that its first key brought.
	check("only position keys went", changed.keys_removed == 3 and #keysOf(clip, "Head", "position.y") == 1)
	check("rotation keys stayed", #keysOf(clip, "Head", "rotation.y") == 3)
	run(clip, { { type = "remove_key", joint = "Head", time = 0.5 } })
	check("then the rest", #keysOf(clip, "Head", "rotation.y") == 2)
	local problem = refusal(clip, { { type = "remove_key", joint = "Head", time = 0.5 } })
	check("a key that is not there", problem and string.find(problem.message, "no key at 0.5", 1, true))
end)

case("settings, markers and restoring work as for keyframe clips", function()
	local source = blank()
	run(source, { { type = "set_key", joint = "Head", time = 1, rotation = { 0, 30, 0 } } })
	local clip = source:Clone()
	run(clip, {
		{ type = "set_properties", name = "Wave", loop = true, priority = "Movement" },
		{ type = "set_marker", time = 0.4, name = "Hit", value = "left" },
		{ type = "set_marker", time = 0.4, name = "Hit", value = "right" },
		{ type = "set_marker", time = 0.8, name = "Hit" },
	})
	check("settings", clip.Name == "Wave" and clip.Loop == true and clip.Priority == Enum.AnimationPriority.Movement)
	local hit = clip:FindFirstChild("Hit")
	check("one marker curve per name, at the top", hit and hit.ClassName == "MarkerCurve")
	local markers = CurveStore.backend.markers(hit)
	check("setting one at the same time changes it", #markers == 2 and markers[1].value == "right")
	run(
		clip,
		{ { type = "remove_marker", time = 0.4, name = "Hit" }, { type = "remove_marker", time = 0.8, name = "Hit" } }
	)
	check("removing the last marker removes its curve", clip:FindFirstChild("Hit") == nil)
	run(clip, { { type = "set_key", joint = "Head", time = 2, rotation = { 0, 99, 0 } } })
	run(clip, { { type = "restore_source" } }, source)
	check("restored to the source's content and settings", Digest.of(clip) == Digest.of(source) and clip.Loop == false)
end)

case("operations for keyframe clips are refused on curve clips, and the other way", function()
	local problem = refusal(blank(), { { type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } } })
	check("set_pose names the operations that do apply", problem and string.find(problem.hint, "set_key", 1, true))
	local ok, keyframeProblem =
		pcall(Operations.check, { { type = "set_key", joint = "Head", time = 0, rotation = { 0, 0, 0 } } }, JOINTS)
	check("and set_key is refused on a keyframe clip", not ok and (keyframeProblem :: any).code == "INVALID_ARGUMENT")
	for name, operation in
		{
			["a rotation of two numbers"] = { type = "set_key", joint = "Head", time = 0, rotation = { 0, 0 } },
			["a key with nothing to set"] = { type = "set_key", joint = "Head", time = 0 },
			["a joint the rig lacks"] = { type = "set_key", joint = "Tail", time = 0, rotation = { 0, 0, 0 } },
			["an interpolation that does not exist"] = {
				type = "set_key",
				joint = "Head",
				time = 0,
				rotation = { 0, 0, 0 },
				interpolation = "Bounce",
			},
			["a channel that does not exist"] = {
				type = "set_tangent",
				joint = "Head",
				time = 0,
				channel = "rotation.w",
				out = 1,
			},
			["a tangent with nothing to set"] = {
				type = "set_tangent",
				joint = "Head",
				time = 0,
				channel = "rotation.x",
			},
			["a position past the limit"] = { type = "set_key", joint = "Head", time = 0, position = { 0, 2000, 0 } },
		} :: { [string]: any }
	do
		local refused = refusal(blank(), { operation })
		check(name, refused and refused.code == "INVALID_ARGUMENT", refused)
	end
end)

case("a keyframe clip becomes a curve clip through its poses", function()
	local sequence = keyframed()
	local clip = Curves.fromKeyframes(sequence, Operations.keyframes(sequence), Operations.findPose)
	check(
		"a CurveAnimation with the same name and settings",
		clip.ClassName == "CurveAnimation" and clip.Name == "Turn"
	)
	local y = keysOf(clip, "Head", "rotation.y")
	check("a key at every pose", #y == 3 and near(y[2].time, 0.5))
	check("each the pose's angle", near(math.deg(y[2].value), 170, 1e-3))
	-- From 170 to -170 is 20 degrees onward, not 340 back.
	check("angles are taken the short way round", near(math.deg(y[3].value), 190, 1e-3), math.deg(y[3].value))
	check(
		"channels that never move get no keys",
		#keysOf(clip, "Head", "rotation.z") == 0 and #keysOf(clip, "Head", "position.x") == 0
	)
	check("a channel that moves does", #keysOf(clip, "Head", "position.y") == 3)
	check("joints that are not posed get nothing", Curves.folder(clip, "LeftFoot", false) == nil)
	check("tangents are worked out", y[2].left > 0)
	local look = clip:FindFirstChild("Look")
	check("markers come along", look and CurveStore.backend.markers(look)[1].value == "left")
end)

case("reading a curve clip gives its keys in the outside's units", function()
	local clip = blank()
	run(clip, {
		{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "Head", time = 0.5, rotation = { 0, 40, 0 } },
		{ type = "set_key", joint = "Head", time = 1, rotation = { 0, 90, 0 } },
		{ type = "set_key", joint = "LeftFoot", time = 0.25, position = { 0, 0.5, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
		{ type = "set_marker", time = 0.5, name = "Hit" },
	})
	local summary = Reading.read(clip, {})
	check("says it is made of curves", summary.format == "curves")
	check(
		"its length and key times",
		summary.duration == 1 and table.concat(summary.keyframe_times, " ") == "0 0.25 0.5 1"
	)
	check("the joints that move", table.concat(summary.animated_joints, " ") == "Head LeftFoot")
	check("its markers", #summary.markers == 1 and summary.markers[1].name == "Hit")
	check("no keys unless asked", summary.keys == nil)
	local detail = Reading.read(clip, { joints = { "Head" } })
	local middle
	for _, key in detail.keys do
		if key.channel == "rotation.y" and key.time == 0.5 then
			middle = key
		end
	end
	check("a key in degrees", middle and near(middle.value, 40, 1e-3))
	check("with its tangents in degrees per second", middle["in"] > 50 and middle["in"] == middle.out, middle["in"])
	local page = Reading.read(clip, { joints = { "Head" }, limit = 4 })
	check("a page at a time", #page.keys == 4 and page.keys_total == 9 and page.next_offset == 4)
end)

case("a curve clip's fingerprint covers keys, tangents and markers", function()
	local clip = blank()
	run(clip, {
		{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "Head", time = 1, rotation = { 0, 30, 0 } },
	})
	local base = Digest.of(clip)
	check("a copy matches", Digest.of(clip:Clone()) == base)
	local tangent = clip:Clone()
	run(tangent, { { type = "set_tangent", joint = "Head", time = 0, channel = "rotation.y", out = 45 } })
	check("a tangent shows", Digest.of(tangent) ~= base)
	local marked = clip:Clone()
	run(marked, { { type = "set_marker", time = 0.5, name = "Hit" } })
	check("a marker shows", Digest.of(marked) ~= base)
	local renamed = clip:Clone()
	renamed.Name = "Other"
	check("the name does not", Digest.of(renamed) == base)
end)

case("a curve clip is checked", function()
	local function validate(clip: any): any
		return Validate.run(clip, { joints = JOINTS }, assert(Validate.thresholds({ speed_degrees_per_second = 400 })))
	end
	local sound = blank()
	run(sound, {
		{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "Head", time = 1, rotation = { 0, 60, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	local result = validate(sound)
	check("a sound clip has no findings", result.valid and result.errors == 0 and result.warnings == 0, result.warnings)

	local fast = blank()
	run(fast, {
		{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 0, 0 }, interpolation = "Linear" },
		{ type = "set_key", joint = "Head", time = 0.1, rotation = { 0, 80, 0 }, interpolation = "Linear" },
	})
	local abrupt = validate(fast)
	check("a joint turning too fast is a warning", abrupt.valid and abrupt.counts.ABRUPT_ROTATION == 1)
	local issue = abrupt.issues[1]
	check("with the speed measured", issue and near(issue.measured, 800, 20), issue and issue.measured)

	sound.Loop = true
	local loop = validate(sound)
	check(
		"a loop that does not close is a warning",
		loop.counts.LOOP_ROTATION_MISMATCH == 1 and near(loop.issues[1].measured, 60, 0.01)
	)

	local between = blank()
	run(between, {
		{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "Head", time = 0.22, rotation = { 0, 10, 0 } },
		{ type = "set_key", joint = "Head", time = 1 / 3, rotation = { 0, 20, 0 } },
	})
	local framed = validate(between)
	local off = framed.issues[1]
	check(
		"keys between frames are a warning, counted",
		framed.valid
			and framed.counts.KEY_OFF_FRAME == 1
			and off.measured == 3
			and string.find(off.message, "0.22", 1, true),
		off and off.message
	)
	check("keys on frames are not", validate(sound).counts.KEY_OFF_FRAME == nil)

	local stray = blank()
	run(stray, { { type = "set_key", joint = "Head", time = 0, rotation = { 0, 1, 0 } } })
	Curves.folder(stray, "Head", false).Name = "Tail"
	local unknown = validate(stray)
	check(
		"keys for a joint the rig lacks are an error",
		not unknown.valid and unknown.counts.UNKNOWN_JOINT == 3,
		unknown.counts.UNKNOWN_JOINT
	)
end)

case("a working copy converted from a keyframe clip is restored by converting again", function()
	local sequence = keyframed()
	local clip = Curves.fromKeyframes(sequence, Operations.keyframes(sequence), Operations.findPose)
	local converted = Digest.of(clip)
	run(clip, { { type = "set_key", joint = "Head", time = 2, rotation = { 0, 1, 0 } } })
	run(clip, { { type = "restore_source" } }, sequence)
	check("back to the conversion", Digest.of(clip) == converted)
	check("with no keyframes inside it", #clip:GetChildren() > 0 and clip:FindFirstChildOfClass("Keyframe") == nil)
end)

case("a curve clip's hips are checked for jumps in place, and a loop for where they end", function()
	local function validate(clip: any): any
		return Validate.run(clip, { joints = JOINTS }, assert(Validate.thresholds({})))
	end
	local jump = blank()
	run(jump, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0, 0 }, interpolation = "Linear" },
		{ type = "set_key", joint = "LowerTorso", time = 0.5, position = { 0, 0, 0 }, interpolation = "Linear" },
		{ type = "set_key", joint = "LowerTorso", time = 0.5333333, position = { 0, 2, 0 }, interpolation = "Linear" },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 2, 0 }, interpolation = "Linear" },
	})
	local abrupt = validate(jump)
	check("hips that jump 2 studs in a frame move too fast", abrupt.counts.ABRUPT_MOVE == 1, abrupt.counts)
	local issue
	for _, found in abrupt.issues do
		if found.code == "ABRUPT_MOVE" then
			issue = found
		end
	end
	check("with the speed measured", issue and near(issue.measured, 60, 1), issue and issue.measured)
	jump.Loop = true
	local loop = validate(jump)
	check(
		"a loop that ends with the hips elsewhere is a mismatch",
		loop.counts.LOOP_POSITION_MISMATCH == 1,
		loop.counts
	)
	local still = blank()
	run(still, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, -0.2, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, -0.2, 0 } },
	})
	still.Loop = true
	local fine = validate(still)
	check(
		"hips that end where they start are not",
		fine.counts.LOOP_POSITION_MISMATCH == nil and fine.counts.ABRUPT_MOVE == nil,
		fine.counts
	)
end)

finish()
