--!strict
-- Entry point of the probe build. It acts only inside a disposable fixture (see
-- FixtureGuard), so loading it while any other place is open has no effect.
--
-- A prepared fixture carries no connection details. The probe connects only when a
-- person has added the Port and PairingCode attributes to the fixture marker.
--
-- The probe runs in one of two modes, chosen by the marker when the plugin loads:
--
--   Screenshot mode, when the marker already has the arm attribute (with any value).
--   Only the ordinary methods are offered. The experiment probes, which drive undo and
--   redo and reset the undo history, are not loaded at all. Screenshots become possible
--   once a person approves the scene and camera (see Approval).
--
--   Experiment mode, otherwise. The experiment probes are offered and the capture gate
--   is never opened, so no screenshot can be taken.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local FixtureGuard = require("./FixtureGuard")

-- What the guard is told about the open place, read afresh each time it is asked.
local function observe(): (FixtureGuard.Observation, Instance?)
	local found = ServerStorage:FindFirstChild(FixtureGuard.MARKER_NAME)
	return {
		markerClass = if found then found.ClassName else nil,
		markerValue = if found and found:IsA("StringValue") then found.Value else nil,
		placeId = game.PlaceId,
		gameId = game.GameId,
		isEdit = RunService:IsEdit(),
	},
		found
end

local observation, marker = observe()
local allowed, detail = FixtureGuard.check(observation)
if not allowed or not marker then
	return
end

local port = marker:GetAttribute("Port")
local code = marker:GetAttribute("PairingCode")
if type(port) ~= "number" or type(code) ~= "string" then
	print(`[MotionBridgeProbe] Fixture {detail} recognised. No connection is configured, so nothing will run.`)
	return
end

local Connection = require("../src/Connection")
local Handlers = require("../src/Handlers")
local Preview = require("../src/Preview")

local screenshotMode = marker:GetAttribute(FixtureGuard.ARM_ATTRIBUTE) ~= nil
local methods, registry = Handlers.create()
local signals: { RBXScriptConnection } = {}
local withdraw: ((reason: string) -> ())? = nil

if screenshotMode then
	local Selection = game:GetService("Selection")
	local Approval = require("./Approval")
	local E2Scene = require("./E2Scene")
	local SyntheticRig = require("./SyntheticRig")

	-- The synthetic rig is the only thing a screenshot may be of. It is built once,
	-- invisible, so that the only figure in a picture is the preview's own copy of it.
	if not workspace:FindFirstChild(E2Scene.RIG_NAME) then
		local rig = SyntheticRig.build("Motor6D", E2Scene.RIG_NAME, CFrame.new(0, 3.7, 0))
		for _, descendant in rig:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Transparency = 1
			end
		end
	end

	-- Approval is pinned to this marker instance and this fixture id.
	local state = Approval.new(marker, detail)
	local fixtureId = detail

	-- Everything the approval rules look at, read afresh. Nothing here writes anything.
	local function look(): Approval.Observation
		local guard, found = observe()
		local camera = workspace.CurrentCamera
		local view = nil
		pcall(function()
			view = {
				cframe = camera.CFrame,
				fieldOfView = camera.FieldOfView,
				width = camera.ViewportSize.X,
				height = camera.ViewportSize.Y,
			}
		end)
		local tabKnown, activeScript = pcall(function()
			return game:GetService("StudioService").ActiveScript
		end)
		local selectionKnown, selected = pcall(function()
			return #Selection:Get()
		end)
		local terrainKnown, cells = pcall(function()
			return workspace.Terrain:CountCells()
		end)
		local subject = Preview.subject()
		local sceneKnown, scene, sceneProblem =
			pcall(E2Scene.inspect, workspace, camera, if subject then subject.clone else nil)
		return {
			guard = guard,
			marker = found,
			armValue = if found then found:GetAttribute(FixtureGuard.ARM_ATTRIBUTE) else nil,
			camera = camera,
			view = view,
			viewportActive = if tabKnown then activeScript == nil else nil,
			selectionEmpty = if selectionKnown then selected == 0 else nil,
			terrainCells = if terrainKnown then cells else nil,
			scene = if sceneKnown then scene else nil,
			sceneProblem = if sceneKnown then sceneProblem else "the scene could not be read",
			subject = subject,
		}
	end

	local function disarm(reason: string)
		Approval.disarm(state, reason)
	end
	withdraw = disarm

	Preview.setCaptureGate(function(capturing: boolean): string?
		return Approval.refusal(state, look(), capturing)
	end, disarm)

	-- Approval is given only at the moment a person types the fixture id into the arm
	-- attribute, and is withdrawn by any other change to it.
	table.insert(
		signals,
		marker:GetAttributeChangedSignal(FixtureGuard.ARM_ATTRIBUTE):Connect(function()
			if marker:GetAttribute(FixtureGuard.ARM_ATTRIBUTE) == fixtureId then
				local approved, why = Approval.arm(state, look())
				print(
					if approved
						then "[MotionBridgeProbe] Screenshots approved for this scene and camera."
						else `[MotionBridgeProbe] Screenshots not approved: {why}.`
				)
			else
				disarm("the fixture was unarmed")
			end
		end)
	)
	table.insert(
		signals,
		workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			disarm("the camera was switched")
		end)
	)
	pcall(function()
		local studio = game:GetService("StudioService")
		table.insert(
			signals,
			studio:GetPropertyChangedSignal("ActiveScript"):Connect(function()
				disarm("the active tab changed")
			end)
		)
	end)
	print(
		`[MotionBridgeProbe] Screenshot mode. Frame the camera, then set {FixtureGuard.ARM_ATTRIBUTE} to the fixture id to approve.`
	)
else
	local Probes = require("./Probes")
	for name, handler in Probes.create(methods, registry) do
		methods[name] = handler
	end
end

local connection
connection = Connection.start({
	port = port,
	session = {
		id = string.lower((string.gsub(HttpService:GenerateGUID(false), "[^%x]", ""))),
		placeName = game.Name,
		placeId = game.PlaceId,
		pluginVersion = "probe",
	},
	-- The credential derived from the one-time code lives in memory only.
	pairingCode = code,
	onRequest = function(method: string, params: any): any
		if method == "probe.connection_stats" then
			return connection.stats
		end
		return Handlers.dispatcher(methods)(method, params)
	end,
	onState = function(state, stateDetail)
		print(`[MotionBridgeProbe] {state} {stateDetail or ""}`)
	end,
	onCredential = function() end,
})

plugin.Unloading:Connect(function()
	connection.stop()
	for _, signal in signals do
		signal:Disconnect()
	end
	-- Approval does not outlive the plugin, and a preview interrupted by the unload must
	-- not leave its clone in the place.
	if withdraw then
		withdraw("the plugin unloaded")
	end
	Preview.setCaptureGate(nil)
	Preview.sweep()
end)
