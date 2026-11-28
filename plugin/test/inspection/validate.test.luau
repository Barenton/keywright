--!strict
-- Offline tests for the checks on a clip. Run with: lune run plugin/test/inspection/validate.test.luau
--
-- Real here: Lune's instances and CFrame arithmetic, on clips built by the edit
-- operations and then damaged by hand where an edit would refuse to. Not tested here:
-- which joints of a real rig are non-kinematic, and that saving refuses a clip with
-- errors, both of which are the handler's part in Studio.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Roblox = require("../../src/Core/Roblox") :: any
Roblox.Instance = roblox.Instance
Roblox.CFrame = roblox.CFrame
Roblox.Enum = roblox.Enum

local Operations = require("../../src/Editing/Operations")
local Sequence = require("../../src/Editing/KeyframeEdit/Sequence")
local Rig = require("../../src/Rigs/Rig")
local Validate = require("../../src/Inspection/Validate")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
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

local function build(operations: { any }, loop: boolean?): any
	local sequence = Instance.new("KeyframeSequence")
	sequence.Loop = loop == true
	sequence.Priority = Enum.AnimationPriority.Action
	Operations.check(operations, JOINTS)
	Operations.run(sequence, operations, { joints = JOINTS })
	return sequence
end

local function validate(sequence: any, thresholds: any?, nonKinematic: any?): any
	local limits = assert(Validate.thresholds(thresholds))
	return Validate.run(sequence, { joints = JOINTS, nonKinematic = nonKinematic }, limits)
end

local function codes(result: any): string
	local list = {}
	for _, issue in result.issues do
		table.insert(list, issue.code)
	end
	return table.concat(list, " ")
end

local function only(result: any, code: string): any
	for _, issue in result.issues do
		if issue.code == code then
			return issue
		end
	end
	return nil
end

local function pose(sequence: any, joint: string, time: number): any
	return Operations.findPose(Operations.findKeyframe(sequence, time) :: any, joint)
end

-- A gentle wave: the arm swings out and back over two seconds.
local function wave(loop: boolean?): any
	return build({
		{ type = "set_pose", joint = "LeftUpperArm", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "LeftUpperArm", time = 1, rotation = { 0, 0, -60 } },
		{ type = "set_pose", joint = "LeftUpperArm", time = 2, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 10, 0 } },
		{ type = "set_pose", joint = "Head", time = 2, rotation = { 0, 10, 0 } },
	}, loop)
end

