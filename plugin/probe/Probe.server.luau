--!strict
-- Entry point of the probe build. It acts only inside a disposable fixture (see
-- FixtureGuard), so loading it while any other place is open has no effect.
--
-- A prepared fixture carries no connection details. The probe connects only when a
-- person has added the Port and PairingCode attributes to the fixture marker.
--
-- The probe runs in one of two modes, chosen by the marker when the plugin loads:
--
--   Screenshot mode, when the marker has the mode attribute set to true. Only the
--   ordinary methods are offered. The experiment probes, which drive undo and redo and
--   reset the undo history, are not loaded at all. The probe builds one invisible
--   synthetic rig of its own, and shows a panel in which a person can approve
--   screenshots of the scene as they have framed it (see Approval).
--
--   Experiment mode, otherwise. The experiment probes are offered and the capture gate
--   is never opened, so no screenshot can be taken.
--
-- Nothing in the place can approve a screenshot. The mode attribute only selects which
-- of the two sets of methods is loaded.

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
	print(`[KeywrightProbe] Fixture {detail} recognised. No connection is configured, so nothing will run.`)
	return
end

local Connection = require("../src/Connection")
local Handlers = require("../src/Handlers")
local Preview = require("../src/Preview")

local screenshotMode = marker:GetAttribute(FixtureGuard.MODE_ATTRIBUTE) == true
local methods, registry = Handlers.create()
local signals: { RBXScriptConnection } = {}
local owned: { Instance } = {}
local withdraw: ((reason: string) -> ())? = nil

