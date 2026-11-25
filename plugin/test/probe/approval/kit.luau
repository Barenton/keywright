--!strict
-- Shared by the approval suites in this folder: what they are run against, and the
-- helpers they use. Not a suite.
--
-- Offline tests for what stands behind the capture gate in the probe build: the framing
-- proof (Stage), the scene rules (E2Scene) and a person's approval (Approval).
--
-- Real here: Lune's instance model for the scene, and its vector and CFrame arithmetic
-- for the framing proof. Modelled: everything Studio would report about itself (which
-- tab is active, what is selected, the viewport's size, the terrain), which the tests
-- supply as plain values. Passing here is not verification in Studio.

-- The suite that is running, for helpers here that record checks as they go.
local active: ((name: string, condition: any, detail: any?) -> ())? = nil
local function check(name: string, condition: any, detail: any?)
	(active :: any)(name, condition, detail)
end

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Approval = require("../../../probe/Approval")
local E2Scene = require("../../../probe/E2Scene")
local FixtureGuard = require("../../../probe/FixtureGuard")
local Stage = require("../../../src/Preview/Stage")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

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

-- A place shaped like the prepared fixture in screenshot mode: a camera, default
-- lighting, the baseplate and the invisible synthetic rig the probe built.
local function buildPlace()
	local root = Instance.new("Folder")
	root.Name = "Workspace"
	local camera = Instance.new("Camera")
	camera.Parent = root
	local lighting = Instance.new("Folder")
	lighting.Name = "Lighting"
	local materials = Instance.new("Folder")
	materials.Name = "MaterialService"
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
		part.CFrame = CFrame.new((index % 3) - 1, 1 + (index % 6), 0)
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
	return {
		root = root,
		camera = camera,
		lighting = lighting,
		materials = materials,
		baseplate = baseplate,
		rig = rig,
		parts = parts,
	}
end

-- The preview's copy of the rig as Preview shows it: the same shape, visible apart from
-- its root part, standing in the place.
local function buildClone(place: any): any
	local clone = place.rig:Clone()
	clone.Name = "KeywrightPreview"
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = if descendant.Name == "HumanoidRootPart" then 1 else 0
		end
	end
	clone.Parent = place.root
	return clone
end

local function inspect(place: any, clone: any?, overrides: { [string]: any }?): (any, string?)
	local request: { [string]: any } = {
		root = place.root,
		camera = place.camera,
		lighting = place.lighting,
		materials = place.materials,
		rig = place.rig,
		clone = clone,
	}
	for key, value in overrides or {} do
		request[key] = if value == "<nil>" then nil else value
	end
	return E2Scene.inspect(request :: any)
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

local Kit = {}

-- A suite's own count of checks: `check` records one, `case` runs a group of them and
-- counts one that raises, `finish` prints the tally and fails the run if any failed.
function Kit.suite(
	label: string
): ((name: string, condition: any, detail: any?) -> (), (name: string, run: () -> ()) -> (), () -> ())
	local failures, count, current = 0, 0, ""
	local function suiteCheck(name: string, condition: any, detail: any?)
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
	local function finish()
		print(`{count - failures}/{count} {label} checks passed`)
		if failures > 0 then
			process.exit(1)
		end
	end
	active = suiteCheck
	return suiteCheck, case, finish
end

-- ---------------------------------------------------------------------------------------
-- E2Scene: the scene rules
-- ---------------------------------------------------------------------------------------

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
		state = Approval.new(marker, FIXTURE_ID, place.rig),
		-- What the person types into the panel.
		typed = FIXTURE_ID :: any,
		-- What Studio would report; cases change these.
		placeId = 0,
		gameId = 0,
		isEdit = true,
		viewportActive = true :: boolean?,
		selectionEmpty = true :: boolean?,
		terrainCells = 0 :: number?,
		watching = true :: boolean?,
		camera = place.camera :: any,
		view = nil :: any,
		subject = nil :: any,
		foundMarker = marker :: any,
	}
	session.view = viewOf((inspect(place) :: any).subject)
	return session
end

local function observe(session: any): any
	local found = session.foundMarker
	local place = session.place
	local scene, sceneProblem = E2Scene.inspect({
		root = place.root,
		camera = session.camera,
		lighting = place.lighting,
		materials = place.materials,
		rig = session.state.rig,
		clone = if session.subject then session.subject.clone else nil,
	} :: any)
	return {
		guard = {
			markerClass = if found then found.ClassName else nil,
			markerValue = if found then found.Value else nil,
			placeId = session.placeId,
			gameId = session.gameId,
			isEdit = session.isEdit,
		},
		marker = found,
		camera = session.camera,
		view = session.view,
		viewportActive = session.viewportActive,
		selectionEmpty = session.selectionEmpty,
		terrainCells = session.terrainCells,
		watching = session.watching,
		scene = scene,
		sceneProblem = sceneProblem,
		subject = session.subject,
	}
end

-- Starts a preview of the probe's rig, as Preview would report it once its copy is shown.
local function startPreview(session: any)
	session.subject = { model = session.place.rig, clone = buildClone(session.place) }
end

local function endPreview(session: any)
	if session.subject and session.subject.clone then
		session.subject.clone.Parent = nil
	end
	session.subject = nil
end

local function arm(session: any): (boolean, string)
	return Approval.arm(session.state, observe(session), session.typed)
end

local function approved(session: any): any
	local ok, why = arm(session)
	check("approval is given", ok, why)
	return session
end

Kit.buildPlace = buildPlace
Kit.buildClone = buildClone
Kit.inspect = inspect
Kit.viewOf = viewOf
Kit.newSession = newSession
Kit.observe = observe
Kit.startPreview = startPreview
Kit.endPreview = endPreview
Kit.arm = arm
Kit.approved = approved
Kit.process = process
Kit.roblox = roblox
Kit.Approval = Approval
Kit.E2Scene = E2Scene
Kit.FixtureGuard = FixtureGuard
Kit.Stage = Stage
Kit.Instance = Instance
Kit.CFrame = CFrame
Kit.Vector3 = Vector3
Kit.FIXTURE_ID = FIXTURE_ID
Kit.OTHER_ID = OTHER_ID
Kit.PART_NAMES = PART_NAMES
Kit.SUBJECT = SUBJECT

return Kit
