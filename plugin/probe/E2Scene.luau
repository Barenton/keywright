--!strict
-- The one scene a screenshot may be taken of: the prepared fixture's baseplate, under the
-- place's untouched default sky, and the single invisible synthetic rig the probe built
-- for this session. Nothing else may be in the place, and while a screenshot is taken,
-- the preview's own copy of that rig, shown where the rig stands.
--
-- The rig is invisible so that the only figure in a picture is the preview's copy. No rig
-- a person inserted, no avatar, mesh, image, script or sky can pass these rules, so no
-- content of a real place can be in a picture. This module only inspects; it creates and
-- changes nothing, and it takes every instance it looks at as an argument.

local E2Scene = {}

E2Scene.RIG_NAME = "MotionBridgeE2Rig"
E2Scene.BASEPLATE_NAME = "Baseplate"
E2Scene.BASEPLATE_SIZE = { 64, 1, 64 }
E2Scene.BASEPLATE_POSITION = { 0, -0.5, 0 }
-- A scene with more instances than this is refused without being read further.
E2Scene.MAX_INSTANCES = 400
-- Largest edge of a rig part, in studs.
E2Scene.MAX_PART_EDGE = 4
-- How much larger than the rig at rest the volume a person is asked to frame is.
E2Scene.POSE_ALLOWANCE = 1.5
-- How far below the top of the baseplate a part may reach before it counts as sunk into
-- it, where it could not be seen.
E2Scene.FLOOR_TOLERANCE = 0.05

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

-- Lighting settings that decide what the background and the light look like.
local LIGHTING = {
	"Ambient",
	"Brightness",
	"ClockTime",
	"ColorShift_Bottom",
	"ColorShift_Top",
	"EnvironmentDiffuseScale",
	"EnvironmentSpecularScale",
	"ExposureCompensation",
	"FogColor",
	"FogEnd",
	"FogStart",
	"GeographicLatitude",
	"GlobalShadows",
	"OutdoorAmbient",
}

type Sphere = { centre: Vector3, radius: number }

export type Place = {
	-- The place's workspace, its current camera and its Lighting service.
	root: Instance,
	camera: any,
	lighting: Instance?,
	-- The synthetic rig the probe built for this session. No other rig is accepted.
	rig: any,
	-- The preview's copy of that rig, if one is being shown.
	clone: any,
}

export type Scene = {
	rig: Model,
	fingerprint: string,
	-- The volume around the rig at rest that a person is asked to frame.
	subject: Sphere,
	-- Height of the top of the baseplate.
	floor: number,
	-- One sphere around each part of the shown copy, as posed, when there is a copy.
	posed: { Sphere }?,
}

local function isVector(value: any, expected: { number }): boolean
	return value.X == expected[1] and value.Y == expected[2] and value.Z == expected[3]
end

-- A property as text, for comparing one reading with a later one.
local function text(instance: any, property: string): string
	local ok, value = pcall(function()
		return instance[property]
	end)
	return if ok then tostring(value) else "?"
end

