--!strict
-- The one scene a screenshot may be taken of: the prepared fixture's baseplate and a
-- single synthetic rig made of plain invisible blocks, with nothing else in the place.
--
-- The rig is invisible so that the only figure in a picture is the preview's own copy of
-- it, which stands exactly where the rig stands. No rig a person inserted, no avatar, no
-- mesh, image or script can pass these rules, so no content of a real place can be in a
-- picture. This module only inspects; it creates and changes nothing.

local E2Scene = {}

E2Scene.RIG_NAME = "MotionBridgeE2Rig"
E2Scene.BASEPLATE_NAME = "Baseplate"
E2Scene.BASEPLATE_SIZE = { 64, 1, 64 }
E2Scene.BASEPLATE_POSITION = { 0, -0.5, 0 }
-- A scene with more instances than this is refused without being read further.
E2Scene.MAX_INSTANCES = 400
-- Largest edge of a rig part, in studs.
E2Scene.MAX_PART_EDGE = 4
-- How much larger than the rig at rest the volume proved to be in the picture is, so
-- that limbs moved by a pose stay inside it.
E2Scene.POSE_ALLOWANCE = 1.5

local RIG_PARTS = {
	"HumanoidRootPart",
	"LowerTorso",
	"UpperTorso",
	"Head",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"LeftUpperLeg",
	"LeftLowerLeg",
	"LeftFoot",
	"RightUpperLeg",
	"RightLowerLeg",
	"RightFoot",
}

local RIG_CLASSES = {
	Part = true,
	Motor6D = true,
	AnimationConstraint = true,
	Attachment = true,
	Humanoid = true,
	Animator = true,
}

export type Scene = {
	rig: Model,
	fingerprint: string,
	subject: { centre: Vector3, radius: number },
}

local function isVector(value: any, expected: { number }): boolean
	return value.X == expected[1] and value.Y == expected[2] and value.Z == expected[3]
end

-- Returns nil when the model is the synthetic rig and nothing more, or the reason it is not.
local function rigProblem(rig: any): string?
	local parts: { [string]: any } = {}
	local humanoids, animators = 0, 0
	for _, descendant: any in rig:GetDescendants() do
		local class = descendant.ClassName
		if not RIG_CLASSES[class] then
			return `the rig contains a {class}, which a synthetic rig never has`
		end
		if class == "Part" then
			if descendant.Parent ~= rig then
				return "the rig has a part nested inside another instance"
			elseif parts[descendant.Name] then
				return `the rig has two parts named "{descendant.Name}"`
			end
			parts[descendant.Name] = descendant
			local size = descendant.Size
			if descendant.Transparency ~= 1 then
				return `the rig's "{descendant.Name}" is visible`
			elseif descendant.Shape.Name ~= "Block" then
				return `the rig's "{descendant.Name}" is not a plain block`
			elseif math.max(size.X, size.Y, size.Z) > E2Scene.MAX_PART_EDGE then
				return `the rig's "{descendant.Name}" is larger than a synthetic rig's parts`
			end
		elseif class == "Humanoid" then
			humanoids += 1
			if descendant.Parent ~= rig then
				return "the rig's Humanoid is not directly inside it"
			end
		elseif class == "Animator" then
			animators += 1
		else
			-- Joints and attachments sit directly inside the part they belong to.
			local parent = descendant.Parent
			if not parent or parent.ClassName ~= "Part" or parent.Parent ~= rig then
				return `the rig has a {class} outside its parts`
			end
		end
	end
	local count = 0
	for _ in parts do
		count += 1
	end
	if count ~= #RIG_PARTS then
		return `the rig has {count} parts, not the {#RIG_PARTS} of a synthetic rig`
	end
	for _, name in RIG_PARTS do
		if not parts[name] then
			return `the rig has no "{name}"`
		end
	end
	if humanoids ~= 1 or animators > 1 then
		return "the rig does not have exactly one Humanoid"
	end
	return nil
end

local function describe(instance: any, path: string): string
	local class = instance.ClassName
	local line = `{path}|{class}`
	if class == "Part" then
		line ..= `|{tostring(instance.CFrame)}|{tostring(instance.Size)}|{instance.Transparency}`
	elseif class == "Motor6D" then
		line ..= `|{tostring(instance.C0)}|{tostring(instance.C1)}|{tostring(instance.Transform)}`
	elseif class == "Attachment" then
		line ..= `|{tostring(instance.CFrame)}`
	end
	return line
end

-- Inspects the place's workspace. `camera` is the camera in use and `clone` the preview
-- clone that is allowed to stand in the scene, if one exists. Returns the scene, or nil
-- and the reason the place is not exactly the approved scene.
function E2Scene.inspect(root: Instance, camera: any, clone: Instance?): (Scene?, string?)
	local baseplate: any, rig: any = nil, nil
	for _, child: any in root:GetChildren() do
		if child == camera and child.ClassName == "Camera" then
			continue
		elseif clone ~= nil and child == clone then
			continue
		elseif child.ClassName == "Terrain" then
			continue
		elseif child.ClassName == "Part" and child.Name == E2Scene.BASEPLATE_NAME and baseplate == nil then
			baseplate = child
		elseif child.ClassName == "Model" and child.Name == E2Scene.RIG_NAME and rig == nil then
			rig = child
		else
			return nil, `the place contains "{child.Name}" ({child.ClassName}), which is not part of the fixture scene`
		end
	end
	if not baseplate then
		return nil, "the place has no fixture baseplate"
	elseif not rig then
		return nil, "the place has no synthetic rig"
	end
	if
		#baseplate:GetChildren() ~= 0
		or not isVector(baseplate.Size, E2Scene.BASEPLATE_SIZE)
		or not isVector(baseplate.CFrame.Position, E2Scene.BASEPLATE_POSITION)
		or baseplate.Shape.Name ~= "Block"
	then
		return nil, "the baseplate is not the one the fixture was prepared with"
	end
	local problem = rigProblem(rig)
	if problem then
		return nil, problem
	end

	local lines = { describe(baseplate, baseplate.Name) }
	local parts = {}
	local function walk(instance: any, path: string): boolean
		table.insert(lines, describe(instance, path))
		if #lines > E2Scene.MAX_INSTANCES then
			return false
		end
		if instance.ClassName == "Part" then
			table.insert(parts, instance)
		end
		for _, child in instance:GetChildren() do
			if not walk(child, `{path}/{child.Name}`) then
				return false
			end
		end
		return true
	end
	if not walk(rig, rig.Name) then
		return nil, "the scene has too many instances to be the fixture scene"
	end
	table.sort(lines)

	-- A sphere around the rig at rest, enlarged so that posed limbs stay inside it.
	local sum = parts[1].CFrame.Position
	for index = 2, #parts do
		sum += parts[index].CFrame.Position
	end
	local centre = sum / #parts
	local reach = 0
	for _, part in parts do
		reach = math.max(reach, (part.CFrame.Position - centre).Magnitude + part.Size.Magnitude / 2)
	end
	return {
		rig = rig,
		fingerprint = table.concat(lines, "\n"),
		subject = { centre = centre, radius = reach * E2Scene.POSE_ALLOWANCE },
	},
		nil
end

return E2Scene
