--!strict
-- Offline tests for clips made of curves. Run with: lune run plugin/test/editing/curves.test.luau
--
-- Real here: Lune's instances, laid out as the Animation Editor lays out a curve clip,
-- and everything Keywright works out about them. In place of Studio: the keys of each
-- curve, which Lune cannot hold, are kept in an attribute, so that a clone carries them.
-- Not tested here: that Studio plays what is written, which was measured separately.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde")

local Roblox = require("../../src/Core/Roblox") :: any
Roblox.Instance = roblox.Instance
Roblox.CFrame = roblox.CFrame
Roblox.Vector3 = roblox.Vector3
Roblox.Enum = roblox.Enum

local BlockRig = require("../rigs/blockrig")
local Curves = require("../../src/Editing/Curves")
local Pose = require("../../src/Rigs/Pose")
local Digest = require("../../src/Inspection/Digest")
local Operations = require("../../src/Editing/Operations")
local Reading = require("../../src/Inspection/Reading")
local Rig = require("../../src/Rigs/Rig")
local Validate = require("../../src/Inspection/Validate")

Curves.backend = {
	keys = function(curve)
		local text = curve:GetAttribute("Keys")
		return if text then serde.decode("json", text) else {}
	end,
	setKeys = function(curve, keys)
		curve:SetAttribute("Keys", serde.encode("json", keys))
	end,
	markers = function(curve)
		local text = curve:GetAttribute("Markers")
		return if text then serde.decode("json", text) else {}
	end,
	setMarkers = function(curve, markers)
		curve:SetAttribute("Markers", serde.encode("json", markers))
	end,
}

local Instance = roblox.Instance
local Enum = roblox.Enum

local failures = 0
local count = 0
local current = ""

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL [{current}] {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

local function case(name: string, run: () -> ())
	current = name
	local ok, problem = pcall(run)
	if not ok then
		count += 1
		failures += 1
		print(
			`FAIL [{name}] raised: {if type(problem) == "table" then (problem :: any).message else tostring(problem)}`
		)
	end
end

local JOINTS: { [string]: any } = {}
for _, name in Rig.R15_ORDER do
	JOINTS[name] = true
end

local function blank(): any
	local clip = Instance.new("CurveAnimation")
	clip.Name = "Clip"
	clip.Loop = false
	clip.Priority = Enum.AnimationPriority.Action
	return clip
end

local function run(clip: any, operations: { any }, source: any?): { [string]: number }
	Curves.check(operations, JOINTS)
	return Curves.run(clip, operations, { joints = JOINTS, source = source })
end

local function refusal(clip: any, operations: any): any
	local ok, problem = pcall(run, clip, operations)
	return if ok then nil else problem
end

local function near(a: number, b: number, within: number?): boolean
	return math.abs(a - b) <= (within or 1e-6)
end

local function keysOf(clip: any, joint: string, channel: string): { any }
	local curve = Curves.channel(clip, joint, channel, false)
	return if curve then Curves.keys(curve) else {}
end

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
	local markers = Curves.backend.markers(hit)
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

-- A keyframe clip: the head turning through three poses, a marker on the middle one.
local function keyframed(): any
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "Turn"
	sequence.Loop = false
	sequence.Priority = Enum.AnimationPriority.Action
	Operations.run(sequence, {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 0.5, rotation = { 10, 170, 0 } },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, -170, 0 }, position = { 0, 0.5, 0 } },
		{ type = "set_marker", time = 0.5, name = "Look", value = "left" },
	}, { joints = JOINTS })
	return sequence
end

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
	check("markers come along", look and Curves.backend.markers(look)[1].value == "left")
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

-- ---------------------------------------------------------------------------------------
-- Pinning and contact, on a rig with real geometry

local REAL = Rig.scan(BlockRig.build()).joints

local function realRun(clip: any, operations: { any }): { [string]: number }
	Curves.check(operations, REAL)
	return Curves.run(clip, operations, { joints = REAL })
end

-- Where every part is at a time, as the clip's curves give it.
local function placedAt(clip: any, time: number): { [string]: any }
	local transforms = {}
	for _, joint in Rig.R15_ORDER do
		local values = {}
		for index, channel in Curves.CHANNELS do
			local curve = Curves.channel(clip, joint, channel, false)
			values[index] = if curve then Curves.evaluate(Curves.keys(curve), time) else 0
		end
		transforms[joint] = roblox.CFrame.new(values[1], values[2], values[3])
			* roblox.CFrame.fromEulerAnglesXYZ(values[4], values[5], values[6])
	end
	return Pose.place({ joints = REAL } :: any, transforms, roblox.CFrame.new())
