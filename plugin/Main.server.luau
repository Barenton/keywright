--!strict
-- Plugin entry point: the agent access switch, pairing, and connection status.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Access = require("./src/Access")
local Connection = require("./src/Connection")
local Edit = require("./src/Edit")
local Handlers = require("./src/Handlers")
local Preview = require("./src/Preview")
local Recording = require("./src/Recording")

local PLUGIN_VERSION = "0.0.0"
local DEFAULT_PORT = 47318
local SETTING_PORT = "MotionBridgePort"
local SETTING_CREDENTIAL = "MotionBridgeCredential"
local SETTING_ACCESS = "MotionBridgeAccess"
local CODE_ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789"

-- Only the edit data model talks to the broker.
if not RunService:IsEdit() then
	return
end

local function readSetting(key: string): any
	local ok, value = pcall(function()
		return plugin:GetSetting(key)
	end)
	return if ok then value else nil
end

-- Plugin settings are shared by every Studio window and writes can fail silently,
-- so each write is read back.
local function writeSetting(key: string, value: any): boolean
	for _ = 1, 3 do
		pcall(function()
			plugin:SetSetting(key, value)
		end)
		task.wait(0.1)
		if readSetting(key) == value then
			return true
		end
	end
	return false
end

local function loadCredential(): Connection.Credential?
	local stored = readSetting(SETTING_CREDENTIAL)
	if type(stored) ~= "string" then
		return nil
	end
	local id, keyHex = string.match(stored, "^(%x+):(%x+)$")
	if id and keyHex and #id == 16 and #keyHex == 64 then
		return { id = id, keyHex = keyHex }
	end
	return nil
end

local function newPairingCode(): string
	-- GUIDs are the only unpredictable source available to plugins.
	local hex = string.gsub(HttpService:GenerateGUID(false), "[^%x]", "")
	local code = ""
	for i = 1, 20, 2 do
		local byte = tonumber(string.sub(hex, i, i + 1), 16) :: number
		local index = byte % #CODE_ALPHABET + 1
		code ..= string.sub(CODE_ALPHABET, index, index)
	end
	return code
end

local toolbar = plugin:CreateToolbar("Motion Bridge")
local button = toolbar:CreateButton("Motion Bridge", "Show the Motion Bridge panel", "")
local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"MotionBridgePanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 280, 160, 220, 120)
)
widget.Title = "Motion Bridge"
button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

local theme = settings().Studio.Theme
local frame = Instance.new("Frame")
frame.Size = UDim2.fromScale(1, 1)
frame.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
frame.BorderSizePixel = 0
frame.Parent = widget

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.Parent = frame
local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 10)
padding.PaddingLeft = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.Parent = frame

local function label(text: string): TextLabel
	local item = Instance.new("TextLabel")
	item.Size = UDim2.new(1, 0, 0, 36)
	item.BackgroundTransparency = 1
	item.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	item.Font = Enum.Font.SourceSans
	item.TextSize = 15
	item.TextWrapped = true
	item.TextXAlignment = Enum.TextXAlignment.Left
	item.TextYAlignment = Enum.TextYAlignment.Top
	item.Text = text
	item.Parent = frame
	return item
end

local toggle = Instance.new("TextButton")
toggle.Size = UDim2.new(1, 0, 0, 28)
toggle.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Button)
toggle.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.ButtonText)
toggle.Font = Enum.Font.SourceSans
toggle.TextSize = 15
toggle.Text = "Turn on agent access"
toggle.Parent = frame

local status = label("Agent access is off.")
local pairing = label("")

-- A test build carries one more module, which makes chosen edits fail on purpose so that
-- what Studio does then can be checked. The plugin as released has no such module. A
-- session from a test build says so in its version, and so does the panel.
local version = PLUGIN_VERSION
local fault = script.Parent:FindFirstChild("Fault")
if fault and fault:IsA("ModuleScript") then
	(require(fault) :: any).install(Edit, Recording)
	version ..= "+fault"
	label("Test build: some edits fail on purpose.")