-- Checks that a model is the synthetic rig's shape and nothing more. `visible` says
-- whether its body must be shown (the preview's copy) or hidden (the rig itself).
-- Returns the parts by name, or nil and the reason.
local function rigParts(model: any, visible: boolean, what: string): ({ [string]: any }?, string?)
	local parts: { [string]: any } = {}
	local humanoids, animators = 0, 0
	for _, descendant: any in model:GetDescendants() do
		local class = descendant.ClassName
		if not RIG_CLASSES[class] then
			return nil, `{what} contains a {class}, which a synthetic rig never has`
		end
		if class == "Part" then
			if descendant.Parent ~= model then
				return nil, `{what} has a part nested inside another instance`
			elseif parts[descendant.Name] then
				return nil, `{what} has two parts named "{descendant.Name}"`
			end
			parts[descendant.Name] = descendant
			local size = descendant.Size
			local shown = visible and descendant.Name ~= "HumanoidRootPart"
			if descendant.Transparency ~= (if shown then 0 else 1) then
				return nil, `{what}'s "{descendant.Name}" is {if shown then "not fully shown" else "visible"}`
			elseif descendant.Shape.Name ~= "Block" then
				return nil, `{what}'s "{descendant.Name}" is not a plain block`
			elseif math.max(size.X, size.Y, size.Z) > E2Scene.MAX_PART_EDGE then
				return nil, `{what}'s "{descendant.Name}" is larger than a synthetic rig's parts`
			end
		elseif class == "Humanoid" then
			humanoids += 1
			if descendant.Parent ~= model then
				return nil, `{what}'s Humanoid is not directly inside it`
			end
		elseif class == "Animator" then
			animators += 1
		else
			-- Joints and attachments sit directly inside the part they belong to.
			local parent = descendant.Parent
			if not parent or parent.ClassName ~= "Part" or parent.Parent ~= model then
				return nil, `{what} has a {class} outside its parts`
			end
		end
	end
	local count = 0
	for _ in parts do
		count += 1
	end
	if count ~= #RIG_PARTS then
		return nil, `{what} has {count} parts, not the {#RIG_PARTS} of a synthetic rig`
	end
	for _, name in RIG_PARTS do
		if not parts[name] then
			return nil, `{what} has no "{name}"`
		end
	end
	if humanoids ~= 1 or animators > 1 then
		return nil, `{what} does not have exactly one Humanoid`
	end
	return parts, nil
end

local function describe(instance: any, path: string): string
	local class = instance.ClassName
	local line = `{path}|{class}`
	if class == "Part" then
		line ..= `|{tostring(instance.CFrame)}|{tostring(instance.Size)}|{instance.Transparency}`
	elseif class == "Motor6D" then
		line ..= `|{text(instance, "C0")}|{text(instance, "C1")}|{text(instance, "Transform")}`
	elseif class == "Attachment" then
		line ..= `|{text(instance, "CFrame")}`
	end
	return line
end

-- How far below its centre a box reaches.
local function reachDown(part: any): number
	local cframe, size = part.CFrame, part.Size
	return (
		math.abs(cframe.RightVector.Y) * size.X
		+ math.abs(cframe.UpVector.Y) * size.Y
		+ math.abs(cframe.LookVector.Y) * size.Z
	) / 2
end

-- Inspects the place. Returns the scene, or nil and the reason the place is not exactly
-- the approved scene.
function E2Scene.inspect(place: Place): (Scene?, string?)
	local camera, rig, clone = place.camera, place.rig, place.clone
	if rig == nil then
		return nil, "the probe has no synthetic rig of its own in this session"
	end

	-- The sky and anything else that draws a background live in Lighting.
	local lighting: any = place.lighting
	if lighting == nil then
		return nil, "the place's lighting could not be read"
	end
	local extra = lighting:GetChildren()[1]
	if extra then
		return nil, `the place's lighting contains "{extra.Name}" ({extra.ClassName}), which changes the picture`
	end

	local baseplate: any, foundRig, foundCamera = nil, false, false
	for _, child: any in place.root:GetChildren() do
		if camera ~= nil and child == camera and child.ClassName == "Camera" then
			foundCamera = true
			if #child:GetChildren() ~= 0 then
				return nil, "the camera has something attached to it"
			end
		elseif clone ~= nil and child == clone then
			continue
		elseif child.ClassName == "Terrain" then
			if #child:GetChildren() ~= 0 then
				return nil, "the terrain has something attached to it"
			end
		elseif child == rig and child.ClassName == "Model" then
			foundRig = true
		elseif child.ClassName == "Part" and child.Name == E2Scene.BASEPLATE_NAME and baseplate == nil then
			baseplate = child
		else
			return nil, `the place contains "{child.Name}" ({child.ClassName}), which is not part of the fixture scene`
		end
	end
	if not foundCamera then
		return nil, "the camera is not the place's own"
	elseif not baseplate then
		return nil, "the place has no fixture baseplate"
	elseif not foundRig then
		return nil, "the probe's synthetic rig is not in the place"
	end
	if
		#baseplate:GetChildren() ~= 0
		or not isVector(baseplate.Size, E2Scene.BASEPLATE_SIZE)
		or not isVector(baseplate.CFrame.Position, E2Scene.BASEPLATE_POSITION)
		or baseplate.Shape.Name ~= "Block"
		or baseplate.Transparency ~= 0
	then
		return nil, "the baseplate is not the one the fixture was prepared with"
	end
	local floor = baseplate.CFrame.Position.Y + baseplate.Size.Y / 2

	local parts, problem = rigParts(rig, false, "the rig")
	if not parts then
		return nil, problem
	end

	-- Everything a later reading is compared against: the baseplate's look, the lighting,
	-- and the whole of the rig.
	local lines = {
		`{describe(baseplate, baseplate.Name)}|{text(baseplate, "Color")}|{text(baseplate, "Material")}|{text(
			baseplate,
			"Reflectance"
		)}`,
	}
	for _, property in LIGHTING do
		table.insert(lines, `Lighting.{property}|{text(lighting, property)}`)
	end
	local function walk(instance: any, path: string): boolean
		table.insert(lines, describe(instance, path))
		if #lines > E2Scene.MAX_INSTANCES then
			return false
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

	-- A sphere around the rig at rest, enlarged, for a person to frame.
	local sum, count = nil :: any, 0
	for _, part in parts do
		sum = if sum then sum + part.CFrame.Position else part.CFrame.Position
		count += 1
	end
	local centre = sum / count
	local reach = 0
	for _, part in parts do
		reach = math.max(reach, (part.CFrame.Position - centre).Magnitude + part.Size.Magnitude / 2)
	end

	local posed: { Sphere }? = nil
	if clone ~= nil then
		-- The copy must be the rig's shape, shown, and nothing more, and every part of it
		-- must be where it can be seen: as posed, and not sunk into the baseplate.
		local shown, cloneProblem = rigParts(clone, true, "the preview")
		if not shown then
			return nil, cloneProblem
		end
		local spheres: { Sphere } = {}
		for name, part in shown do
			if tostring(part.Size) ~= tostring(parts[name].Size) then
				return nil, `the preview's "{name}" is not the size of the rig's`
			end
			if part.CFrame.Position.Y - reachDown(part) < floor - E2Scene.FLOOR_TOLERANCE then
				return nil, `the preview's "{name}" reaches below the baseplate`
			end
			if name ~= "HumanoidRootPart" then
				table.insert(spheres, { centre = part.CFrame.Position, radius = part.Size.Magnitude / 2 })
			end
		end
		posed = spheres
	end

	return {
		rig = rig,
		fingerprint = table.concat(lines, "\n"),
		subject = { centre = centre, radius = reach * E2Scene.POSE_ALLOWANCE },
		floor = floor,
		posed = posed,
	},
		nil
end

return E2Scene
