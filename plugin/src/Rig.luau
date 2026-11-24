--!strict
-- Rig inspection for R15 characters. A joint is a Motor6D or an AnimationConstraint;
-- both are read through the same properties and neither is ever written here.

local Errors = require("./Errors")

local Rig = {}

export type Joint = {
	name: string, -- name of the driven part; this is how poses address the joint
	jointName: string,
	instance: Instance,
	class: "Motor6D" | "AnimationConstraint",
	part0: BasePart,
	part1: BasePart,
}

Rig.ROOT = "HumanoidRootPart"

-- Driven part -> parent part for the 15 standard R15 joints.
Rig.R15_PARENTS = {
	LowerTorso = "HumanoidRootPart",
	UpperTorso = "LowerTorso",
	Head = "UpperTorso",
	LeftUpperArm = "UpperTorso",
	LeftLowerArm = "LeftUpperArm",
	LeftHand = "LeftLowerArm",
	RightUpperArm = "UpperTorso",
	RightLowerArm = "RightUpperArm",
	RightHand = "RightLowerArm",
	LeftUpperLeg = "LowerTorso",
	LeftLowerLeg = "LeftUpperLeg",
	LeftFoot = "LeftLowerLeg",
	RightUpperLeg = "LowerTorso",
	RightLowerLeg = "RightUpperLeg",
	RightFoot = "RightLowerLeg",
} :: { [string]: string }

-- stylua: ignore
Rig.R15_ORDER = {
	"LowerTorso", "UpperTorso", "Head",
	"LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
	"RightUpperLeg", "RightLowerLeg", "RightFoot",
}

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

-- The wire form of a transform: position in studs, rotation as Euler XYZ in degrees.
function Rig.encode(cframe: CFrame): { position: { number }, rotation: { number } }
	local rx, ry, rz = cframe:ToEulerAnglesXYZ()
	local position = cframe.Position
	return {
		position = { round(position.X, 4), round(position.Y, 4), round(position.Z, 4) },
		rotation = { round(math.deg(rx), 3), round(math.deg(ry), 3), round(math.deg(rz), 3) },
	}
end