end

local sessionId = string.lower((string.gsub(HttpService:GenerateGUID(false), "[^%x]", "")))
local methods = Handlers.create()
local connection: any = nil

local function start()
	local port = readSetting(SETTING_PORT)
	local credential = loadCredential()
	local code = if credential then nil else newPairingCode()
	pairing.Text = if code then `Pair once: run "motion-bridge pair {code}" in a terminal.` else ""
	connection = Connection.start({
		port = if type(port) == "number" then port else DEFAULT_PORT,
		session = {
			id = sessionId,
			placeName = game.Name,
			placeId = game.PlaceId,
			pluginVersion = version,
		},
		credential = credential,
		pairingCode = code,
		onRequest = Handlers.dispatcher(methods),
		onCancel = function(reason: string)
			Preview.cancel(reason)
		end,
		onState = function(state, detail)
			local text = if state == "ready"
				then "Connected to the broker."
				elseif state == "connecting" then "Connecting to the broker..."
				elseif state == "unpaired" then (if detail
					then "Waiting for the pairing code to be registered."
					else "Not paired with the broker.")
				elseif state == "foreign" then "Another program is using the broker port. Nothing was sent to it."
				elseif state == "denied" then `The broker refused the connection ({detail or "unknown"}).`
				elseif state == "stopped" then "Agent access is off."
				else "Broker not reachable. Retrying..."
			status.Text = text
		end,
		onCredential = function(newCredential)
			if newCredential then
				pairing.Text = ""
				if not writeSetting(SETTING_CREDENTIAL, `{newCredential.id}:{newCredential.keyHex}`) then
					pairing.Text = "Paired for this session, but the credential could not be saved."
				end
			else
				writeSetting(SETTING_CREDENTIAL, "")
				pairing.Text = "Pairing is needed again. Turn agent access off and on to get a new code."
			end
		end,
	})
end

-- Whether access is on is remembered for this place, so that reloading the plugin or
-- reopening the place does not turn it off. A place that has never been saved to Roblox
-- cannot be told from any other such place, so for it access is off every time.
local function rememberedPlaces(): any
	local stored = readSetting(SETTING_ACCESS)
	if type(stored) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(stored)
	end)
	return if ok then decoded else nil
end

local function remember(on: boolean)
	if game.PlaceId == 0 then
		return
	end
	-- Settings are shared by every Studio window and a write can fail silently, so the
	-- latest value is read before each write and the result is read back.
	for _ = 1, 3 do
		local places = Access.update(rememberedPlaces(), game.PlaceId, on)
		pcall(function()
			plugin:SetSetting(SETTING_ACCESS, HttpService:JSONEncode(places))
		end)
		task.wait(0.1)
		if Access.remembered(rememberedPlaces(), game.PlaceId) == on then
			return
		end
	end
	if on then
		pairing.Text = "Agent access is on, but could not be remembered for this place."
	end
end

toggle.MouseButton1Click:Connect(function()
	if connection then
		connection.stop()
		connection = nil
		-- A preview in progress gives up its screenshot.
		Preview.cancel("agent access was turned off")
		pairing.Text = ""
		toggle.Text = "Turn on agent access"
		remember(false)
	else
		toggle.Text = "Turn off agent access"
		start()
		remember(true)
	end
end)

if Access.remembered(rememberedPlaces(), game.PlaceId) then
	-- A person turned access on for this place earlier and has not turned it off.
	toggle.Text = "Turn off agent access"
	start()
end

plugin.Unloading:Connect(function()
	-- An undo recording still open now would never be finished, and Studio would refuse
	-- every later one.
	pcall(Recording.abandon)
	if connection then
		connection.stop()
	end
	-- A preview interrupted by the unload must not leave its clone in the place.
	Preview.sweep()
end)
