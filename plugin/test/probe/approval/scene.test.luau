--!strict
-- What the probe accepts as the approved scene: subjects whole in the picture, only its own rig, and the camera as it is.
-- Run with: lune run plugin/test/probe/approval/scene.test.luau

local Kit = require("./kit")

local arm = Kit.arm
local buildClone = Kit.buildClone
local buildPlace = Kit.buildPlace
local CFrame = Kit.CFrame
local inspect = Kit.inspect
local Instance = Kit.Instance
local newSession = Kit.newSession
local Stage = Kit.Stage
local SUBJECT = Kit.SUBJECT
local Vector3 = Kit.Vector3
local viewOf = Kit.viewOf

local check, case, finish = Kit.suite("approval scene")
case("a subject that is whole in the picture is accepted", function()
	check("framed", Stage.framed(viewOf(SUBJECT), SUBJECT) == nil, Stage.framed(viewOf(SUBJECT), SUBJECT))
	local portrait = viewOf(SUBJECT, 2.4)
	portrait.width, portrait.height = 720, 1280
	check("framed in a tall viewport", Stage.framed(portrait, SUBJECT) == nil, Stage.framed(portrait, SUBJECT))
end)

for label, change in
	{
		["the camera is too close to show all of it"] = function(view: any)
			return viewOf(SUBJECT, 0.8), "top and bottom"
		end,
		["the subject is off to the side"] = function(view: any)
			view.cframe = view.cframe * CFrame.Angles(0, math.rad(40), 0)
			return view, "of the picture"
		end,
		["the subject is above the picture"] = function(view: any)
			view.cframe = view.cframe * CFrame.Angles(math.rad(-30), 0, 0)
			return view, "top and bottom"
		end,
		["the camera looks the other way"] = function(view: any)
			view.cframe = view.cframe * CFrame.Angles(0, math.pi, 0)
			return view, "not in front"
		end,
		["the camera is inside the subject"] = function(view: any)
			view.cframe = CFrame.new(SUBJECT.centre)
			return view, "not in front"
		end,
		["the camera is very far away"] = function(view: any)
			return viewOf(SUBJECT, 40), "too far"
		end,
		["the subject is a speck"] = function(view: any)
			return viewOf({ centre = SUBJECT.centre, radius = 0.2 }, 30), "too small"
		end,
		["the viewport is too narrow for it"] = function(view: any)
			view.width, view.height = 720, 1280
			return view, "sides"
		end,
		["the camera is tilted sideways"] = function(view: any)
			view.cframe = view.cframe * CFrame.Angles(0, 0, math.rad(10))
			return view, "tilted"
		end,
		["the field of view is very wide"] = function(view: any)
			view.fieldOfView = 120
			return view, "field of view"
		end,
		["the field of view is very narrow"] = function(view: any)
			view.fieldOfView = 5
			return view, "field of view"
		end,
		["the field of view is not a number"] = function(view: any)
			view.fieldOfView = 0 / 0
			return view, "field of view"
		end,
		["the viewport is tiny"] = function(view: any)
			view.width, view.height = 32, 18
			return view, "viewport"
		end,
		["the viewport is enormous"] = function(view: any)
			view.width = 20000
			return view, "viewport"
		end,
		["the viewport size is not whole pixels"] = function(view: any)
			view.height = 1080.5
			return view, "viewport"
		end,
	} :: { [string]: (view: any) -> (any, string) }
do
	case(`framing is refused when {label}`, function()
		local view, expected = change(viewOf(SUBJECT))
		local subject = if label == "the subject is a speck" then { centre = SUBJECT.centre, radius = 0.2 } else SUBJECT
		local reason = Stage.framed(view, subject)
		check("it is refused", reason ~= nil)
		check("the reason says why", reason ~= nil and string.find(reason, expected, 1, true) ~= nil, reason)
	end)
end