function Rig.decode(position: { number }?, rotation: { number }?): CFrame
	local p = position or { 0, 0, 0 }
	local r = rotation or { 0, 0, 0 }
	return CFrame.new(p[1], p[2], p[3]) * CFrame.fromEulerAnglesXYZ(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
end

local function jointParts(instance: Instance): (BasePart?, BasePart?)
	-- Part0 and Part1 exist on Motor6D and, as read-only aliases, on AnimationConstraint.
	local ok, part0, part1 = pcall(function()
		return (instance :: any).Part0, (instance :: any).Part1
	end)
	if ok and part0 and part1 then
		return part0, part1
	end
	if instance:IsA("AnimationConstraint") then
		local a0, a1 = instance.Attachment0, instance.Attachment1
		local p0 = a0 and a0.Parent
		local p1 = a1 and a1.Parent
		if p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart") then
			return p0, p1
		end
	end
	return nil, nil
end

-- Rest transforms, read the same way for both joint classes.
function Rig.rest(joint: Joint): (CFrame, CFrame)
	local ok, c0, c1 = pcall(function()
		return (joint.instance :: any).C0, (joint.instance :: any).C1
	end)
	if ok and typeof(c0) == "CFrame" and typeof(c1) == "CFrame" then
		return c0, c1
	end
	local constraint = joint.instance :: AnimationConstraint
	return (constraint.Attachment0 :: Attachment).CFrame, (constraint.Attachment1 :: Attachment).CFrame
end

function Rig.getTransform(joint: Joint): CFrame
	return (joint.instance :: any).Transform
end

function Rig.isKinematic(joint: Joint): boolean
	if joint.class == "AnimationConstraint" then
		return (joint.instance :: AnimationConstraint).IsKinematic
	end
	return true
end

export type Scan = {
	joints: { [string]: Joint },
	extras: { string },
	problems: { string },
}

function Rig.scan(model: Model): Scan
	local joints: { [string]: Joint } = {}
	local extras: { string } = {}
	local problems: { string } = {}
	for _, instance in model:GetDescendants() do
		local class: ("Motor6D" | "AnimationConstraint")? = if instance:IsA("Motor6D")
			then "Motor6D"
			elseif instance:IsA("AnimationConstraint") then "AnimationConstraint"
			else nil
		if not class then
			continue
		end
		local part0, part1 = jointParts(instance)
		if not part0 or not part1 then
			table.insert(extras, instance:GetFullName())
			continue
		end
		local name = part1.Name
		if Rig.R15_PARENTS[name] == part0.Name and part0:IsDescendantOf(model) and part1:IsDescendantOf(model) then
			if joints[name] then
				table.insert(problems, `Two joints drive "{name}".`)
			else
				joints[name] = {
					name = name,
					jointName = instance.Name,
					instance = instance,
					class = class,
					part0 = part0,
					part1 = part1,
				}
			end
		else
			table.insert(extras, `{instance.Name} ({part0.Name} -> {part1.Name})`)
		end
	end
	return { joints = joints, extras = extras, problems = problems }
end

export type Description = {
	name: string,
	rig_type: string,
	supported: boolean,
	reasons: { string },
	joint_count: number,
	joint_classes: { [string]: number },
	non_kinematic_joints: { string },
	extra_joints: { string },
	joints: { any }?,
}

function Rig.describe(model: Model, detail: boolean?): (Description, Scan)
	local scan = Rig.scan(model)
	local reasons = table.clone(scan.problems)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rigType = "Unknown"
	if not humanoid then
		table.insert(reasons, "The model has no Humanoid.")
	else
		rigType = humanoid.RigType.Name
		if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
			table.insert(reasons, `Rig type is {rigType}; only R15 is supported.`)
		end
	end
	if not model:IsDescendantOf(workspace) then
		table.insert(reasons, "The model is not under Workspace.")
	end

	local seen: { [string]: number } = {}
	for _, instance in model:GetDescendants() do
		if instance:IsA("BasePart") and (Rig.R15_PARENTS[instance.Name] or instance.Name == Rig.ROOT) then
			seen[instance.Name] = (seen[instance.Name] or 0) + 1
		end
	end
	for name, count in seen do
		if count > 1 then
			table.insert(reasons, `{count} parts are named "{name}".`)
		end
	end

	local classes: { [string]: number } = {}
	local nonKinematic: { string } = {}
	local count = 0
	for _, name in Rig.R15_ORDER do
		local joint = scan.joints[name]
		if not joint then
			table.insert(reasons, `No joint drives "{name}" from "{Rig.R15_PARENTS[name]}".`)
			continue
		end
		count += 1
		classes[joint.class] = (classes[joint.class] or 0) + 1
		if not Rig.isKinematic(joint) then
			table.insert(nonKinematic, name)
		end
	end

	local description: Description = {
		name = model.Name,
		rig_type = rigType,
		supported = #reasons == 0,
		reasons = reasons,
		joint_count = count,
		joint_classes = classes,
		non_kinematic_joints = nonKinematic,
		extra_joints = scan.extras,
	}
	if detail then
		local list = {}
		for _, name in Rig.R15_ORDER do
			local joint = scan.joints[name]
			if joint then
				local c0, c1 = Rig.rest(joint)
				local size = joint.part1.Size
				table.insert(list, {
					name = name,
					parent = joint.part0.Name,
					joint_name = joint.jointName,
					class = joint.class,
					kinematic = Rig.isKinematic(joint),
					c0 = Rig.encode(c0),
					c1 = Rig.encode(c1),
					size = { size.X, size.Y, size.Z },
				})
			end
		end
		description.joints = list
	end
	return description, scan
end

-- Fails with UNSUPPORTED_RIG unless the model is a rig Motion Bridge can address unambiguously.
function Rig.require(model: Model): Scan
	local description, scan = Rig.describe(model)
	if not description.supported then
		Errors.throw(
			"UNSUPPORTED_RIG",
			table.concat(description.reasons, " "),
			"Select a standard R15 character under Workspace."
		)
	end
	return scan
end

-- Part names from the root part down to the given driven part.
function Rig.chain(name: string): { string }
	local chain = { name }
	local current = name
	while Rig.R15_PARENTS[current] do
		current = Rig.R15_PARENTS[current]
		table.insert(chain, 1, current)
	end
	return chain
end

return Rig