case("a sound clip has no findings", function()
	for _, loop in { false, true } do
		local result = validate(wave(loop))
		check("valid", result.valid == true and result.errors == 0 and result.warnings == 0, codes(result))
		check("nothing listed", #result.issues == 0 and next(result.counts) == nil and result.issues_truncated == nil)
	end
	check("an empty clip is sound too", validate(build({ { type = "set_properties", loop = true } })).valid)
	check("the limits used are returned", validate(wave()).thresholds.loop_rotation_degrees == 2)
end)

case("structural problems are errors", function()
	local sequence = wave()
	pose(sequence, "Head", 0).Name = "Tail"
	local unknown = validate(sequence)
	local issue = only(unknown, "UNKNOWN_JOINT")
	check(
		"a pose for a joint the rig lacks",
		unknown.valid == false and issue and issue.severity == "error" and issue.joints[1] == "Tail" and issue.time == 0,
		codes(unknown)
	)

	sequence = wave()
	local stray = Instance.new("Keyframe")
	stray.Time = 1.0004
	stray.Parent = sequence
	check(
		"two keyframes at one time",
		only(validate(sequence), "DUPLICATE_KEYFRAME") ~= nil and not validate(sequence).valid
	)

	sequence = wave()
	local twin = pose(sequence, "Head", 0):Clone()
	twin.Parent = Operations.findKeyframe(sequence, 0)
	local doubled = only(validate(sequence), "DUPLICATE_POSE")
	check("two poses for one joint in a keyframe", doubled and doubled.joints[1] == "Head" and doubled.time == 0)

	sequence = wave()
	pose(sequence, "Head", 2).CFrame = CFrame.new(0, 0 / 0, 0)
	check(
		"a number that is not finite",
		only(validate(sequence), "NON_FINITE_TRANSFORM") ~= nil and not validate(sequence).valid
	)

	sequence = wave()
	pose(sequence, "Head", 2).CFrame = CFrame.new(0, 5000, 0)
	local far = only(validate(sequence), "POSITION_OUT_OF_RANGE")
	check(
		"a position past the limit",
		far and far.measured == 5000 and far.threshold == Operations.MAX_POSITION and far.unit == "studs"
	)

	sequence = wave();
	(Operations.findKeyframe(sequence, 2) :: any).Time = 400
	local late = only(validate(sequence), "INVALID_KEYFRAME_TIME")
	check("a keyframe past the longest clip", late and late.severity == "error" and late.measured == 400)

	sequence = wave()
	local limit = Sequence.MAX_KEYFRAMES
	Sequence.MAX_KEYFRAMES = 2
	local crowded = validate(sequence)
	Sequence.MAX_KEYFRAMES = limit
	check("more keyframes than are supported", only(crowded, "TOO_MANY_KEYFRAMES") ~= nil and not crowded.valid)
end)

case("the root part and placeholders are not taken for unknown joints", function()
	local sequence = wave()
	local root = (Operations.findKeyframe(sequence, 0) :: any):FindFirstChild("HumanoidRootPart")
	root.Weight = 1
	check("a pose on the root part is allowed", validate(sequence).valid, codes(validate(sequence)))
	local holder = Instance.new("Pose")
	holder.Name = "SomethingElse"
	holder.Weight = 0
	holder.Parent = Operations.findKeyframe(sequence, 1)
	check("a pose with no weight moves nothing, whatever its name", validate(sequence).valid)
end)

case("a loop that does not close is a warning, with the amount", function()
	local sequence = build({
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 30, 0 }, position = { 0, 0.5, 0 } },
		{ type = "set_pose", joint = "LeftHand", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "LeftHand", time = 1, rotation = { 0, 1, 0 } },
		{ type = "set_pose", joint = "RightHand", time = 0.5, rotation = { 0, 50, 0 } },
	}, true)
	local result = validate(sequence)
	check("the clip is still valid", result.valid == true and result.errors == 0)
	local rotation = only(result, "LOOP_ROTATION_MISMATCH")
	check(
		"the turn is measured against its limit",
		rotation
			and rotation.joints[1] == "Head"
			and math.abs(rotation.measured - 30) < 0.01
			and rotation.threshold == 2
			and rotation.unit == "degrees",
		rotation and rotation.measured
	)
	check("over the whole clip", rotation.time_from == 0 and rotation.time_to == 1)
	local position = only(result, "LOOP_POSITION_MISMATCH")
	check("so is the distance", position and math.abs(position.measured - 0.5) < 0.001 and position.threshold == 0.02)
	check("a joint within the limit is not reported", result.counts.LOOP_ROTATION_MISMATCH == 1)
	check("nor one that is not keyed at both ends", not string.find(codes(result), "RightHand"))

	sequence.Loop = false
	check("a clip that does not loop is not held to this", #validate(sequence).issues == 0, codes(validate(sequence)))
	sequence.Loop = true
	local loose = validate(sequence, { loop_rotation_degrees = 45, loop_position_studs = 1 })
	check("the limits can be widened for one call", #loose.issues == 0 and loose.thresholds.loop_rotation_degrees == 45)
	local tight = validate(sequence, { loop_rotation_degrees = 0.5 })
	check("or narrowed", tight.counts.LOOP_ROTATION_MISMATCH == 2)
end)

case("a joint that moves too fast between keyframes is a warning", function()
	local sequence = build({
		{ type = "set_pose", joint = "RightUpperArm", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "RightUpperArm", time = 0.02, rotation = { 0, 0, 90 } },
		{ type = "set_pose", joint = "RightUpperArm", time = 1, rotation = { 0, 0, 100 } },
		{ type = "set_pose", joint = "UpperTorso", time = 0, position = { 0, 0, 0 } },
		{ type = "set_pose", joint = "UpperTorso", time = 0.1, position = { 0, 10, 0 } },
	})
	local result = validate(sequence)
	local rotation = only(result, "ABRUPT_ROTATION")
	check(
		"the turn rate is measured",
		rotation and math.abs(rotation.measured - 4500) < 5 and rotation.threshold == 2500,
		rotation and rotation.measured
	)
	check(
		"between the two keyframes",
		rotation.time_from == 0 and rotation.time_to == 0.02 and rotation.joints[1] == "RightUpperArm"
	)
	local move = only(result, "ABRUPT_MOVE")
	check(
		"the speed is measured",
		move and math.abs(move.measured - 100) < 0.1 and move.unit == "studs per second",
		move and move.measured
	)
	check("the slow stretch is not reported", result.counts.ABRUPT_ROTATION == 1 and result.valid == true)
	check(
		"a faster limit lets it pass",
		#validate(sequence, { speed_degrees_per_second = 5000, speed_studs_per_second = 200 }).issues == 0
	)
end)

case("joints driven through forces, odd nesting and unknown content are warnings", function()
	local forced = validate(wave(), nil, { LeftUpperArm = true, RightFoot = true })
	local issue = only(forced, "NON_KINEMATIC_JOINT")
	check("a non-kinematic joint the clip moves", forced.valid and issue and issue.joints[1] == "LeftUpperArm")
	check("one it does not move is left out", forced.counts.NON_KINEMATIC_JOINT == 1)

	local sequence = wave()
	pose(sequence, "Head", 0).Parent = pose(sequence, "LeftUpperArm", 0)
	local nested = only(validate(sequence), "POSE_HIERARCHY")
	check("a pose under the wrong parent", nested and nested.severity == "warning" and nested.joints[1] == "Head")

	sequence = wave()
	local face = Instance.new("NumberPose")
	face.Parent = Operations.findKeyframe(sequence, 0)
	local other = only(validate(sequence), "OTHER_CONTENT")
	check("content that is kept but not understood", other and other.measured == 1 and validate(sequence).valid)
end)

case("findings are bounded, counted and in a fixed order", function()
	local operations = {}
	for index = 0, 119 do
		-- Sixty jumps of 170 degrees, a hundredth of a second each.
		table.insert(operations, {
			type = "set_pose",
			joint = "Head",
			time = index * 0.01,
			rotation = { 0, if index % 2 == 0 then 0 else 170, 0 },
		})
	end
	local sequence = build(operations)
	pose(sequence, "Head", 0.5).CFrame = CFrame.new(0, 0 / 0, 0)
	local result = validate(sequence)
	check("at most fifty are listed", #result.issues == Validate.MAX_ISSUES and result.issues_truncated == true)
	check(
		"the counts are of all of them",
		result.counts.ABRUPT_ROTATION > 100 and result.warnings == result.counts.ABRUPT_ROTATION
	)
	check("errors come first", result.issues[1].code == "NON_FINITE_TRANSFORM" and result.errors == 1)
	local ordered = true
	for index = 3, #result.issues do
		ordered = ordered and result.issues[index - 1].time_from <= result.issues[index].time_from
	end
	check("then by time", ordered)
	check("the same clip gives the same list", codes(validate(sequence)) == codes(result))
end)

case("limits a caller gives are checked", function()
	check("the defaults when none are given", (Validate.thresholds(nil) :: any).speed_studs_per_second == 40)
	check(
		"defaults are not changed by an override",
		(Validate.thresholds({ speed_studs_per_second = 5 }) :: any).speed_studs_per_second == 5
			and Validate.DEFAULTS.speed_studs_per_second == 40
	)
	for name, given in
		{
			["a name that is not a limit"] = { speed = 1 },
			["zero"] = { loop_rotation_degrees = 0 },
			["text"] = { loop_rotation_degrees = "2" },
			["not an object"] = 5,
		} :: { [string]: any }
	do
		local thresholds, problem = Validate.thresholds(given)
		check(`refused: {name}`, thresholds == nil and type(problem) == "string", problem)
	end
end)

print(`{count - failures}/{count} validation checks passed`)
if failures > 0 then
	process.exit(1)
end
