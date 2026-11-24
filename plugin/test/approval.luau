--!strict
-- Offline tests for what stands behind the capture gate in the probe build: the framing
-- proof (Stage), the scene rules (E2Scene) and a person's approval (Approval).
-- Run with: lune run plugin/test/approval.luau
--
-- Real here: Lune's instance model for the scene, and its vector and CFrame arithmetic
-- for the framing proof. Modelled: everything Studio would report about itself (which
-- tab is active, what is selected, the viewport's size, the terrain), which the tests
-- supply as plain values. Passing here is not verification in Studio.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Approval = require("../probe/Approval")
local E2Scene = require("../probe/E2Scene")
local FixtureGuard = require("../probe/FixtureGuard")
local Stage = require("../src/Stage")

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
		print(`FAIL [{name}] raised: {tostring(problem)}`)
	end
end

local FIXTURE_ID = "0123456789abcdef0123456789abcdef"
local OTHER_ID = "fedcba9876543210fedcba9876543210"

local PART_NAMES = {
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

-- A place shaped like the prepared fixture in screenshot mode: a camera, the baseplate
-- and the invisible synthetic rig.
local function buildPlace()
	local root = Instance.new("Folder")
	root.Name = "Workspace"
	local camera = Instance.new("Camera")
	camera.Parent = root
	local baseplate = Instance.new("Part")
	baseplate.Name = E2Scene.BASEPLATE_NAME
	baseplate.Size = Vector3.new(64, 1, 64)
	baseplate.CFrame = CFrame.new(0, -0.5, 0)
	baseplate.Parent = root

	local rig = Instance.new("Model")
	rig.Name = E2Scene.RIG_NAME
	local parts = {}
	for index, name in PART_NAMES do
		local part = Instance.new("Part")
		part.Name = name
		part.Size = Vector3.new(1, 1.2, 1)
		part.Transparency = 1
		part.CFrame = CFrame.new((index % 3) - 1, 0.5 + (index % 6), 0)
		part.Parent = rig
		parts[name] = part
	end
	for index = 2, #PART_NAMES do
		local motor = Instance.new("Motor6D")
		motor.Name = PART_NAMES[index] .. "Joint"
		motor.Part0 = parts.HumanoidRootPart
		motor.Part1 = parts[PART_NAMES[index]]
		motor.Transform = CFrame.new()
		motor.Parent = parts[PART_NAMES[index]]
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = rig
	local animator = Instance.new("Animator")
	animator.Parent = humanoid
	rig.Parent = root
	return { root = root, camera = camera, baseplate = baseplate, rig = rig, parts = parts }
end

-- A view that looks straight at the subject from in front, upright, with room to spare.
local function viewOf(subject: any, distanceFactor: number?): any
	local distance = subject.radius / math.sin(math.rad(35)) * (distanceFactor or 1.3)
	local position = subject.centre + Vector3.new(0, 0, -distance)
	-- Turned half way round, so that it faces the subject. (Lune's CFrame.lookAt does not
	-- rotate, so the direction is built from a plain rotation instead.)
	local cframe = CFrame.new(position) * CFrame.Angles(0, math.pi, 0)
	return { cframe = cframe, fieldOfView = 70, width = 1920, height = 1080 }
end

-- ---------------------------------------------------------------------------------------
-- Stage: the framing proof
-- ---------------------------------------------------------------------------------------

local SUBJECT = { centre = Vector3.new(0, 3, 0), radius = 5 }

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

-- ---------------------------------------------------------------------------------------
-- E2Scene: the scene rules
-- ---------------------------------------------------------------------------------------

case("the fixture scene is accepted and described", function()
	local place = buildPlace()
	local scene, reason = E2Scene.inspect(place.root, place.camera, nil)
	check("accepted", scene ~= nil, reason)
	if scene then
		check("the rig is identified", scene.rig == place.rig)
		check("the subject has a size", scene.subject.radius > 3 and scene.subject.radius < 30, scene.subject.radius)
		local again = E2Scene.inspect(place.root, place.camera, nil) :: any
		check("the description is stable", again.fingerprint == scene.fingerprint)
	end
end)

case("the preview's own clone, and only that exact instance, may stand in the scene", function()
	local place = buildPlace()
	local base = E2Scene.inspect(place.root, place.camera, nil) :: any
	local clone = Instance.new("Model")
	clone.Name = "MotionBridgePreview"
	local limb = Instance.new("Part")
	limb.Parent = clone
	clone.Parent = place.root
	local withClone, reason = E2Scene.inspect(place.root, place.camera, clone)
	check("accepted with the clone named", withClone ~= nil, reason)
	check(
		"the clone does not alter the scene's description",
		withClone ~= nil and withClone.fingerprint == base.fingerprint
	)
	check("refused when the clone is not named", E2Scene.inspect(place.root, place.camera, nil) == nil)
	local impostor = Instance.new("Model")
	impostor.Name = "MotionBridgePreview"
	check("refused when a different instance is named", E2Scene.inspect(place.root, place.camera, impostor) == nil)
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
			local script = Instance.new("Script")
			script.Parent = place.root
			return "Script"
		end,
		["there are two synthetic rigs"] = function(place: any)
			place.rig:Clone().Parent = place.root
			return E2Scene.RIG_NAME
		end,
		["a second camera is in the place"] = function(place: any)
			Instance.new("Camera").Parent = place.root
			return "Camera"
		end,
		["the rig is missing"] = function(place: any)
			place.rig.Parent = nil
			return "no synthetic rig"
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
		local scene, reason = E2Scene.inspect(place.root, place.camera, nil)
		check("it is refused", scene == nil)
		check("the reason says why", type(reason) == "string" and string.find(reason, expected, 1, true) ~= nil, reason)
	end)
end

case("the scene's description changes when anything in it moves", function()
	local place = buildPlace()
	local before = (E2Scene.inspect(place.root, place.camera, nil) :: any).fingerprint
	place.parts.Head.CFrame = place.parts.Head.CFrame + Vector3.new(0, 0.5, 0)
	local moved = (E2Scene.inspect(place.root, place.camera, nil) :: any).fingerprint
	check("a moved part changes it", moved ~= before)
	place.parts.Head:FindFirstChildOfClass("Motor6D").Transform = CFrame.new(0, 0.1, 0)
	local posed = (E2Scene.inspect(place.root, place.camera, nil) :: any).fingerprint
	check("a posed joint changes it", posed ~= moved)
end)

-- ---------------------------------------------------------------------------------------
-- Approval: a person's approval of one scene through one camera
-- ---------------------------------------------------------------------------------------

-- A probe session in the fixture, with everything as a person would have set it up.
local function newSession()
	local place = buildPlace()
	local marker = Instance.new("StringValue")
	marker.Name = FixtureGuard.MARKER_NAME
	marker.Value = FixtureGuard.MARKER_PREFIX .. FIXTURE_ID
	local session = {
		place = place,
		marker = marker,
		state = Approval.new(marker, FIXTURE_ID),
		-- What Studio would report; cases change these.
		armValue = FIXTURE_ID :: any,
		placeId = 0,
		gameId = 0,
		isEdit = true,
		viewportActive = true :: boolean?,
		selectionEmpty = true :: boolean?,
		terrainCells = 0 :: number?,
		camera = place.camera :: any,
		view = nil :: any,
		subject = nil :: any,
		foundMarker = marker :: any,
	}
	local scene = E2Scene.inspect(place.root, place.camera, nil) :: any
	session.view = viewOf(scene.subject)
	return session
end

local function observe(session: any): any
	local found = session.foundMarker
	local scene, sceneProblem =
		E2Scene.inspect(session.place.root, session.camera, if session.subject then session.subject.clone else nil)
	return {
		guard = {
			markerClass = if found then found.ClassName else nil,
			markerValue = if found then found.Value else nil,
			placeId = session.placeId,
			gameId = session.gameId,
			isEdit = session.isEdit,
		},
		marker = found,
		armValue = session.armValue,
		camera = session.camera,
		view = session.view,
		viewportActive = session.viewportActive,
		selectionEmpty = session.selectionEmpty,
		terrainCells = session.terrainCells,
		scene = scene,
		sceneProblem = sceneProblem,
		subject = session.subject,
	}
end

-- Starts a preview of the approved rig, as Preview would report it.
local function startPreview(session: any)
	local clone = Instance.new("Model")
	clone.Name = "MotionBridgePreview"
	clone.Parent = session.place.root
	session.subject = { model = session.place.rig, clone = clone }
end

local function approved(session: any): any
	local ok, why = Approval.arm(session.state, observe(session))
	check("approval is given", ok, why)
	return session
end

case("nothing is approved until a person arms the fixture", function()
	local session = newSession()
	local reason = Approval.refusal(session.state, observe(session), false)
	check("refused", reason ~= nil and string.find(reason, Approval.NEVER_GIVEN, 1, true) ~= nil, reason)
	startPreview(session)
	check("refused for a capture too", Approval.refusal(session.state, observe(session), true) ~= nil)
end)

case("an approved scene and camera allow a screenshot of the approved rig", function()
	local session = approved(newSession())
	check("screenshots are possible", Approval.refusal(session.state, observe(session), false) == nil)
	startPreview(session)
	local reason = Approval.refusal(session.state, observe(session), true)
	check("a screenshot of the rig's preview is allowed", reason == nil, reason)
	check("and again, while nothing changes", Approval.refusal(session.state, observe(session), true) == nil)
end)

for label, value in
	{
		["true"] = true,
		["the text 'true'"] = "true",
		["another fixture's id"] = OTHER_ID,
		["this id in capitals"] = string.upper(FIXTURE_ID),
		["this id with a space"] = FIXTURE_ID .. " ",
		["the whole marker value"] = FixtureGuard.MARKER_PREFIX .. FIXTURE_ID,
		["a number"] = 1,
		["nothing"] = "<nil>",
	} :: { [string]: any }
do
	case(`arming with {label} gives no approval`, function()
		local session = newSession()
		session.armValue = if value == "<nil>" then nil else value
		local ok, why = Approval.arm(session.state, observe(session))
		check("no approval", ok == false, why)
		check("a reason is given", type(why) == "string" and why ~= "")
		startPreview(session)
		check("no screenshot", Approval.refusal(session.state, observe(session), true) ~= nil)
	end)
end

case("approval is pinned to the fixture the probe was started in", function()
	-- A different, perfectly well-formed marker, armed with its own id.
	local session = newSession()
	local other = Instance.new("StringValue")
	other.Name = FixtureGuard.MARKER_NAME
	other.Value = FixtureGuard.MARKER_PREFIX .. OTHER_ID
	session.foundMarker = other
	session.armValue = OTHER_ID
	local ok, why = Approval.arm(session.state, observe(session))
	check("another fixture's marker is refused", ok == false, why)
	check("the reason names the fixture", string.find(why, "not the one the probe was started in") ~= nil, why)

	-- The same id on a new marker instance: the value is right, the marker is not the one.
	local replaced = newSession()
	local copy = Instance.new("StringValue")
	copy.Name = FixtureGuard.MARKER_NAME
	copy.Value = replaced.marker.Value
	replaced.foundMarker = copy
	local again, reason = Approval.arm(replaced.state, observe(replaced))
	check("a replaced marker is refused", again == false, reason)
	check("the reason names the marker", string.find(reason, "not the one the probe was started with") ~= nil, reason)
end)

for label, alter in
	{
		["the place is published"] = function(session: any)
			session.placeId = 123
		end,
		["a playtest is running"] = function(session: any)
			session.isEdit = false
		end,
		["the marker is gone"] = function(session: any)
			session.foundMarker = nil
		end,
		["a script tab is active"] = function(session: any)
			session.viewportActive = false
		end,
		["the active tab is unknown"] = function(session: any)
			session.viewportActive = nil
		end,
		["something is selected"] = function(session: any)
			session.selectionEmpty = false
		end,
		["the selection is unknown"] = function(session: any)
			session.selectionEmpty = nil
		end,
		["the place has terrain"] = function(session: any)
			session.terrainCells = 40
		end,
		["the terrain is unknown"] = function(session: any)
			session.terrainCells = nil
		end,
		["there is no camera"] = function(session: any)
			session.camera = nil
		end,
		["the camera cannot be read"] = function(session: any)
			session.view = nil
		end,
		["the camera is not framed on the rig"] = function(session: any)
			session.view.cframe = session.view.cframe * CFrame.Angles(0, math.rad(60), 0)
		end,
		["the camera is tilted"] = function(session: any)
			session.view.cframe = session.view.cframe * CFrame.Angles(0, 0, math.rad(8))
		end,
		["the field of view is extreme"] = function(session: any)
			session.view.fieldOfView = 110
		end,
		["the viewport is tiny"] = function(session: any)
			session.view.width, session.view.height = 40, 30
		end,
		["the place holds something else"] = function(session: any)
			local part = Instance.new("Part")
			part.Name = "Private"
			part.Parent = session.place.root
		end,
		["the rig is a visible one"] = function(session: any)
			session.place.parts.Head.Transparency = 0
		end,
		["a preview is already in progress"] = function(session: any)
			startPreview(session)
		end,
	} :: { [string]: (session: any) -> () }
do
	case(`arming gives no approval when {label}`, function()
		local session = newSession()
		alter(session)
		local ok, why = Approval.arm(session.state, observe(session))
		check("no approval", ok == false, why)
		check("a reason is given", type(why) == "string" and why ~= "")
		check("screenshots stay off", Approval.refusal(session.state, observe(session), false) ~= nil)
	end)
end

-- Each of these happens after approval, while a screenshot is pending. The screenshot
-- must be refused, and the approval must stay withdrawn even if the change is undone.
for label, change in
	{
		["the camera is moved"] = function(session: any)
			local original = session.view.cframe
			session.view.cframe = original + Vector3.new(0.5, 0, 0)
			return function()
				session.view.cframe = original
			end
		end,
		["the camera is turned"] = function(session: any)
			local original = session.view.cframe
			session.view.cframe = original * CFrame.Angles(0, math.rad(2), 0)
			return function()
				session.view.cframe = original
			end
		end,
		["the camera is rolled slightly"] = function(session: any)
			local original = session.view.cframe
			session.view.cframe = original * CFrame.Angles(0, 0, math.rad(0.5))
			return function()
				session.view.cframe = original
			end
		end,
		["the field of view changes"] = function(session: any)
			session.view.fieldOfView = 60
			return function()
				session.view.fieldOfView = 70
			end
		end,
		["the viewport is resized"] = function(session: any)
			session.view.width = 1600
			return function()
				session.view.width = 1920
			end
		end,
		["the camera is switched for another"] = function(session: any)
			local original = session.camera
			session.camera = Instance.new("Camera")
			return function()
				session.camera = original
			end
		end,
		["the camera is replaced by another in the same position"] = function(session: any)
			-- Everything about the view and the scene is identical; only the instance differs.
			local original = session.camera
			local replacement = Instance.new("Camera")
			original.Parent = nil
			replacement.Parent = session.place.root
			session.camera = replacement
			return function()
				replacement.Parent = nil
				original.Parent = session.place.root
				session.camera = original
			end
		end,
		["a script tab becomes active"] = function(session: any)
			session.viewportActive = false
			return function()
				session.viewportActive = true
			end
		end,
		["something is selected"] = function(session: any)
			session.selectionEmpty = false
			return function()
				session.selectionEmpty = true
			end
		end,
		["the fixture is unarmed"] = function(session: any)
			session.armValue = nil
			return function()
				session.armValue = FIXTURE_ID
			end
		end,
		["the arm attribute is changed to something else"] = function(session: any)
			session.armValue = OTHER_ID
			return function()
				session.armValue = FIXTURE_ID
			end
		end,
		["the marker is replaced"] = function(session: any)
			local original = session.foundMarker
			local copy = Instance.new("StringValue")
			copy.Name = original.Name
			copy.Value = original.Value
			session.foundMarker = copy
			return function()
				session.foundMarker = original
			end
		end,
		["the place is published"] = function(session: any)
			session.placeId = 99
			return function()
				session.placeId = 0
			end
		end,
		["a playtest starts"] = function(session: any)
			session.isEdit = false
			return function()
				session.isEdit = true
			end
		end,
		["something is added to the place"] = function(session: any)
			local part = Instance.new("Part")
			part.Name = "Intruder"
			part.Parent = session.place.root
			return function()
				part.Parent = nil
			end
		end,
		["a rig part is moved"] = function(session: any)
			local head = session.place.parts.Head
			local original = head.CFrame
			head.CFrame = original + Vector3.new(0, 0.25, 0)
			return function()
				head.CFrame = original
			end
		end,
		["the rig is made visible"] = function(session: any)
			session.place.parts.UpperTorso.Transparency = 0
			return function()
				session.place.parts.UpperTorso.Transparency = 1
			end
		end,
		["the rig is swapped for an identical one"] = function(session: any)
			local original = session.place.rig
			local twin = original:Clone()
			original.Parent = nil
			twin.Parent = session.place.root
			session.subject.model = twin
			return function()
				twin.Parent = nil
				original.Parent = session.place.root
				session.subject.model = original
			end
		end,
		["terrain appears"] = function(session: any)
			session.terrainCells = 3
			return function()
				session.terrainCells = 0
			end
		end,
		["the preview is of a different model"] = function(session: any)
			local original = session.subject.model
			session.subject.model = Instance.new("Model")
			return function()
				session.subject.model = original
			end
		end,
		["the preview has no clone"] = function(session: any)
			local clone = session.subject.clone
			session.subject = { model = session.subject.model, clone = nil }
			clone.Parent = nil
			return function()
				clone.Parent = session.place.root
				session.subject = { model = session.place.rig, clone = clone }
			end
		end,
		["there is no preview at all"] = function(session: any)
			local subject = session.subject
			subject.clone.Parent = nil
			session.subject = nil
			return function()
				subject.clone.Parent = session.place.root
				session.subject = subject
			end
		end,
	} :: { [string]: (session: any) -> () -> () }
do
	case(`a pending screenshot is refused and approval withdrawn when {label}`, function()
		local session = approved(newSession())
		startPreview(session)
		check("allowed before the change", Approval.refusal(session.state, observe(session), true) == nil)
		local undo = change(session)
		local reason = Approval.refusal(session.state, observe(session), true)
		check("refused once it has changed", reason ~= nil)
		check(
			"a reason is given",
			type(reason) == "string" and string.find(reason, "screenshots are off", 1, true) ~= nil,
			reason
		)
		undo()
		local after = Approval.refusal(session.state, observe(session), true)
		check("still refused after the change is undone", after ~= nil)
		check(
			"the refusal says how to re-approve",
			after ~= nil and string.find(after, "set it again", 1, true) ~= nil,
			after
		)
		check("screenshots are reported as off", Approval.refusal(session.state, observe(session), false) ~= nil)
	end)
end

case("asking whether screenshots are possible does not by itself withdraw approval", function()
	local session = approved(newSession())
	session.selectionEmpty = false
	check("reported as not possible right now", Approval.refusal(session.state, observe(session), false) ~= nil)
	session.selectionEmpty = true
	check("possible again once the cause is gone", Approval.refusal(session.state, observe(session), false) == nil)
	startPreview(session)
	check("and a screenshot is still allowed", Approval.refusal(session.state, observe(session), true) == nil)
end)

case("a withdrawn approval comes back only when a person arms again", function()
	local session = approved(newSession())
	Approval.disarm(session.state, "the preview was cancelled")
	local reason = Approval.refusal(session.state, observe(session), false)
	check(
		"refused after withdrawal",
		reason ~= nil and string.find(reason, "the preview was cancelled", 1, true) ~= nil,
		reason
	)
	startPreview(session)
	check("refused for a capture", Approval.refusal(session.state, observe(session), true) ~= nil)
	check("arming during the preview is refused", (Approval.arm(session.state, observe(session))) == false)
	session.subject.clone.Parent = nil
	session.subject = nil
	check("arming again gives approval", (Approval.arm(session.state, observe(session))) == true)
	check("screenshots are possible again", Approval.refusal(session.state, observe(session), false) == nil)
end)

case("re-arming records the camera as it is then, not as it was", function()
	local session = approved(newSession())
	local moved = viewOf((E2Scene.inspect(session.place.root, session.camera, nil) :: any).subject, 1.6)
	session.view = moved
	startPreview(session)
	check(
		"the moved camera is refused under the old approval",
		Approval.refusal(session.state, observe(session), true) ~= nil
	)
	session.subject.clone.Parent = nil
	session.subject = nil
	check("a person approves the new framing", (Approval.arm(session.state, observe(session))) == true)
	startPreview(session)
	check("the new framing is now the approved one", Approval.refusal(session.state, observe(session), true) == nil)
end)

print(`{count - failures}/{count} approval checks passed`)
if failures > 0 then
	process.exit(1)
end
