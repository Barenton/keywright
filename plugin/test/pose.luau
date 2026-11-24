--!strict
-- Offline tests for working out where a rig's parts are from its joint transforms.
-- Run with: lune run plugin/test/pose.luau
--
-- Real here: Lune's instances and its CFrame arithmetic. The rule being applied is the
-- one Roblox documents for a Motor6D (Part1 = Part0 * C0 * Transform * C1 inverse).
-- Whether Studio places an AnimationConstraint's part the same way is not tested here;
-- the comparison that checks it in Studio (Pose.compare) is.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Pose = require("../src/Pose")
local Rig = require("../src/Rig")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

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

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 0.001
end

-- Rest offsets of a block rig: { joint, parent, driven, C0 position, C1 position, size }.
local JOINTS: { { any } } = {
	{ "Root", "HumanoidRootPart", "LowerTorso", { 0, -1, 0 }, { 0, -0.2, 0 }, { 2, 0.4, 1 } },
	{ "Waist", "LowerTorso", "UpperTorso", { 0, 0.2, 0 }, { 0, -0.8, 0 }, { 2, 1.6, 1 } },
	{ "Neck", "UpperTorso", "Head", { 0, 0.8, 0 }, { 0, -0.6, 0 }, { 1.2, 1.2, 1.2 } },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm", { -1, 0.5, 0 }, { 0.5, 0.4, 0 }, { 1, 1.2, 1 } },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm", { 0, -0.6, 0 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "LeftWrist", "LeftLowerArm", "LeftHand", { 0, -0.6, 0 }, { 0, 0.15, 0 }, { 1, 0.3, 1 } },
	{ "RightShoulder", "UpperTorso", "RightUpperArm", { 1, 0.5, 0 }, { -0.5, 0.4, 0 }, { 1, 1.2, 1 } },
	{ "RightElbow", "RightUpperArm", "RightLowerArm", { 0, -0.6, 0 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "RightWrist", "RightLowerArm", "RightHand", { 0, -0.6, 0 }, { 0, 0.15, 0 }, { 1, 0.3, 1 } },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg", { -0.5, -0.2, 0 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg", { 0, -0.6, 0 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot", { 0, -0.6, 0 }, { 0, 0.15, 0 }, { 1, 0.3, 1 } },
	{ "RightHip", "LowerTorso", "RightUpperLeg", { 0.5, -0.2, 0 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg", { 0, -0.6, 0 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "RightAnkle", "RightLowerLeg", "RightFoot", { 0, -0.6, 0 }, { 0, 0.15, 0 }, { 1, 0.3, 1 } },
}

-- A rig standing somewhere arbitrary and turned, to show the result does not depend on it.
local function buildRig(without: string?)
	local model = Instance.new("Model")
	local parts: { [string]: any } = {}
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.CFrame = CFrame.new(120, 45, -300) * CFrame.Angles(0, math.rad(70), 0)
	root.Parent = model
	parts.HumanoidRootPart = root
	for _, entry in JOINTS do
		local part = Instance.new("Part")
		part.Name = entry[3]
		part.Size = Vector3.new(entry[6][1], entry[6][2], entry[6][3])
		part.Parent = model
		parts[entry[3]] = part
	end
	for _, entry in JOINTS do
		if entry[3] == without then
			continue
		end
		local motor = Instance.new("Motor6D")
		motor.Name = entry[1]
		motor.Part0 = parts[entry[2]]
		motor.Part1 = parts[entry[3]]
		motor.C0 = CFrame.new(entry[4][1], entry[4][2], entry[4][3])
		motor.C1 = CFrame.new(entry[5][1], entry[5][2], entry[5][3])
		motor.Transform = CFrame.new()
		motor.Parent = parts[entry[3]]
	end
	return model
end

local function rest(): { [string]: any }
	local transforms = {}
	for _, name in Rig.R15_ORDER do
		transforms[name] = CFrame.new()
	end
	return transforms
end

local function byName(parts: { any }): { [string]: any }
	local map = {}
	for _, part in parts do
		map[part.name] = part
	end
	return map
end

case("the rest pose puts every part where its rest offsets say", function()
	local scan = Rig.scan(buildRig())
	local parts = Pose.parts(scan, rest(), CFrame.new())
	check("one entry for each driven part", #parts == 15, #parts)
	check("in the rig's standard order", parts[1].name == "LowerTorso" and parts[15].name == "RightFoot")
	local map = byName(parts)
	check("the root part itself is left out", map.HumanoidRootPart == nil)
	-- Worked by hand from the offsets above.
	local expected = {
		LowerTorso = { 0, -0.8, 0 },
		UpperTorso = { 0, 0.2, 0 },
		Head = { 0, 1.6, 0 },
		LeftUpperArm = { -1.5, 0.3, 0 },
		LeftLowerArm = { -1.5, -0.9, 0 },
		LeftHand = { -1.5, -1.65, 0 },
		RightUpperArm = { 1.5, 0.3, 0 },
		RightHand = { 1.5, -1.65, 0 },
		LeftUpperLeg = { -0.5, -1.6, 0 },
		LeftFoot = { -0.5, -3.55, 0 },
		RightLowerLeg = { 0.5, -2.8, 0 },
	}
	for name, position in expected do
		local c = map[name].cframe
		check(
			`{name} is in place`,
			near(c[1], position[1]) and near(c[2], position[2]) and near(c[3], position[3]),
			`{c[1]}, {c[2]}, {c[3]}`
		)
	end
	local head = map.Head
	check("sizes are the parts' own", head.size[1] == 1.2 and head.size[2] == 1.2 and head.size[3] == 1.2)
	check(
		"an unposed part is not turned",
		near(head.cframe[4], 1) and near(head.cframe[8], 1) and near(head.cframe[12], 1)
	)
	check("each part carries a position and a rotation", #head.cframe == 12, #head.cframe)
end)

case("the result does not depend on where the rig stands", function()
	local first = Pose.parts(Rig.scan(buildRig()), rest(), CFrame.new())
	local moved = buildRig()
	moved.HumanoidRootPart.CFrame = CFrame.new(-9000, 2, 77)
	local second = Pose.parts(Rig.scan(moved), rest(), CFrame.new())
	local same = true
	for index, part in first do
		for slot, value in part.cframe do
			same = same and value == second[index].cframe[slot]
		end
	end
	check("identical for a rig somewhere else", same)
end)

case("turning a joint carries everything below it", function()
	local scan = Rig.scan(buildRig())
	local transforms = rest()
	-- Raise the right arm sideways: a quarter turn about the shoulder's forward axis.
	transforms.RightUpperArm = CFrame.Angles(0, 0, math.rad(90))
	local map = byName(Pose.parts(scan, transforms, CFrame.new()))
	local hand, upper = map.RightHand.cframe, map.RightUpperArm.cframe
	-- By hand: the shoulder is at (1, 0.7). The arm's own centre sits 0.5 across and 0.4
	-- below its joint; turned a quarter, that is 0.4 across and 0.5 above. The forearm
	-- and hand then run 1.2 and 0.75 further out along the same level.
	check(
		"the upper arm is where a quarter turn puts it",
		near(upper[1], 1.4) and near(upper[2], 1.2),
		`{upper[1]}, {upper[2]}`
	)
	check("the hand is out to the side", near(hand[1], 3.35), hand[1])
	check("the hand is level with the arm, not hanging", near(hand[2], 1.2), hand[2])
	check("the arm stays in the body's plane", near(hand[3], 0))
	check("the hand turned with the arm", near(hand[4], 0) and near(hand[7], 1), `{hand[4]}, {hand[7]}`)
	-- Nothing else moved.
	local untouched = byName(Pose.parts(scan, rest(), CFrame.new()))
	for _, name in { "Head", "LeftHand", "LeftFoot", "RightFoot", "UpperTorso" } do
		local same = true
		for slot, value in map[name].cframe do
			same = same and value == untouched[name].cframe[slot]
		end
		check(`{name} is where it was`, same)
	end
end)

case("a joint's offset moves its part and what hangs from it", function()
	local scan = Rig.scan(buildRig())
	local transforms = rest()
	transforms.UpperTorso = CFrame.new(0, 0.5, 0)
	local map = byName(Pose.parts(scan, transforms, CFrame.new()))
	check("the torso rose", near(map.UpperTorso.cframe[2], 0.7), map.UpperTorso.cframe[2])
	check("the head rose with it", near(map.Head.cframe[2], 2.1), map.Head.cframe[2])
	check("the legs did not", near(map.LeftFoot.cframe[2], -3.55), map.LeftFoot.cframe[2])
end)

case("turns down the chain add up", function()
	local scan = Rig.scan(buildRig())
	local transforms = rest()
	transforms.LeftUpperLeg = CFrame.Angles(math.rad(90), 0, 0)
	transforms.LeftLowerLeg = CFrame.Angles(math.rad(-90), 0, 0)
	local map = byName(Pose.parts(scan, transforms, CFrame.new()))
	-- Thigh swung a quarter turn about the hip, shin bent back a quarter turn at the knee:
	-- the shin hangs straight down again, one thigh's length away from where it was.
	local foot, rested = map.LeftFoot.cframe, byName(Pose.parts(scan, rest(), CFrame.new())).LeftFoot.cframe
	check("the shin is upright again", near(foot[8], 1), foot[8])
	check("the foot moved off its rest spot", math.abs(foot[3] - rested[3]) > 0.5, foot[3])
	check("and is higher than at rest", foot[2] > rested[2] + 0.5, foot[2])
end)

case("a pose that cannot be worked out is refused", function()
	local scan = Rig.scan(buildRig())
	local transforms = rest()
	transforms.Head = nil
	local ok, problem = pcall(Pose.parts, scan, transforms, CFrame.new())
	check("a missing transform is refused", not ok and (problem :: any).code == "PREVIEW_UNAVAILABLE", problem)
	-- A rig missing a joint in the middle of a chain cannot place what hangs from it.
	local broken = Rig.scan(buildRig("LeftLowerArm"))
	local again, why = pcall(Pose.parts, broken, rest(), CFrame.new())
	check("a broken chain is refused", not again and (why :: any).code == "PREVIEW_UNAVAILABLE", why)
end)

case("placement is by name, unrounded, and leaves out the root", function()
	local scan = Rig.scan(buildRig())
	local placed = Pose.place(scan, rest(), CFrame.new())
	local names = 0
	for _ in placed do
		names += 1
	end
	check("fifteen driven parts", names == 15, names)
	check("no entry for the root part", placed.HumanoidRootPart == nil)
	local parts = byName(Pose.parts(scan, rest(), CFrame.new()))
	check("the same place the picture uses", near(placed.Head.Position.Y, parts.Head.cframe[2]))
end)

case("where parts are is compared with where they should be", function()
	local scan = Rig.scan(buildRig())
	local expected = Pose.place(scan, rest(), CFrame.new())
	local same = Pose.compare(expected, Pose.place(scan, rest(), CFrame.new()))
	check("identical placements differ by nothing", same.parts == 15 and same.studs == 0 and same.degrees == 0)
	check("and name no part", same.worst == nil, same.worst)

	local moved = Pose.place(scan, rest(), CFrame.new())
	moved.LeftHand = CFrame.new(0.3, 0, 0.4) * moved.LeftHand
	local displaced = Pose.compare(expected, moved)
	check("a part half a stud away is found", math.abs(displaced.studs - 0.5) < 1e-5, displaced.studs)
	check("and named", displaced.worst == "LeftHand", displaced.worst)
	check("without a turn", displaced.degrees < 1e-4, displaced.degrees)

	-- A turn far below a hundredth of a degree must be measured, not lost in rounding.
	for _, degrees in { 0.005, 0.5, 30 } do
		local turned = Pose.place(scan, rest(), CFrame.new())
		turned.Head = turned.Head * CFrame.Angles(0, math.rad(degrees), 0)
		local found = Pose.compare(expected, turned)
		check(
			`a turn of {degrees} degrees is measured`,
			math.abs(found.degrees - degrees) < math.max(0.001, degrees * 0.001),
			found.degrees
		)
		check("and the turned part is named", found.worst == "Head", found.worst)
	end

	local fewer = Pose.place(scan, rest(), CFrame.new())
	fewer.RightFoot = nil
	check("a part missing from one side is not compared", Pose.compare(expected, fewer).parts == 14)
end)

print(`{count - failures}/{count} pose checks passed`)
if failures > 0 then
	process.exit(1)
end
