--!strict
-- Offline tests for reading a clip. Run with: lune run plugin/test/inspection/reading.test.luau
--
-- Real here: Lune's instances and CFrame arithmetic. Not tested here: working copies and
-- revisions, which Clips adds in Studio, and the size limit in bytes, which the relay
-- applies (test/mcp/read.test.ts).

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Roblox = require("../../src/Core/Roblox") :: any
Roblox.Instance = roblox.Instance
Roblox.CFrame = roblox.CFrame
Roblox.Enum = roblox.Enum

local Operations = require("../../src/Editing/Operations")
local Reading = require("../../src/Inspection/Reading")
local Rig = require("../../src/Rigs/Rig")

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

-- A clip with `keyframes` keyframes a tenth of a second apart, each posing the head and
-- one arm, and a marker on every other keyframe.
local function build(keyframes: number): any
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "Walk"
	sequence.Loop = true
	sequence.Priority = Enum.AnimationPriority.Movement
	local operations = {}
	for index = 0, keyframes - 1 do
		local time = index / 10
		table.insert(operations, { type = "set_pose", joint = "Head", time = time, rotation = { 0, index, 0 } })
		table.insert(
			operations,
			{ type = "set_pose", joint = "LeftUpperArm", time = time, rotation = { 0, 0, -index } }
		)
		if index % 2 == 0 then
			table.insert(operations, { type = "set_marker", time = time, name = "Step", value = tostring(index) })
		end
		if #operations > 200 then
			Operations.run(sequence, operations, { joints = JOINTS })
			operations = {}
		end
	end
	if #operations > 0 then
		Operations.run(sequence, operations, { joints = JOINTS })
	end
	return sequence
end

case("the summary says what the clip is", function()
	local summary = Reading.summary(build(5), {})
	check("its settings", summary.name == "Walk" and summary.loop == true and summary.priority == "Movement")
	check("its length", summary.keyframe_count == 5 and math.abs(summary.duration - 0.4) < 1e-6)
	check("its keyframe times, in order", table.concat(summary.keyframe_times, " ") == "0 0.1 0.2 0.3 0.4")
	check("the joints that move, sorted", table.concat(summary.animated_joints, " ") == "Head LeftUpperArm")
	check(
		"its markers, with their times",
		#summary.markers == 3 and summary.markers[2].time == 0.2 and summary.markers[2].value == "2"
	)
	check(
		"nothing is marked as cut short",
		summary.keyframe_times_truncated == nil and summary.markers_truncated == nil
	)
	check("and no other content is reported when there is none", summary.other_content == nil)
end)