if screenshotMode then
	local Lighting = game:GetService("Lighting")
	local MaterialService = game:GetService("MaterialService")
	local Selection = game:GetService("Selection")
	local Approval = require("./Approval")
	local E2Scene = require("./E2Scene")
	local SyntheticRig = require("./SyntheticRig")

	-- The synthetic rig is the only thing a screenshot may be of. The probe builds its
	-- own for this session, invisible, and never adopts one it finds: a rig of that name
	-- already in the place is left alone and screenshots stay off.
	local rig: Model? = nil
	if workspace:FindFirstChild(E2Scene.RIG_NAME) then
		print(`[KeywrightProbe] A "{E2Scene.RIG_NAME}" is already in the place. Remove it and reload the probe.`)
	else
		local built = SyntheticRig.build("Motor6D", E2Scene.RIG_NAME, CFrame.new(0, 3.7, 0))
		-- Removed when the probe unloads. It stays archivable because a preview has to be
		-- able to copy it; if it is ever saved with the place, the check above refuses it.
		for _, descendant in built:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Transparency = 1
			end
		end
		table.insert(owned, built)
		rig = built
	end

	-- Approval is pinned to this marker instance, this fixture id and this rig.
	local state = Approval.new(marker, detail, rig)

	-- A switch of camera or tab withdraws approval as it happens. If either cannot be
	-- watched for, approval is never given.
	local watching = false
	-- Shows in the panel why there is no approval; set once the panel exists.
	local show: (text: string) -> () = function() end
	local function disarm(reason: string)
		Approval.disarm(state, reason)
		show(`Not approved: {reason}.`)
	end
	-- Withdraws approval and stops whatever was running under it: a preview gives up its
	-- screenshot, and a request to Studio for permission stops waiting.
	local function stop(reason: string)
		disarm(reason)
		Preview.cancel(reason)
	end
	withdraw = stop
	local watched = pcall(function()
		table.insert(
			signals,
			workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
				stop("the camera was switched")
			end)
		)
		table.insert(
			signals,
			game:GetService("StudioService"):GetPropertyChangedSignal("ActiveScript"):Connect(function()
				stop("the active tab changed")
			end)
		)
	end)
	watching = watched

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
		local sceneKnown, scene, sceneProblem = pcall(E2Scene.inspect, {
			root = workspace,
			camera = camera,
			lighting = Lighting,
			materials = MaterialService,
			rig = rig,
			clone = if subject then subject.clone else nil,
		})
		return {
			guard = guard,
			marker = found,
			camera = camera,
			view = view,
			viewportActive = if tabKnown then activeScript == nil else nil,
			selectionEmpty = if selectionKnown then selected == 0 else nil,
			terrainCells = if terrainKnown then cells else nil,
			watching = watching,
			scene = if sceneKnown then scene else nil,
			sceneProblem = if sceneKnown then sceneProblem else "the scene could not be read",
			subject = subject,
		}
	end

	Preview.setCaptureGate(function(capturing: boolean): string?
		local refusal = Approval.refusal(state, look(), capturing)
		if refusal and state.approved == nil then
			show(`Not approved: {state.withdrawn}.`)
		end
		return refusal
	end, disarm)

	-- The panel is the only way to approve. What is typed into it stays in memory.
	local widget = plugin:CreateDockWidgetPluginGuiAsync(
		"KeywrightProbeScreenshots",
		DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, true, true, 360, 230, 300, 200)
	)
	widget.Title = "Keywright probe: screenshots"
	table.insert(owned, widget)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(46, 46, 46)
	frame.BorderSizePixel = 0
	frame.Parent = widget
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.Parent = frame
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = frame

	local function text(class: string, height: number, content: string): any
		local item: any = Instance.new(class)
		item.Size = UDim2.new(1, 0, 0, height)
		item.BackgroundColor3 = Color3.fromRGB(64, 64, 64)
		item.BackgroundTransparency = if class == "TextLabel" then 1 else 0
		item.TextColor3 = Color3.fromRGB(230, 230, 230)
		item.Font = Enum.Font.SourceSans
		item.TextSize = 15
		item.TextWrapped = true
		item.TextXAlignment = Enum.TextXAlignment.Left
		item.Text = content
		item.Parent = frame
		return item
	end
	text("TextLabel", 34, "Frame the camera on the rig by hand, clear the selection, then type this fixture's id.")
	local input = text("TextBox", 26, "")
	input.PlaceholderText = "fixture id from INSTRUCTIONS.md"
	input.ClearTextOnFocus = false
	local approve = text("TextButton", 26, "Approve screenshots of this scene and camera")
	local revoke = text("TextButton", 26, "Withdraw approval")
	local describe = text("TextButton", 26, "Print what the probe sees (approves nothing)")
	local status = text("TextLabel", 40, "Not approved.")
	show = function(content: string)
		status.Text = content
	end

	table.insert(
		signals,
		approve.MouseButton1Click:Connect(function()
			local typed = string.gsub(input.Text, "%s", "")
			input.Text = ""
			local approved, why = Approval.arm(state, look(), typed)
			status.Text = if approved
				then "Approved for this scene and camera. Any change withdraws it."
				else `Not approved: {why}.`
		end)
	)
	table.insert(
		signals,
		revoke.MouseButton1Click:Connect(function()
			stop("approval was withdrawn in the panel")
		end)
	)
	-- For checking the probe's reading of Studio by hand. It reads and prints; it cannot
	-- approve, and it takes no picture.
	table.insert(
		signals,
		describe.MouseButton1Click:Connect(function()
			local seen = look()
			local view = seen.view
			print("[KeywrightProbe] What the probe sees:")
			print(`  fixture guard: {select(2, FixtureGuard.check(seen.guard))}`)
			print(
				`  3D viewport active: {tostring(seen.viewportActive)}; nothing selected: {tostring(seen.selectionEmpty)}`
			)
			print(`  terrain cells: {tostring(seen.terrainCells)}; switches watched: {tostring(seen.watching)}`)
			print(
				if view
					then `  camera: {tostring(view.cframe.Position)} fov {view.fieldOfView} viewport {view.width}x{view.height}`
					else "  camera: could not be read"
			)
			print(`  scene: {if seen.scene then "the fixture scene" else tostring(seen.sceneProblem)}`)
			print(`  screenshots now: {Approval.refusal(state, seen, false) or "possible"}`)
		end)
	)
	print("[KeywrightProbe] Screenshot mode. Approve in the probe's panel once the camera is framed.")
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
	-- A request nobody is waiting for any more gives up its screenshot and its approval.
	onCancel = function(reason: string)
		Preview.cancel(reason)
	end,
	onState = function(state, stateDetail)
		print(`[KeywrightProbe] {state} {stateDetail or ""}`)
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
	for _, instance in owned do
		pcall(function()
			instance:Destroy()
		end)
	end
end)