case("two observations are the same view only if nothing about the camera changed", function()
	local view = viewOf(SUBJECT)
	local function changed(alter: (copy: any) -> ()): boolean
		local copy = { cframe = view.cframe, fieldOfView = view.fieldOfView, width = view.width, height = view.height }
		alter(copy)
		return not Stage.same(view, copy)
	end
	check("identical values are the same view", not changed(function() end))
	check(
		"moved",
		changed(function(copy)
			copy.cframe = copy.cframe + Vector3.new(0.01, 0, 0)
		end)
	)
	check(
		"turned",
		changed(function(copy)
			copy.cframe = copy.cframe * CFrame.Angles(0, math.rad(0.5), 0)
		end)
	)
	check(
		"rolled",
		changed(function(copy)
			copy.cframe = copy.cframe * CFrame.Angles(0, 0, math.rad(0.5))
		end)
	)
	check(
		"field of view",
		changed(function(copy)
			copy.fieldOfView = 70.5
		end)
	)
	check(
		"viewport width",
		changed(function(copy)
			copy.width = 1919
		end)
	)
	check(
		"viewport height",
		changed(function(copy)
			copy.height = 1081
		end)
	)
	check(
		"unreadable",
		changed(function(copy)
			copy.cframe = nil
		end)
	)
end)

for label, change in
	{
		["the camera is upside down"] = function(view: any)
			view.cframe = view.cframe * CFrame.Angles(0, 0, math.pi)
			return view, SUBJECT, "upside down"
		end,
		["the camera points almost straight down, where tilt cannot be told from turning"] = function(view: any)
			-- Pitched 89 degrees down and rolled 45: its sideways direction is still nearly level.
			local above = SUBJECT.centre + Vector3.new(0, 16, 0)
			view.cframe = CFrame.new(above) * CFrame.Angles(math.rad(-89), 0, 0) * CFrame.Angles(0, 0, math.rad(45))
			return view, SUBJECT, "too steeply"
		end,
		["the camera points steeply up"] = function(view: any)
			local below = SUBJECT.centre + Vector3.new(0, -16, 0)
			view.cframe = CFrame.new(below) * CFrame.Angles(math.rad(75), 0, 0)
			return view, SUBJECT, "too steeply"
		end,
		["the subject touches the camera's near limit"] = function(view: any)
			-- A small sphere in the middle of the picture, closer than Studio draws.
			local near = { centre = view.cframe.Position + view.cframe.LookVector * 0.6, radius = 0.1 }
			return view, near, "too close"
		end,
	} :: { [string]: (view: any) -> (any, any, string) }
do
	case(`framing is refused when {label}`, function()
		local view, subject, expected = change(viewOf(SUBJECT))
		local reason = Stage.framed(view, subject)
		check("it is refused", reason ~= nil)
		check("the reason says why", reason ~= nil and string.find(reason, expected, 1, true) ~= nil, reason)
	end)
end

case("several spheres are held only if every one is whole in the picture", function()
	local view = viewOf(SUBJECT)
	local inside = {
		{ centre = SUBJECT.centre + Vector3.new(1, 0, 0), radius = 1 },
		{ centre = SUBJECT.centre + Vector3.new(-1, 2, 0), radius = 0.5 },
	}
	check("all inside", Stage.holds(view, inside) == nil, Stage.holds(view, inside))
	local stray = table.clone(inside)
	table.insert(stray, { centre = SUBJECT.centre + Vector3.new(60, 0, 0), radius = 0.5 })
	check("one far to the side", Stage.holds(view, stray) ~= nil)
	local behind = table.clone(inside)
	table.insert(behind, { centre = view.cframe.Position - view.cframe.LookVector * 5, radius = 0.5 })
	check("one behind the camera", Stage.holds(view, behind) ~= nil)
	local edge = table.clone(inside)
	table.insert(edge, { centre = SUBJECT.centre + Vector3.new(0, 7.2, 0), radius = 1 })
	check("one crossing the top edge", Stage.holds(view, edge) ~= nil)
	check("nothing to show proves nothing", Stage.holds(view, {}) ~= nil)
	local tilted = viewOf(SUBJECT)
	tilted.cframe = tilted.cframe * CFrame.Angles(0, 0, math.pi)
	check("an unusable view holds nothing", Stage.holds(tilted, inside) ~= nil)
end)