case("a time range narrows the lists and not the counts", function()
	local summary = Reading.summary(build(10), { timeFrom = 0.2, timeTo = 0.4 })
	check("keyframe times in the range", table.concat(summary.keyframe_times, " ") == "0.2 0.3 0.4")
	check("markers in the range", #summary.markers == 2)
	check(
		"the count and the duration are of the whole clip",
		summary.keyframe_count == 10 and math.abs(summary.duration - 0.9) < 1e-6
	)
end)

case("long lists stop at a fixed length and say so", function()
	local limit = Reading.MAX_LISTED
	Reading.MAX_LISTED = 4
	local summary = Reading.summary(build(12), {})
	check("keyframe times stop", #summary.keyframe_times == 4 and summary.keyframe_times_truncated == true)
	check("markers stop", #summary.markers == 4 and summary.markers_truncated == true)
	check("the count is still the whole clip", summary.keyframe_count == 12)
	local narrow = Reading.summary(build(12), { timeFrom = 0, timeTo = 0.2 })
	check("a range that fits is not marked", #narrow.keyframe_times == 3 and narrow.keyframe_times_truncated == nil)
	Reading.MAX_LISTED = limit
end)

case("content that is kept but not edited is counted by class", function()
	local sequence = build(3)
	for _, keyframe in Operations.keyframes(sequence) do
		local face = Instance.new("NumberPose")
		face.Name = "JawDrop"
		face.Parent = keyframe
	end
	local folder = Instance.new("Folder")
	folder.Name = "Notes"
	folder.Parent = sequence
	local inside = Instance.new("StringValue")
	inside.Parent = folder
	local summary = Reading.summary(sequence, {})
	local seen = {}
	for _, entry in summary.other_content do
		table.insert(seen, `{entry.class}={entry.count}`)
	end
	check(
		"each class with its count, sorted",
		table.concat(seen, " ") == "Folder=1 NumberPose=3 StringValue=1",
		table.concat(seen, " ")
	)
	check(
		"a NumberPose is not taken for a moving joint",
		table.concat(summary.animated_joints, " ") == "Head LeftUpperArm"
	)
end)

case("poses come for the joints asked, in keyframe order", function()
	local sequence = build(4)
	local page, total = Reading.poses(sequence, { joints = { "LeftUpperArm", "Head", "RightFoot" } })
	check("only joints that have poses", total == 8 and #page == 8, total)
	check(
		"by keyframe, then in the order the joints were given",
		page[1].joint == "LeftUpperArm" and page[2].joint == "Head" and page[1].time == 0 and page[3].time == 0.1
	)
	check("with Euler rotation and position", math.abs(page[4].rotation[2] - 1) < 0.001 and #page[4].position == 3)
	check("and easing", page[1].easing_style == "Linear" and page[1].easing_direction == "In")
	local ranged, inRange = Reading.poses(sequence, { joints = { "Head" }, timeFrom = 0.1, timeTo = 0.2 })
	check("a time range applies", inRange == 2 and ranged[1].time == 0.1 and ranged[2].time == 0.2)
	local placeholder = Reading.poses(sequence, { joints = { "UpperTorso" } })
	check("a pose that only holds the nesting is not returned", #placeholder == 0)
end)

case("poses come a page at a time and the pages join up", function()
	local sequence = build(25)
	local seen = {}
	local offset = 0
	local pages = 0
	repeat
		local result = Reading.read(
			sequence,
			{ joints = { "Head", "LeftUpperArm" }, offset = offset, limit = 7, posesOnly = offset > 0 }
		)
		check("the total is the same on every page", result.poses_total == 50)
		check("only the first page carries the summary", (result.name ~= nil) == (offset == 0))
		for _, entry in result.poses do
			table.insert(seen, `{entry.joint}@{entry.time}`)
		end
		pages += 1
		offset = result.next_offset or -1
	until offset < 0 or pages > 20
	check("eight pages of at most seven", pages == 8, pages)
	check("every pose once", #seen == 50)
	local unique = {}
	for _, key in seen do
		unique[key] = true
	end
	local distinct = 0
	for _ in unique do
		distinct += 1
	end
	check("and none twice", distinct == 50, distinct)
	check("in order", seen[1] == "Head@0" and seen[50] == "LeftUpperArm@2.4", seen[50])
	local whole = Reading.read(sequence, { joints = { "Head" } })
	check("a read that fits has nothing more to fetch", #whole.poses == 25 and whole.next_offset == nil)
	local summaryOnly = Reading.read(sequence, {})
	check("no joints means no poses", summaryOnly.poses == nil and summaryOnly.keyframe_count == 25)
	check(
		"the page size has a ceiling",
		#select(1, Reading.poses(sequence, { joints = { "Head" }, limit = 1e9 })) == 25
	)
end)

case("rotations can be read and written as quaternions", function()
	local sequence = build(2)
	local page = Reading.poses(sequence, { joints = { "Head" }, quaternion = true })
	local q = page[2].quaternion
	check("a quaternion replaces the Euler angles", page[2].rotation == nil and #q == 4)
	-- One degree about Y.
	check(
		"with the right numbers",
		math.abs(q[2] - math.sin(math.rad(0.5))) < 1e-5 and math.abs(q[4] - math.cos(math.rad(0.5))) < 1e-5,
		table.concat(q, ",")
	)

	-- Every rotation survives the trip to a quaternion and back, in each branch of the conversion.
	local worst = 0
	for _, angles in
		{ { 10, 20, 30 }, { 170, 5, 5 }, { 5, 170, 5 }, { 5, 5, 170 }, { 0, 0, 0 }, { -90, 45, 120 }, { 179, 179, 0 } }
	do
		local original = CFrame.fromEulerAnglesXYZ(math.rad(angles[1]), math.rad(angles[2]), math.rad(angles[3]))
		local quaternion = Rig.quaternion(original)
		check("w is never negative", quaternion[4] >= 0)
		local back = Rig.decode(nil, nil, quaternion)
		local a, b = { original:GetComponents() }, { back:GetComponents() }
		for index = 4, 12 do
			worst = math.max(worst, math.abs(a[index] - b[index]))
		end
	end
	check("round trips agree", worst < 1e-5, worst)

	local scaled = Rig.decode({ 1, 2, 3 }, nil, { 0, 2, 0, 2 })
	local _, y = scaled:ToEulerAnglesXYZ()
	check("a quaternion is brought to unit length", math.abs(math.deg(y) - 90) < 0.001, math.deg(y))
	check("and keeps the position given with it", scaled.Position.Y == 2)

	Operations.check(
		{ { type = "set_pose", joint = "Head", time = 0, quaternion = { 0, 0.7071068, 0, 0.7071068 } } },
		JOINTS
	)
	Operations.run(
		sequence,
		{ { type = "set_pose", joint = "Head", time = 0, quaternion = { 0, 0.7071068, 0, 0.7071068 } } },
		{ joints = JOINTS }
	)
	local head = Operations.findPose(Operations.findKeyframe(sequence, 0) :: any, "Head") :: any
	local _, turned = head.CFrame:ToEulerAnglesXYZ()
	check("a pose can be set from one", math.abs(math.deg(turned) - 90) < 0.001, math.deg(turned))
	for name, operation in
		{
			["both kinds of rotation"] = {
				type = "set_pose",
				joint = "Head",
				time = 0,
				rotation = { 0, 0, 0 },
				quaternion = { 0, 0, 0, 1 },
			},
			["three numbers"] = { type = "set_pose", joint = "Head", time = 0, quaternion = { 0, 0, 1 } },
			["a length far from 1"] = { type = "set_pose", joint = "Head", time = 0, quaternion = { 0, 0, 0, 3 } },
			["all zeros"] = {
				type = "offset_pose",
				joint = "Head",
				time_from = 0,
				time_to = 1,
				quaternion = { 0, 0, 0, 0 },
			},
		} :: { [string]: any }
	do
		local ok, problem = pcall(Operations.check, { operation }, JOINTS)
		check(`refused: {name}`, not ok and (problem :: any).code == "INVALID_ARGUMENT", problem)
	end
end)

print(`{count - failures}/{count} reading checks passed`)
if failures > 0 then
	process.exit(1)
end
