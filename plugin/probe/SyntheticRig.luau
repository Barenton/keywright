--!strict
-- Builds a disposable R15-shaped rig for Phase 0 probes. The geometry is identical for
-- both joint classes, so any difference in behaviour comes from the joint class alone.

local SyntheticRig = {}

export type JointClass = "Motor6D" | "AnimationConstraint"

local SIZES: { [string]: Vector3 } = {
	HumanoidRootPart = Vector3.new(2, 2, 1),
	LowerTorso = Vector3.new(2, 0.4, 1),
	UpperTorso = Vector3.new(2, 1.6, 1),
	Head = Vector3.new(1.2, 1.2, 1.2),
	LeftUpperArm = Vector3.new(1, 1.2, 1),
	LeftLowerArm = Vector3.new(1, 1.2, 1),
	LeftHand = Vector3.new(1, 0.3, 1),
	RightUpperArm = Vector3.new(1, 1.2, 1),
	RightLowerArm = Vector3.new(1, 1.2, 1),
	RightHand = Vector3.new(1, 0.3, 1),
	LeftUpperLeg = Vector3.new(1, 1.2, 1),
	LeftLowerLeg = Vector3.new(1, 1.2, 1),
	LeftFoot = Vector3.new(1, 0.3, 1),
	RightUpperLeg = Vector3.new(1, 1.2, 1),
	RightLowerLeg = Vector3.new(1, 1.2, 1),
	RightFoot = Vector3.new(1, 0.3, 1),
}

-- { joint name, parent part, driven part, C0 in parent, C1 in driven part }
local JOINTS: { { any } } = {
	{ "Root", "HumanoidRootPart", "LowerTorso", Vector3.new(0, -1, 0), Vector3.new(0, -0.2, 0) },
	{ "Waist", "LowerTorso", "UpperTorso", Vector3.new(0, 0.2, 0), Vector3.new(0, -0.8, 0) },
	{ "Neck", "UpperTorso", "Head", Vector3.new(0, 0.8, 0), Vector3.new(0, -0.6, 0) },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm", Vector3.new(-1, 0.5, 0), Vector3.new(0.5, 0.4, 0) },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm", Vector3.new(0, -0.6, 0), Vector3.new(0, 0.6, 0) },
	{ "LeftWrist", "LeftLowerArm", "LeftHand", Vector3.new(0, -0.6, 0), Vector3.new(0, 0.15, 0) },
	{ "RightShoulder", "UpperTorso", "RightUpperArm", Vector3.new(1, 0.5, 0), Vector3.new(-0.5, 0.4, 0) },
	{ "RightElbow", "RightUpperArm", "RightLowerArm", Vector3.new(0, -0.6, 0), Vector3.new(0, 0.6, 0) },
	{ "RightWrist", "RightLowerArm", "RightHand", Vector3.new(0, -0.6, 0), Vector3.new(0, 0.15, 0) },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg", Vector3.new(-0.5, -0.2, 0), Vector3.new(0, 0.6, 0) },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg", Vector3.new(0, -0.6, 0), Vector3.new(0, 0.6, 0) },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot", Vector3.new(0, -0.6, 0), Vector3.new(0, 0.15, 0) },
	{ "RightHip", "LowerTorso", "RightUpperLeg", Vector3.new(0.5, -0.2, 0), Vector3.new(0, 0.6, 0) },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg", Vector3.new(0, -0.6, 0), Vector3.new(0, 0.6, 0) },
	{ "RightAnkle", "RightLowerLeg", "RightFoot", Vector3.new(0, -0.6, 0), Vector3.new(0, 0.15, 0) },
}

function SyntheticRig.build(class: JointClass, name: string, origin: CFrame): Model
	local model = Instance.new("Model")
	model.Name = name

	local parts: { [string]: Part } = {}
	for partName, size in SIZES do
		local part = Instance.new("Part")
		part.Name = partName
		part.Size = size
		part.Anchored = partName == "HumanoidRootPart"
		part.CanCollide = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Transparency = if partName == "HumanoidRootPart" then 1 else 0
		part.Parent = model
		parts[partName] = part
	end
	parts.HumanoidRootPart.CFrame = origin
	model.PrimaryPart = parts.HumanoidRootPart

	for _, entry in JOINTS do
		local jointName, parentName, drivenName, c0Position, c1Position =
			entry[1], entry[2], entry[3], entry[4], entry[5]
		local part0, part1 = parts[parentName], parts[drivenName]
		local c0, c1 = CFrame.new(c0Position), CFrame.new(c1Position)
		part1.CFrame = part0.CFrame * c0 * c1:Inverse()

		if class == "Motor6D" then
			local motor = Instance.new("Motor6D")
			motor.Name = jointName
			motor.Part0 = part0
			motor.Part1 = part1
			motor.C0 = c0
			motor.C1 = c1
			motor.Parent = part1
		else
			local attachment0 = Instance.new("Attachment")
			attachment0.Name = jointName .. "RigAttachment"
			attachment0.CFrame = c0
			attachment0.Parent = part0
			local attachment1 = Instance.new("Attachment")
			attachment1.Name = jointName .. "RigAttachment"
			attachment1.CFrame = c1
			attachment1.Parent = part1
			local constraint = Instance.new("AnimationConstraint")
			constraint.Name = jointName
			constraint.Attachment0 = attachment0
			constraint.Attachment1 = attachment1
			constraint.Parent = part1
		end
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.Parent = model
	local animator = Instance.new("Animator")
	animator.Parent = humanoid

	model.Parent = workspace
	return model
end

return SyntheticRig