case("the fixture scene is accepted and described", function()
	local place = buildPlace()
	local scene, reason = inspect(place)
	check("accepted", scene ~= nil, reason)
	if scene then
		check("the rig is the probe's", scene.rig == place.rig)
		check("the subject has a size", scene.subject.radius > 3 and scene.subject.radius < 30, scene.subject.radius)
		check("the floor is the top of the baseplate", scene.floor == 0, scene.floor)
		check("no posed copy without a preview", scene.posed == nil)
		check("the description is stable", (inspect(place) :: any).fingerprint == scene.fingerprint)
	end
end)

case("only the rig the probe built is accepted", function()
	local place = buildPlace()
	check("no rig of its own", inspect(place, nil, { rig = "<nil>" }) == nil)
	-- An identical rig that the probe did not build, in place of its own.
	local twin = place.rig:Clone()
	place.rig.Parent = nil
	twin.Parent = place.root
	local scene, reason = inspect(place)
	check("a lookalike is refused", scene == nil, reason)
	-- The probe's own rig, with a lookalike beside it.
	place.rig.Parent = place.root
	check("a lookalike beside it is refused", inspect(place) == nil)
	twin.Parent = nil
	check("accepted again once it is gone", inspect(place) ~= nil)
	check("a rig that is not in the place is refused", inspect(place, nil, { rig = twin }) == nil)
end)

case("the preview's copy is accepted only as the rig's shape, shown, and nothing more", function()
	local place = buildPlace()
	local base = inspect(place) :: any
	local clone = buildClone(place)
	local scene, reason = inspect(place, clone)
	check("accepted with the copy named", scene ~= nil, reason)
	if scene then
		check("the copy does not alter the scene's description", scene.fingerprint == base.fingerprint)
		check(
			"each shown part of the copy is measured",
			scene.posed ~= nil and #scene.posed == 15,
			scene.posed and #scene.posed
		)
	end
	check("refused when the copy is not named", inspect(place) == nil)
	check("refused when a different instance is named", inspect(place, Instance.new("Model")) == nil)

	local function refusedAfter(label: string, alter: (copy: any) -> (), expected: string)
		local fresh = buildPlace()
		local copy = buildClone(fresh)
		alter(copy)
		local accepted, why = inspect(fresh, copy)
		check(label, accepted == nil and type(why) == "string" and string.find(why, expected, 1, true) ~= nil, why)
	end
	refusedAfter("something visible is added beneath it", function(copy)
		local sign = Instance.new("Part")
		sign.Name = "Sign"
		sign.Parent = copy
	end, "parts")
	refusedAfter("a picture is put on it", function(copy)
		Instance.new("Decal").Parent = copy.Head
	end, "Decal")
	refusedAfter("a mesh is put in it", function(copy)
		Instance.new("MeshPart").Parent = copy
	end, "MeshPart")
	refusedAfter("a script is put in it", function(copy)
		Instance.new("Script").Parent = copy
	end, "Script")
	refusedAfter("part of it is hidden", function(copy)
		copy.Head.Transparency = 1
	end, "not fully shown")
	refusedAfter("its root part is shown", function(copy)
		copy.HumanoidRootPart.Transparency = 0
	end, "visible")
	refusedAfter("a part of it is resized", function(copy)
		copy.Head.Size = Vector3.new(3, 3, 3)
	end, "not the size")
	refusedAfter("a part of it is missing", function(copy)
		copy.LeftFoot.Parent = nil
	end, "parts")
	refusedAfter("a limb is sunk into the baseplate", function(copy)
		copy.LeftFoot.CFrame = CFrame.new(0, 0.2, 0)
	end, "below the baseplate")
	refusedAfter("a limb is under the baseplate", function(copy)
		copy.RightHand.CFrame = CFrame.new(0, -10, 0)
	end, "below the baseplate")
	refusedAfter("a limb dips a hair into the baseplate", function(copy)
		copy.LeftFoot.CFrame = CFrame.new(0, 0.59, 0)
	end, "below the baseplate")
end)