end

local function turnBetween(a: any, b: any): number
	local squares = (a.RightVector - b.RightVector).Magnitude ^ 2
		+ (a.UpVector - b.UpVector).Magnitude ^ 2
		+ (a.LookVector - b.LookVector).Magnitude ^ 2
	return math.deg(2 * math.asin(math.min(1, math.sqrt(squares / 8))))
end

-- Which way a part faces across the floor, in degrees.
local function yaw(part: any): number
	return math.deg(math.atan2(-part.LookVector.X, -part.LookVector.Z))
end

-- Hips that drop and come back up over a second, with nothing else keyed.
local function squat(depth: number, sideways: number?): any
	local clip = blank()
	realRun(clip, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 0.5, position = { sideways or 0, -depth, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	return clip
end

case("a pinned foot stays where it was while the hips drop", function()
	local clip = squat(0.8)
	local start = placedAt(clip, 0).LeftFoot
	check(
		"before pinning, the foot drops with the hips",
		placedAt(clip, 0.5).LeftFoot.Position.Y < start.Position.Y - 0.7
	)
	local changed = realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1 } })
	check("every frame is pinned", changed.frames_pinned == 31, changed.frames_pinned)
	check("nothing was out of reach", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local studs, degrees = 0, 0
	for frame = 0, 30 do
		local foot = placedAt(clip, frame / 30).LeftFoot
		studs = math.max(studs, (foot.Position - start.Position).Magnitude)
		degrees = math.max(degrees, turnBetween(foot, start))
	end
	check("the foot stays within a thousandth of a stud", studs < 0.001, studs)
	check("and does not turn", degrees < 0.05, degrees)
	local knee = Curves.keys(assert(Curves.channel(clip, "LeftLowerLeg", "rotation.x", false)))
	check("the knee is keyed on every frame", #knee == 31, #knee)
	local onFrames = true
	for _, key in knee do
		onFrames = onFrames and math.abs(key.time * 30 - math.round(key.time * 30)) < 1e-6
	end
	check("on whole frames", onFrames)
	check("the knee bends forward at the bottom", knee[16].value < -0.3, knee[16].value)
	check("the other foot is not touched", Curves.folder(clip, "RightUpperLeg", false) == nil)
	check("and still drops", placedAt(clip, 0.5).RightFoot.Position.Y < start.Position.Y - 0.7)
end)

case("a foot that cannot stay is reached for, and the result says by how much it fell short", function()
	local clip = squat(-1)
	local changed = realRun(clip, { { type = "pin", part = "RightFoot", time_from = 0, time_to = 1 } })
	check("some frames were out of reach", (changed.frames_out_of_reach or 0) > 0, changed.frames_out_of_reach)
	check("with the worst shortfall", (changed.largest_miss_studs or 0) > 0.5, changed.largest_miss_studs)
	-- The hips rise highest at the middle of the clip, so that is where the leg falls short.
	check(
		"and when",
		(changed.out_of_reach_from or 0) > 0
			and (changed.out_of_reach_from or 0) < 0.5
			and (changed.out_of_reach_to or 1) > 0.5
			and (changed.out_of_reach_to or 1) < 1,
		`{changed.out_of_reach_from} to {changed.out_of_reach_to}`
	)
end)

case("a pin over part of a clip leaves the rest of it as it was", function()
	local clip = squat(0.8)
	local outside = { 0.1, 0.2, 0.8, 0.9 }
	local before = {}
	for _, time in outside do
		before[time] = placedAt(clip, time).LeftFoot
	end
	local pinnedAt = placedAt(clip, 0.4).LeftFoot
	realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0.4, time_to = 0.6 } })
	for _, time in outside do
		local moved = (placedAt(clip, time).LeftFoot.Position - before[time].Position).Magnitude
		check(`the foot at {time} seconds is where it was`, moved < 1e-4, moved)
	end
	local held = 0
	for frame = 12, 18 do
		held = math.max(held, (placedAt(clip, frame / 30).LeftFoot.Position - pinnedAt.Position).Magnitude)
	end
	check("and held inside the range", held < 0.001, held)
end)

