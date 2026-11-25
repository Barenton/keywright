--!strict
-- A block R15 rig for the offline suites, built from Lune's instances. Not a suite.
--
-- The offsets are close to a real R15 rig's, including what makes one awkward to
-- reach with: each knee and elbow sits a little off the line of its limb, and each foot
-- reaches forward of its ankle. A solver that only works on a straight chain fails here.

local roblox = require("@lune/roblox") :: any

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local BlockRig = {}

-- { joint, parent, driven, C0 position, C1 position, size }
BlockRig.JOINTS = {
	{ "Root", "HumanoidRootPart", "LowerTorso", { 0, -0.2, 0 }, { 0, -0.2, 0 }, { 2, 0.4, 1 } },
	{ "Waist", "LowerTorso", "UpperTorso", { 0, 0.2, 0 }, { 0, -0.8, 0 }, { 2, 1.6, 1 } },
	{ "Neck", "UpperTorso", "Head", { 0, 0.8, 0 }, { 0, -0.6, 0 }, { 1.2, 1.2, 1.2 } },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm", { -1, 0.5, 0 }, { 0.5, 0.4, 0 }, { 1, 1.2, 1 } },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm", { 0, -0.55, 0.05 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "LeftWrist", "LeftLowerArm", "LeftHand", { 0, -0.6, 0 }, { 0, 0.15, 0 }, { 1, 0.3, 1 } },
	{ "RightShoulder", "UpperTorso", "RightUpperArm", { 1, 0.5, 0 }, { -0.5, 0.4, 0 }, { 1, 1.2, 1 } },
	{ "RightElbow", "RightUpperArm", "RightLowerArm", { 0, -0.55, 0.05 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "RightWrist", "RightLowerArm", "RightHand", { 0, -0.6, 0 }, { 0, 0.15, 0 }, { 1, 0.3, 1 } },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg", { -0.5, -0.2, 0 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg", { 0, -0.55, -0.05 }, { 0, 0.65, 0 }, { 1, 1.2, 1 } },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot", { 0, -0.6, 0 }, { 0, 0.15, 0.25 }, { 1, 0.3, 1.5 } },
	{ "RightHip", "LowerTorso", "RightUpperLeg", { 0.5, -0.2, 0 }, { 0, 0.6, 0 }, { 1, 1.2, 1 } },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg", { 0, -0.55, -0.05 }, { 0, 0.65, 0 }, { 1, 1.2, 1 } },
	{ "RightAnkle", "RightLowerLeg", "RightFoot", { 0, -0.6, 0 }, { 0, 0.15, 0.25 }, { 1, 0.3, 1.5 } },
}

-- The rig, standing somewhere arbitrary and turned, as a Model.
function BlockRig.build(): any
	local model = Instance.new("Model")
	model.Name = "BlockRig"
	local parts: { [string]: any } = {}
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(40, 12, -80) * CFrame.Angles(0, math.rad(35), 0)
	root.Parent = model
	parts.HumanoidRootPart = root
	for _, entry in BlockRig.JOINTS do
		local part = Instance.new("Part")
		part.Name = entry[3]
		part.Size = Vector3.new(entry[6][1], entry[6][2], entry[6][3])
		part.Parent = model
		parts[entry[3]] = part
	end
	for _, entry in BlockRig.JOINTS do
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

return BlockRig