case("the copy is measured where its pose puts it", function()
	local place = buildPlace()
	local clone = buildClone(place)
	clone.Head.CFrame = CFrame.new(40, 9, 0)
	local scene = inspect(place, clone) :: any
	local found = false
	for _, sphere in scene.posed do
		found = found or (sphere.centre.X == 40 and sphere.centre.Y == 9)
	end
	check("a moved part is measured at its new position", found)
end)

for label, alter in
	{
		["an unrelated part is in the place"] = function(place: any)
			local part = Instance.new("Part")
			part.Name = "House"
			part.Parent = place.root
			return "House"
		end,
		["an unrelated model is in the place"] = function(place: any)
			local model = Instance.new("Model")
			model.Name = "Avatar"
			model.Parent = place.root
			return "Avatar"
		end,
		["a script is in the place"] = function(place: any)
			Instance.new("Script").Parent = place.root
			return "Script"
		end,
		["a second camera is in the place"] = function(place: any)
			Instance.new("Camera").Parent = place.root
			return "Camera"
		end,
		["something is attached to the camera"] = function(place: any)
			local part = Instance.new("Part")
			part.Parent = place.camera
			return "camera has something attached"
		end,
		["the camera is not the place's own"] = function(place: any)
			place.camera = Instance.new("Camera")
			return "Camera"
		end,
		["the place has a sky"] = function(place: any)
			local sky = Instance.new("Sky")
			sky.Parent = place.lighting
			return "Sky"
		end,
		["the lighting has an effect in it"] = function(place: any)
			local effect = Instance.new("BloomEffect")
			effect.Parent = place.lighting
			return "lighting contains"
		end,
		["the lighting cannot be read"] = function(place: any)
			place.lighting = nil
			return "lighting could not be read"
		end,
		["the place has a custom material"] = function(place: any)
			local variant = Instance.new("MaterialVariant")
			variant.Name = "Glow"
			variant.Parent = place.materials
			return "custom material"
		end,
		["the materials cannot be read"] = function(place: any)
			place.materials = nil
			return "materials could not be read"
		end,
		["the baseplate is stood on its edge"] = function(place: any)
			-- Same centre and size, turned so that it rises through the scene.
			place.baseplate.CFrame = CFrame.new(0, -0.5, 0) * CFrame.Angles(0, 0, math.rad(80))
			return "turned or tilted"
		end,
		["the baseplate is tilted a little"] = function(place: any)
			place.baseplate.CFrame = CFrame.new(0, -0.5, 0) * CFrame.Angles(math.rad(2), 0, 0)
			return "turned or tilted"
		end,
		["the baseplate is turned about its axis"] = function(place: any)
			place.baseplate.CFrame = CFrame.new(0, -0.5, 0) * CFrame.Angles(0, math.rad(30), 0)
			return "turned or tilted"
		end,
		["the rig is missing"] = function(place: any)
			place.rig.Parent = nil
			return "not in the place"
		end,
		["the baseplate is missing"] = function(place: any)
			place.baseplate.Parent = nil
			return "no fixture baseplate"
		end,
		["the baseplate was resized"] = function(place: any)
			place.baseplate.Size = Vector3.new(128, 1, 128)
			return "baseplate"
		end,
		["the baseplate was moved"] = function(place: any)
			place.baseplate.CFrame = CFrame.new(0, 5, 0)
			return "baseplate"
		end,
		["the baseplate is see-through"] = function(place: any)
			place.baseplate.Transparency = 0.5
			return "baseplate"
		end,
		["something sits on the baseplate"] = function(place: any)
			Instance.new("Decal").Parent = place.baseplate
			return "baseplate"
		end,
		["the rig has a mesh part"] = function(place: any)
			Instance.new("MeshPart").Parent = place.rig
			return "MeshPart"
		end,
		["the rig has a picture on it"] = function(place: any)
			Instance.new("Decal").Parent = place.parts.Head
			return "Decal"
		end,
		["the rig has a script"] = function(place: any)
			Instance.new("Script").Parent = place.rig
			return "Script"
		end,
		["the rig wears an accessory"] = function(place: any)
			Instance.new("Accessory").Parent = place.rig
			return "Accessory"
		end,
		["the rig has a sound"] = function(place: any)
			Instance.new("Sound").Parent = place.parts.Head
			return "Sound"
		end,
		["a rig part is visible"] = function(place: any)
			place.parts.Head.Transparency = 0
			return "visible"
		end,
		["a rig part is partly visible"] = function(place: any)
			place.parts.LeftHand.Transparency = 0.5
			return "visible"
		end,
		["a rig part is missing"] = function(place: any)
			place.parts.LeftFoot.Parent = nil
			return "parts"
		end,
		["the rig has an extra part"] = function(place: any)
			local extra = Instance.new("Part")
			extra.Name = "Tail"
			extra.Transparency = 1
			extra.Parent = place.rig
			return "parts"
		end,
		["a rig part is renamed"] = function(place: any)
			place.parts.Head.Name = "Skull"
			return "Head"
		end,
		["a rig part is oversized"] = function(place: any)
			place.parts.UpperTorso.Size = Vector3.new(40, 40, 40)
			return "larger"
		end,
		["a rig part is nested in another"] = function(place: any)
			place.parts.LeftHand.Parent = place.parts.LeftLowerArm
			return "nested"
		end,
		["the rig has no humanoid"] = function(place: any)
			place.rig:FindFirstChildOfClass("Humanoid").Parent = nil
			return "Humanoid"
		end,
	} :: { [string]: (place: any) -> string }