case("a pin blends in and out over the time asked", function()
	local clip = squat(0.8)
	local free = {}
	for frame = 0, 30 do
		free[frame] = placedAt(clip, frame / 30).LeftFoot
	end
	realRun(clip, {
		-- Held where it stands at the start, which the bent leg can reach.
		{ type = "pin", part = "LeftFoot", time_from = 0.4, time_to = 0.6, at = 0, blend_in = 0.2, blend_out = 0.2 },
	})
	local pinned = free[0]
	local function along(frame: number): number
		-- How far from its free path toward the pinned point the foot is, from 0 to 1.
		local gap = (free[frame].Position - pinned.Position).Magnitude
		if gap < 1e-6 then
			return 1
		end
		return 1 - (placedAt(clip, frame / 30).LeftFoot.Position - pinned.Position).Magnitude / gap
	end
	check("at the start of the blend the foot is free", along(6) < 0.01, along(6))
	check("halfway in, it is partway", along(9) > 0.2 and along(9) < 0.8, along(9))
	check("in the range, it is pinned", along(15) > 0.999, along(15))
	check("halfway out, it is partway", along(21) > 0.2 and along(21) < 0.8, along(21))
	check("at the end of the blend it is free again", along(24) < 0.01, along(24))
end)

case("easing in and out, the foot travels straight between its own path and the hold", function()
	-- The hips drop while the leg swings forward and back: on its own, the foot sweeps an
	-- arc. Easing joint angles would carry it along a curve of its own; easing the target
	-- keeps it on the line between where the animation has it and where it is held.
	local clip = squat(0.6)
	realRun(clip, {
		{ type = "set_key", joint = "LeftUpperLeg", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LeftUpperLeg", time = 0.5, rotation = { 50, 0, 0 } },
		{ type = "set_key", joint = "LeftUpperLeg", time = 1, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LeftLowerLeg", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LeftLowerLeg", time = 0.5, rotation = { -70, 0, 0 } },
		{ type = "set_key", joint = "LeftLowerLeg", time = 1, rotation = { 0, 0, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	local free = {}
	for frame = 0, 30 do
		free[frame] = placedAt(clip, frame / 30).LeftFoot
	end
	local held = free[0]
	realRun(clip, {
		{ type = "pin", part = "LeftFoot", time_from = 0.4, time_to = 0.6, at = 0, blend_in = 0.3, blend_out = 0.3 },
	})
	local function smoothstep(t: number): number
		t = math.clamp(t, 0, 1)
		return t * t * (3 - 2 * t)
	end
	local worst, turned = 0, 0
	for frame = 3, 27 do
		local time = frame / 30
		local weight = if time < 0.4
			then smoothstep((time - 0.1) / 0.3)
			elseif time > 0.6 then smoothstep((0.9 - time) / 0.3)
			else 1
		local wanted = free[frame]:Lerp(held, weight)
		local foot = placedAt(clip, time).LeftFoot
		worst = math.max(worst, (foot.Position - wanted.Position).Magnitude)
		turned = math.max(turned, turnBetween(foot, wanted))
	end
	check("the foot is on the line at every frame", worst < 0.001, worst)
	check("turning evenly from its own turn to the held one", turned < 0.05, turned)
end)

case("a pin can put a hand somewhere new", function()
	local clip = squat(0.4)
	local target = { 0.6, 0.4, -1.4 }
	realRun(clip, {
		{ type = "pin", part = "RightHand", time_from = 0, time_to = 1, position = target },
	})
	local worst = 0
	for frame = 0, 30 do
		local hand = placedAt(clip, frame / 30).RightHand.Position
		worst = math.max(worst, (hand - roblox.Vector3.new(target[1], target[2], target[3])).Magnitude)
	end
	check("the hand is held there through the squat", worst < 0.001, worst)
end)

-- Hips that drop while the chest bends forward and turns, over a second.
local function hunch(): any
	local clip = squat(0.4)
	realRun(clip, {
		{ type = "set_key", joint = "UpperTorso", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 0.5, rotation = { -35, 20, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 1, rotation = { 0, 0, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	return clip
end

case("a pin relative to another part moves with that part", function()
	local clip = hunch()
	local offset = roblox.Vector3.new(0.3, 0.2, -1)
	local changed = realRun(clip, {
		{
			type = "pin",
			part = "RightHand",
			time_from = 0,
			time_to = 1,
			relative_to = "UpperTorso",
			position = { offset.X, offset.Y, offset.Z },
		},
	})
	check("nothing was out of reach", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local worst, travelled = 0, 0
	local start = placedAt(clip, 0).RightHand.Position
	for frame = 0, 30 do
		local placed = placedAt(clip, frame / 30)
		local wanted = placed.UpperTorso:PointToWorldSpace(offset)
		worst = math.max(worst, (placed.RightHand.Position - wanted).Magnitude)
		travelled = math.max(travelled, (placed.RightHand.Position - start).Magnitude)
	end
	check("the hand stays on the chest", worst < 0.001, worst)
	check("and so moves through the room with it", travelled > 0.5, travelled)

	-- Without a position, the hand keeps where it was against the part at `at`.
	local kept = hunch()
	local before = placedAt(kept, 0)
	local relation = before.UpperTorso:Inverse() * before.LeftHand
	realRun(kept, { { type = "pin", part = "LeftHand", time_from = 0, time_to = 1, relative_to = "UpperTorso" } })
	local drift, turned = 0, 0
	for frame = 0, 30 do
		local placed = placedAt(kept, frame / 30)
		local wanted = placed.UpperTorso * relation
		drift = math.max(drift, (placed.LeftHand.Position - wanted.Position).Magnitude)
		turned = math.max(turned, turnBetween(placed.LeftHand, wanted))
	end
	check("a hand held to the chest as it was stays so", drift < 0.001, drift)
	check("turning with it", turned < 0.05, turned)
end)

case("a range written to four decimals covers the frames it names", function()
	local clip = squat(0.5)
	-- 0.3667 is a little after frame 11 (0.36666...) and 0.6333 a little before frame 19
	-- (0.63333...): each is still that frame.
	local changed = realRun(clip, {
		{ type = "place_on_floor", time_from = 0.3667, time_to = 0.3667, mode = "touch" },
		{ type = "pin", part = "LeftFoot", time_from = 0.6333, time_to = 0.6333 },
	})
	check("a one-frame place_on_floor", changed.frames_moved == 1, changed.frames_moved)
	check("a one-frame pin", changed.frames_pinned == 1, changed.frames_pinned)
end)

case("a soft pin does not lock the knee straight, and says how short it fell", function()
	-- The hips drop from standing, where the leg is at full reach.
	local function kneeSpeed(soft: number?): (number, any)
		local clip = squat(0.4)
		local changed = realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, soft = soft } })
		local knee = keysOf(clip, "LeftLowerLeg", "rotation.x")
		local fastest = 0
		for frame = 1, 8 do
			local a = Curves.evaluate(knee, (frame - 1) / 30)
			local b = Curves.evaluate(knee, frame / 30)
			fastest = math.max(fastest, math.abs(math.deg(b - a)))
		end
		return fastest, changed
	end
	local hard = kneeSpeed()
	local soft, changed = kneeSpeed(0.1)
	check("the knee moves less suddenly as the hips first drop", soft < hard * 0.8, `{soft} against {hard}`)
	check("softened frames are not out of reach", changed.frames_out_of_reach == nil, changed.frames_out_of_reach)
	check("the result says how short it fell", (changed.largest_soft_studs or 0) > 0, changed.largest_soft_studs)
end)

case("a pin with travel holds the foot on a floor that moves steadily", function()
	local clip = squat(0.3)
	local start = placedAt(clip, 0.2).LeftFoot
	-- While the hips are low, so the leg can follow the foot back.
	local changed = realRun(clip, {
		{ type = "pin", part = "LeftFoot", time_from = 0.2, time_to = 0.6, travel = { 0, 0, 0.6 } },
	})
	check("reached at every frame", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local worst, turned = 0, 0
	for frame = 6, 18 do
		local time = frame / 30
		local foot = placedAt(clip, time).LeftFoot
		local wanted = start.Position + roblox.Vector3.new(0, 0, 0.6 * (time - 0.2))
		worst = math.max(worst, (foot.Position - wanted).Magnitude)
		turned = math.max(turned, turnBetween(foot, start))
	end
	check("the foot moves back at the speed asked, every frame", worst < 0.001, worst)
	check("without turning", turned < 0.05, turned)

	-- Eased in, the point it eases toward is already moving, so it lands moving with it.
	local landing = squat(0.3)
	realRun(landing, {
		{ type = "pin", part = "LeftFoot", time_from = 0.3, time_to = 0.6, travel = { 0, 0, 0.6 }, blend_in = 0.2 },
	})
	local function speedZ(time: number): number
		return (placedAt(landing, time + 1 / 30).LeftFoot.Position.Z - placedAt(landing, time).LeftFoot.Position.Z) * 30
	end
	check(
		"eased in, it already moves with the floor as it lands",
		math.abs(speedZ(0.2667) - 0.6) < 0.15,
		speedZ(0.2667)
	)
end)

case("pins that cannot be done are refused", function()
	local clip = squat(0.5)
	local function refusedReal(operation: any): any
		local ok, problem = pcall(realRun, clip, { operation })
		return if ok then nil else problem
	end
	check("an unknown limb", refusedReal({ type = "pin", part = "Head", time_from = 0, time_to = 1 }) ~= nil)
	local late = refusedReal({ type = "pin", part = "LeftFoot", time_from = 0, time_to = 2 })
	check("past the end of the clip", late and string.find(late.message, "ends at", 1, true), late and late.message)
	check(
		"an unknown hold",
		refusedReal({ type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, hold = "loose" }) ~= nil
	)
	check(
		"too long a blend",
		refusedReal({ type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, blend_in = 5 }) ~= nil
	)
	check(
		"relative to a part of the limb itself",
		refusedReal({ type = "pin", part = "RightHand", time_from = 0, time_to = 1, relative_to = "RightLowerArm" })
			~= nil
	)
	check(
		"relative to a part the rig lacks",
		refusedReal({ type = "pin", part = "RightHand", time_from = 0, time_to = 1, relative_to = "Tail" }) ~= nil
	)
	local blind = refusal(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1 } })
	check(
		"a rig known only by its joint names",
		blind and string.find(blind.message, "could not be measured", 1, true),
		blind and blind.message
	)
end)

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

-- A clip where each side moves its own way, and the middle turns and moves sideways.
local function lopsided(): any
	local clip = blank()
	local function keys(joint: string, a: { number }, b: { number }, c: { number })
		return {
			{ type = "set_key", joint = joint, time = 0, rotation = a },
			{ type = "set_key", joint = joint, time = 0.5, rotation = b },
			{ type = "set_key", joint = joint, time = 1, rotation = c },
		}
	end
	local operations = {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 0.5, position = { 0.3, -0.2, 0.1 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0, 0 } },
	}
	for _, list in
		{
			keys("LowerTorso", { 0, 0, 0 }, { 10, 25, -15 }, { 0, 0, 0 }),
			keys("UpperTorso", { 0, 0, 0 }, { -20, 30, 10 }, { 0, 0, 0 }),
			keys("LeftUpperArm", { 0, 0, 0 }, { 70, 20, -40 }, { 10, 0, 0 }),
			keys("LeftLowerArm", { 0, 0, 0 }, { 60, 0, 0 }, { 0, 0, 0 }),
			keys("RightUpperLeg", { 0, 0, 0 }, { -30, 10, 15 }, { 0, 0, 0 }),
		}
	do
		for _, operation in list do
			table.insert(operations, operation)
		end
	end
	table.insert(operations, { type = "auto_tangents", time_from = 0, time_to = 1 })
	realRun(clip, operations)
	return clip
end

local function mirrorName(name: string): string
	if string.sub(name, 1, 4) == "Left" then
		return "Right" .. string.sub(name, 5)
	elseif string.sub(name, 1, 5) == "Right" then
		return "Left" .. string.sub(name, 6)
	end
	return name
end

-- A frame seen in a mirror across the rig's middle, worked out by reflecting its axes.
local function inMirror(cframe: any): any
	local flip = roblox.Vector3.new(-1, 1, 1)
	local position = cframe.Position * flip
	-- A reflected frame is left-handed; reflecting the whole frame and then turning its X
	-- axis round gives the right-handed frame a mirrored part has.
	local right = -(cframe.RightVector * flip)
	local up = cframe.UpVector * flip
	local back = -(cframe.LookVector * flip)
	return roblox.CFrame.fromMatrix(position, right, up, back)
end

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

-- Every channel of a clip at a time, as one list.
local function sampleAll(clip: any, time: number): { number }
	local values = {}
	for _, joint in Rig.R15_ORDER do
		for _, channel in Curves.CHANNELS do
			local curve = Curves.channel(clip, joint, channel, false)
			table.insert(values, if curve then Curves.evaluate(Curves.keys(curve), time) else 0)
		end
	end
	return values
end
local function difference(a: { number }, b: { number }): number
	local worst = 0
	for index, value in a do
		worst = math.max(worst, math.abs(value - b[index]))
	end
	return worst
end

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

-- The angle in degrees between where a part faces and the way to a point.
local function offAim(part: any, target: any): number
	local toward = (target - part.Position).Unit
	return math.deg(math.acos(math.clamp(part.LookVector:Dot(toward), -1, 1)))
end

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

-- The chest turns 60 degrees in 0.3 seconds and stops; the arm is not animated.
local function turnAndStop(): any
	local clip = blank()
	realRun(clip, {
		{ type = "set_key", joint = "UpperTorso", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 0.3, rotation = { 0, 60, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 1.2, rotation = { 0, 60, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1.2 },
	})
	return clip
end

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

case("a range rewritten frame by frame leaves the motion either side exactly as it was", function()
	local original = lopsided()
	local clip = lopsided()
	-- The left arm has keys before, inside and after the range.
	realRun(clip, { { type = "pin", part = "LeftHand", time_from = 0.3, time_to = 0.6 } })
	local worst = 0
	for frame = 0, 30 do
		local time = frame / 30
		if time < 0.3 - 1e-6 or time > 0.6 + 1e-6 then
			worst = math.max(worst, difference(sampleAll(clip, time), sampleAll(original, time)))
		end
	end
	check("every frame outside the range is unchanged", worst < 1e-6, worst)
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

-- The lowest point of the parts the floor is measured by, at a time.
local MEASURED = {}
for _, name in Rig.R15_ORDER do
	if name ~= "LeftLowerLeg" and name ~= "RightLowerLeg" then
		table.insert(MEASURED, name)
	end
end
local function lowestAt(clip: any, time: number, parts: { string }?): number
	local placed = placedAt(clip, time)
	local lowest = math.huge
	for _, name in parts or MEASURED do
		-- The lowest point of a box whose corners are rounded by 0.4 of its smallest side:
		-- the lowest of the rounding's centres, less the rounding.
		local cframe, size = placed[name], REAL[name].part1.Size
		local round = 0.4 * math.min(size.X, size.Y, size.Z)
		local inner = size / 2 - roblox.Vector3.new(round, round, round)
		local deepest = math.huge
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local corner =
						cframe:PointToWorldSpace(roblox.Vector3.new(sx * inner.X, sy * inner.Y, sz * inner.Z))
					deepest = math.min(deepest, corner.Y - round)
				end
			end
		end
		lowest = math.min(lowest, deepest)
	end
	return lowest
end
local FLOOR = lowestAt(blank(), 0, Rig.R15_ORDER)

case("a pin on_floor stands the foot flat on the floor where it is", function()
	local clip = squat(0.4)
	-- At 0.5 seconds the straight legs have pushed the feet into the floor.
	local sunk = placedAt(clip, 0.5).LeftFoot
	check("before, the foot is in the floor", lowestAt(clip, 0.5, { "LeftFoot" }) < FLOOR - 0.3)
	realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, at = 0.5, on_floor = true } })
	local height, drift = 0, 0
	for frame = 0, 30 do
		height = math.max(height, math.abs(lowestAt(clip, frame / 30, { "LeftFoot" }) - FLOOR))
		local foot = placedAt(clip, frame / 30).LeftFoot.Position
		drift = math.max(drift, math.abs(foot.X - sunk.Position.X) + math.abs(foot.Z - sunk.Position.Z))
	end
	check("after, it stands on the floor at every frame", height < 0.002, height)
	check("where it was, across the floor", drift < 0.002, drift)
	check("not with relative_to", refusal(clip, {
		{ type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, on_floor = true, relative_to = "UpperTorso" },
	}) ~= nil)
end)

case("a pin with a toe or heel pivot rolls the foot over that point", function()
	-- The hips drop and turn, which a planted foot is not to follow.
	local function turning(): any
		local clip = squat(0.3)
		realRun(clip, {
			{ type = "set_key", joint = "LowerTorso", time = 0, rotation = { 0, 0, 0 } },
			{ type = "set_key", joint = "LowerTorso", time = 0.5, rotation = { 0, 20, 0 } },
			{ type = "set_key", joint = "LowerTorso", time = 1, rotation = { 0, 0, 0 } },
			{ type = "auto_tangents", time_from = 0, time_to = 1 },
		})
		return clip
	end
	local size = REAL.LeftFoot.part1.Size
	local function pitch(foot: any): number
		return math.deg(math.asin(math.clamp(foot.LookVector.Y, -1, 1)))
	end

	-- Flat, then up onto the toe and back down, then flat again: as in a step's push-off,
	-- and next to other pins, which rewrite the foot's own keys.
	local clip = turning()
	local toe = roblox.Vector3.new(0, -size.Y / 2, -size.Z / 2)
	local changed = realRun(clip, {
		{ type = "pin", part = "LeftFoot", time_from = 0, time_to = 0.4, on_floor = true },
		{ type = "pin", part = "LeftFoot", time_from = 0.4, time_to = 0.6, pivot = "toe", roll = { 0, 30 } },
		{ type = "pin", part = "LeftFoot", time_from = 0.6, time_to = 0.8, pivot = "toe", roll = { 30, 0 } },
		{ type = "pin", part = "LeftFoot", time_from = 0.8, time_to = 1, on_floor = true },
	})
	check("reached at every frame", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local start = placedAt(clip, 0).LeftFoot:PointToWorldSpace(toe)
	local heading = yaw(placedAt(clip, 0).LeftFoot)
	local drift, twisted = 0, 0
	for frame = 0, 30 do
		local foot = placedAt(clip, frame / 30).LeftFoot
		drift = math.max(drift, (foot:PointToWorldSpace(toe) - start).Magnitude)
		twisted = math.max(twisted, math.abs(yaw(foot) - heading))
	end
	check("the toe stays put throughout", drift < 0.002, drift)
	check("the foot does not turn with the hips", twisted < 0.1, twisted)
	local lifted = placedAt(clip, 0.6).LeftFoot
	check("at the top the heel is lifted as far as asked", math.abs(-pitch(lifted) - 30) < 0.1, pitch(lifted))
	check("and the heel is what rose", lifted:PointToWorldSpace(-toe).Y > start.Y + 0.4)
	check("halfway up, part of the way", math.abs(-pitch(placedAt(clip, 0.5).LeftFoot) - 15) < 0.5)
	local checked = Validate.run(clip, { joints = REAL }, assert(Validate.thresholds({})))
	local slides = 0
	for _, issue in checked.issues do
		if issue.code == "FOOT_SLIDE" and issue.joints[1] == "LeftFoot" then
			slides += 1
		end
	end
	check("rolling over the toe is not taken for sliding", slides == 0, slides)

	-- Landing heel first: the toes start lifted and come down onto the floor.
	local landing = turning()
	local heel = roblox.Vector3.new(0, -size.Y / 2, size.Z / 2)
	realRun(landing, {
		{
			type = "pin",
			part = "LeftFoot",
			time_from = 0,
			time_to = 0.3,
			pivot = "heel",
			roll = { 25, 0 },
			on_floor = true,
		},
	})
	local first = placedAt(landing, 0).LeftFoot
	check("landing, the toes start lifted", math.abs(pitch(first) - 25) < 0.1, pitch(first))
	local heelStart = first:PointToWorldSpace(heel)
	local heelDrift = 0
	for frame = 0, 9 do
		heelDrift =
			math.max(heelDrift, (placedAt(landing, frame / 30).LeftFoot:PointToWorldSpace(heel) - heelStart).Magnitude)
	end
	check("the heel stays put", heelDrift < 0.002, heelDrift)
	check("and on the floor", math.abs(heelStart.Y - FLOOR) < 0.002, heelStart.Y - FLOOR)
	check("the foot ends flat", math.abs(pitch(placedAt(landing, 0.3).LeftFoot)) < 0.1)
	check(
		"a toe pivot on a hand is refused",
		refusal(landing, { { type = "pin", part = "LeftHand", time_from = 0, time_to = 1, pivot = "toe" } }) ~= nil
	)
	check(
		"a roll without a pivot is refused",
		refusal(landing, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, roll = { 0, 10 } } }) ~= nil
	)
end)

case("place_on_floor lifts what sank, and leaves the rest", function()
	local clip = squat(0.8)
	check("before, the feet sink", lowestAt(clip, 0.5) < FLOOR - 0.7, lowestAt(clip, 0.5) - FLOOR)
	local changed = realRun(clip, { { type = "place_on_floor", time_from = 0, time_to = 1 } })
	check("frames were moved", (changed.frames_moved or 0) > 20, changed.frames_moved)
	check("by as much as the deepest sink", math.abs((changed.largest_raise_studs or 0) - 0.8) < 0.01)
	local worst = 0
	for frame = 0, 30 do
		worst = math.max(worst, math.abs(lowestAt(clip, frame / 30) - FLOOR))
	end
	check("after, the lowest part is on the floor at every frame", worst < 0.002, worst)

	local floating = blank()
	realRun(floating, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0.5, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0.5, 0 } },
	})
	local lifted = realRun(floating, { { type = "place_on_floor", time_from = 0, time_to = 1 } })
	check("lift leaves a body in the air where it is", lifted.frames_moved == 0, lifted.frames_moved)
	check("without writing a key", lifted.keys_written == nil, lifted.keys_written)
end)

case("place_on_floor with touch brings a floating body down, by the parts asked", function()
	local clip = blank()
	realRun(clip, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0.5, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 1.2, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, rotation = { 80, 0, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	local changed = realRun(clip, { { type = "place_on_floor", time_from = 0, time_to = 1, mode = "touch" } })
	check("it was lowered", (changed.largest_drop_studs or 0) > 0.4, changed.largest_drop_studs)
	local worst = 0
	for frame = 0, 30 do
		worst = math.max(worst, math.abs(lowestAt(clip, frame / 30) - FLOOR))
	end
	check("the lowest part touches the floor at every frame", worst < 0.002, worst)

	realRun(clip, {
		{ type = "place_on_floor", time_from = 0.5, time_to = 1, mode = "touch", parts = { "UpperTorso" } },
	})
	local torso = math.abs(lowestAt(clip, 1, { "UpperTorso" }) - FLOOR)
	check("by the parts asked: the upper torso rests on the floor", torso < 0.002, torso)

	local function refusedFloor(operation: any): boolean
		return (pcall(realRun, clip, { operation })) == false
	end
	check("an unknown mode", refusedFloor({ type = "place_on_floor", time_from = 0, time_to = 1, mode = "sink" }))
	check("an unknown part", refusedFloor({ type = "place_on_floor", time_from = 0, time_to = 1, parts = { "Tail" } }))
	check("past the end", refusedFloor({ type = "place_on_floor", time_from = 0, time_to = 3 }))
end)

case("contact with the floor is checked in a curve clip", function()
	local function validate(clip: any): any
		return Validate.run(clip, { joints = REAL }, assert(Validate.thresholds({})))
	end
	local standing = squat(0)
	local still = validate(standing)
	check("a rig standing still touches nothing wrong", still.warnings == 0, still.warnings)

	local sunk = validate(squat(0.8))
	check(
		"hips dropping on straight legs sink the feet; the lower legs are not measured",
		sunk.counts.BELOW_FLOOR == 2,
		sunk.counts.BELOW_FLOOR
	)
	local deepest
	for _, issue in sunk.issues do
		if issue.joints[1] == "LeftFoot" then
			deepest = issue
		end
	end
	check("by how much", deepest and math.abs(deepest.measured - 0.8) < 0.02, deepest and deepest.measured)
	check("and when", deepest and math.abs(deepest.time - 0.5) < 0.04, deepest and deepest.time)

	local sliding = squat(0, 0.6)
	local slid = validate(sliding)
	check("feet on the floor that move with the hips slide", slid.counts.FOOT_SLIDE == 2, slid.counts.FOOT_SLIDE)
	realRun(sliding, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1 } })
	local after = validate(sliding)
	check("a pinned foot does not", after.counts.FOOT_SLIDE == 1, after.counts.FOOT_SLIDE)
	check("the other still does", after.issues[1] and after.issues[1].joints[1] == "RightFoot")

	local cycle = blank()
	realRun(cycle, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0, 0 }, interpolation = "Linear" },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0, 1.5 }, interpolation = "Linear" },
		{ type = "set_properties", loop = true },
	})
	local onTheSpot = validate(cycle)
	-- A foot on a moving floor that lands on its heel and pushes off its toe, in a loop.
	local stepping = blank()
	realRun(stepping, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, -0.4, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, -0.4, 0 } },
		{ type = "set_properties", loop = true },
		{
			type = "pin",
			part = "LeftFoot",
			time_from = 0,
			time_to = 0.2,
			pivot = "heel",
			roll = { 15, 0 },
			on_floor = true,
			travel = { 0, 0, 1 },
		},
		{ type = "pin", part = "LeftFoot", time_from = 0.2, time_to = 0.4, on_floor = true, travel = { 0, 0, 1 } },
		{
			type = "pin",
			part = "LeftFoot",
			time_from = 0.4,
			time_to = 0.6,
			pivot = "toe",
			roll = { 0, 20 },
			travel = { 0, 0, 1 },
		},
	})
	local rolled = validate(stepping)
	local leftSlides = 0
	for _, issue in rolled.issues do
		if issue.code == "FOOT_SLIDE" and issue.joints[1] == "LeftFoot" then
			leftSlides += 1
		end
	end
	check("rolling heel to toe on a moving floor in a loop is a cycle, not a slide", leftSlides == 0, leftSlides)
	check(
		"in a loop, feet moving back steadily are a cycle made on the spot",
		onTheSpot.counts.FOOT_SLIDE == nil,
		onTheSpot.counts.FOOT_SLIDE
	)
end)

print(`{count - failures}/{count} curve checks passed`)
if failures > 0 then
	process.exit(1)
end
