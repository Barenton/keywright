--!strict
-- Offline tests for rig inspection. Run with: lune run plugin/test/rigs/rig.test.luau
--
-- Real here: Lune's instances, built as an R15 block rig with Motor6D joints. Not tested
-- here: AnimationConstraint joints, which were inspected in Studio, and anything about
-- how Studio builds a real character.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Roblox = require("../../src/Core/Roblox") :: any
Roblox.Instance = roblox.Instance
Roblox.CFrame = roblox.CFrame
Roblox.Enum = roblox.Enum

local Rig = require("../../src/Rigs/Rig")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3
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

-- A place with a Workspace, and in it a block rig with all fifteen joints.
local function build(): (any, { [string]: any })
	local place = Instance.new("Folder")
	place.Name = "Workspace"
	Roblox.Workspace = place
	local model = Instance.new("Model")
	model.Name = "Dummy"
	model.Parent = place
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.Parent = model
	local parts: { [string]: any } = {}
	local function part(name: string)
		local created = Instance.new("Part")
		created.Name = name
		created.Size = Vector3.new(1, 1.23456789, 1)
		created.Parent = model
		parts[name] = created
	end
	part(Rig.ROOT)
	for _, name in Rig.R15_ORDER do
		part(name)
	end
	for _, name in Rig.R15_ORDER do
		local motor = Instance.new("Motor6D")
		motor.Name = name .. "Joint"
		motor.Part0 = parts[Rig.R15_PARENTS[name]]
		motor.Part1 = parts[name]
		motor.C0 = CFrame.new(0, 0.5, 0)
		motor.C1 = CFrame.new(0, -0.25, 0)
		motor.Parent = parts[name]
	end
	return model, parts
end

local function reasons(description: any): string
	return table.concat(description.reasons, " | ")
end

case("a standard rig is supported and summarised", function()
	local model = build()
	local description = Rig.describe(model)
	check(
		"supported, with no reasons against",
		description.supported and #description.reasons == 0,
		reasons(description)
	)
	check("its type and name", description.rig_type == "R15" and description.name == "Dummy")
	check("fifteen joints, all Motor6D", description.joint_count == 15 and description.joint_classes.Motor6D == 15)
	check(
		"the names an edit can use, parents first",
		#description.joint_names == 15
			and description.joint_names[1] == "LowerTorso"
			and description.joint_names[3] == "Head"
	)
	check("no detail unless asked", description.joints == nil)
	check(
		"nothing extra, nothing non-kinematic",
		#description.extra_joints == 0 and #description.non_kinematic_joints == 0
	)
	check("it passes the gate for editing", Rig.require(model).joints.Head ~= nil)
end)

case("detail gives each joint's parent, class, rest offsets and size", function()
	local description = Rig.describe((build()), true)
	local head
	for _, joint in description.joints do
		if joint.name == "Head" then
			head = joint
		end
	end
	check("one entry per joint", #description.joints == 15)
	check("parent part and joint name", head.parent == "UpperTorso" and head.joint_name == "HeadJoint")
	check("class and kinematic", head.class == "Motor6D" and head.kinematic == true)
	check("rest offsets", head.c0.position[2] == 0.5 and head.c1.position[2] == -0.25)
	check("size, rounded", head.size[2] == 1.2346, head.size[2])
end)

case("what makes a rig unsupported is said, each reason by itself", function()
	local model, parts = build()
	parts.LeftHand:FindFirstChildOfClass("Motor6D").Parent = nil
	local missing = Rig.describe(model)
	check(
		"a missing joint",
		not missing.supported
			and string.find(reasons(missing), 'No joint drives "LeftHand" from "LeftLowerArm"', 1, true),
		reasons(missing)
	)
	check("is not counted or named", missing.joint_count == 14 and not table.find(missing.joint_names, "LeftHand"))
	local refused, problem = pcall(Rig.require, model)
	check(
		"and editing is refused with the reasons",
		not refused
			and (problem :: any).code == "UNSUPPORTED_RIG"
			and string.find((problem :: any).message, "LeftHand") ~= nil
	)

	model, parts = build()
	local twin = Instance.new("Part")
	twin.Name = "Head"
	twin.Parent = model
	check(
		"two parts with one name",
		string.find(reasons(Rig.describe(model)), '2 parts are named "Head"', 1, true) ~= nil,
		reasons(Rig.describe(model))
	)

	model, parts = build()
	local second = parts.Head:FindFirstChildOfClass("Motor6D"):Clone()
	second.Parent = parts.UpperTorso
	check(
		"two joints driving one part",
		string.find(reasons(Rig.describe(model)), 'Two joints drive "Head"', 1, true) ~= nil
	)

	model = build()
	model:FindFirstChildOfClass("Humanoid").RigType = Enum.HumanoidRigType.R6
	check("another rig type", string.find(reasons(Rig.describe(model)), "only R15 is supported", 1, true) ~= nil)

	model = build()
	model:FindFirstChildOfClass("Humanoid").Parent = nil
	check("no Humanoid", string.find(reasons(Rig.describe(model)), "no Humanoid", 1, true) ~= nil)

	model = build()
	model.Parent = Instance.new("Folder")
	check("not under Workspace", string.find(reasons(Rig.describe(model)), "not under Workspace", 1, true) ~= nil)
end)

case("joints outside the standard fifteen are reported and left out", function()
	local model, parts = build()
	local sword = Instance.new("Part")
	sword.Name = "Sword"
	sword.Parent = model
	local grip = Instance.new("Motor6D")
	grip.Name = "Grip"
	grip.Part0 = parts.RightHand
	grip.Part1 = sword
	grip.Parent = parts.RightHand
	local description, scan = Rig.describe(model)
	check("the rig is still supported", description.supported, reasons(description))
	check(
		"the extra joint is reported",
		#description.extra_joints == 1 and string.find(description.extra_joints[1], "Grip") ~= nil,
		description.extra_joints[1]
	)
	check("and cannot be edited", scan.joints.Sword == nil and description.joint_count == 15)
end)

print(`{count - failures}/{count} rig checks passed`)
if failures > 0 then
	process.exit(1)
end