do
	case(`the scene is refused when {label}`, function()
		local place = buildPlace()
		local expected = alter(place)
		local scene, reason = inspect(place)
		check("it is refused", scene == nil)
		check("the reason says why", type(reason) == "string" and string.find(reason, expected, 1, true) ~= nil, reason)
	end)
end

case("the scene's description changes when anything in it changes", function()
	local place = buildPlace()
	local before = (inspect(place) :: any).fingerprint
	place.parts.Head.CFrame = place.parts.Head.CFrame + Vector3.new(0, 0.5, 0)
	local moved = (inspect(place) :: any).fingerprint
	check("a moved part changes it", moved ~= before)
	place.parts.Head:FindFirstChildOfClass("Motor6D").Transform = CFrame.new(0, 0.1, 0)
	local posed = (inspect(place) :: any).fingerprint
	check("a posed joint changes it", posed ~= moved)
	place.baseplate.Reflectance = 0.5
	local shiny = (inspect(place) :: any).fingerprint
	check("the baseplate's look changes it", shiny ~= posed)
end)

case("a camera under the baseplate is refused for being there", function()
	local session = newSession()
	local subject = (inspect(session.place) :: any).subject
	-- In front of the rig and below the ground, the right way up, looking up at it.
	local distance = subject.radius * 2.6
	local slant = math.rad(45)
	local below = subject.centre + Vector3.new(0, -distance * math.sin(slant), -distance * math.cos(slant))
	session.view.cframe = CFrame.new(below) * CFrame.Angles(0, math.pi, 0) * CFrame.Angles(slant, 0, 0)
	check("the camera is under the ground", session.view.cframe.Position.Y < 0, session.view.cframe.Position.Y)
	check(
		"the view itself frames the rig",
		Stage.framed(session.view, subject) == nil,
		Stage.framed(session.view, subject)
	)
	local ok, why = arm(session)
	check("no approval", ok == false)
	check("the reason is the baseplate", string.find(why, "at or below the baseplate") ~= nil, why)
end)

finish()
