--!strict
-- Plugin entry point: the agent access switch, pairing, and connection status.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Access = require("./src/Network/Access")
local Connection = require("./src/Network/Connection")
local Edit = require("./src/Editing/Edit")
local Handlers = require("./src/Handlers")
local Panel = require("./src/Panel")
local Preview = require("./src/Preview/Preview")
local Proposals = require("./src/Storage/Proposals")
local Recording = require("./src/Editing/Recording")

local PLUGIN_VERSION = require("./src/Version")
local DEFAULT_PORT = 47318
local SETTING_PORT = "KeywrightPort"
local SETTING_CREDENTIAL = "KeywrightCredential"
local SETTING_ACCESS = "KeywrightAccess"
local CODE_ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789"

-- Only the edit data model talks to the broker.
if not RunService:IsEdit() then
	return
end

-- The start of the names settings had before the project was called Keywright.
local FORMER_PREFIX = "Motion" .. "Bridge"

local function readSetting(key: string): any
	local ok, value = pcall(function()
		return plugin:GetSetting(key)
	end)
	if ok and value ~= nil then
		return value
	end
	-- A setting stored under the former name is still read, so that a pairing and the
	-- places where access was on carry over. It is written under the new name from then on.
	local former = FORMER_PREFIX .. string.sub(key, #"Keywright" + 1)
	local found, old = pcall(function()
		return plugin:GetSetting(former)
	end)
	return if found then old else nil
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

local toolbar = plugin:CreateToolbar("Keywright")
local button = toolbar:CreateButton("Keywright", "Show the Keywright panel", "")
local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"KeywrightPanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 300, 240, 200, 120)
)
widget.Title = "Keywright"
button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

local view = Panel.new(widget)
view.setStatus(Panel.describe("stopped"))

-- A test build carries one more module, which makes chosen edits fail on purpose so that
-- what Studio does then can be checked. The plugin as released has no such module. A
-- session from a test build says so in its version, and so does the panel.
local version = PLUGIN_VERSION
local fault = script.Parent:FindFirstChild("Fault")
if fault and fault:IsA("ModuleScript") then
	(require(fault) :: any).install(Edit, Recording)
	version ..= "+fault"
	view.addNotice("Test build: some edits fail on purpose.")
end
view.setVersion(`Keywright {version}`)

local sessionId = string.lower((string.gsub(HttpService:GenerateGUID(false), "[^%x]", "")))
local methods, _, panel = Handlers.create()

local connection: any = nil

local function start()
	local port = readSetting(SETTING_PORT)
	local credential = loadCredential()
	local code = if credential then nil else newPairingCode()
	-- The command as the README gives it, run from the keywright folder.
	view.setPairing(if code then `node dist/src/cli.js pair {code}` else nil)
	view.setNote("")
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
			local text: string, tone: Panel.Tone = Panel.describe(state, detail)
			view.setStatus(text, tone)
		end,
		onCredential = function(newCredential)
			view.setPairing(nil)
			if newCredential then
				if not writeSetting(SETTING_CREDENTIAL, `{newCredential.id}:{newCredential.keyHex}`) then
					view.setNote("Paired for this session, but the credential could not be saved.")
				end
			else
				writeSetting(SETTING_CREDENTIAL, "")
				view.setNote("Pairing is needed again. Turn agent access off and on to get a new code.")
			end
		end,
	})
end

-- A proposed replacement of a clip: shown on the panel, and settled only there. The oldest
-- one waiting is shown; the rest wait their turn. Below it, a line stays to say what was
-- last decided.
local shown: string? = nil
local stopped: string? = nil

local function showProposals()
	local waiting = Proposals.pending()
	local first = waiting[1]
	shown = if first then first.clipId else nil
	if first then
		local more = if #waiting > 1 then ` ({#waiting - 1} more waiting)` else ""
		local note = if stopped then `\n{stopped}` else ""
		view.setProposal(
			`It would replace the clip "{first.source}" with its working copy "{first.name}". Nothing is replaced unless you choose it.{more}{note}`
		)
		-- A person has to see it to settle it.
		widget.Enabled = true
	else
		view.setProposal(nil)
	end
end
local stopProposals = Proposals.subscribe(function()
	stopped = nil
	showProposals()
end)
-- What became of the proposal just decided, in words that stay on the panel.
local function report(clipId: string)
	local settled = Proposals.get(clipId)
	if not settled or settled.status == "pending" then
		return
	end
	view.setOutcome(
		if settled.status == "approved"
			then `Replaced the clip "{settled.source}" with "{settled.name}". Undo (Ctrl+Z) puts it back.`
			elseif settled.reason == Handlers.REJECTED_IN_STUDIO then `Kept the clip "{settled.source}" as it is.`
			else `The clip "{settled.source}" was not replaced: {settled.reason or "the proposal no longer applied."}`
	)
end
view.approve.MouseButton1Click:Connect(function()
	local deciding = shown
	if deciding then
		stopped = panel.decide(deciding, true)
		report(deciding)
		showProposals()
	end
end)
view.reject.MouseButton1Click:Connect(function()
	local deciding = shown
	if deciding then
		panel.decide(deciding, false)
		report(deciding)
	end
end)

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
		view.setNote("Agent access is on, but could not be remembered for this place.")
	end
end

view.toggle.MouseButton1Click:Connect(function()
	if connection then
		connection.stop()
		connection = nil
		-- A preview in progress gives up its screenshot.
		Preview.cancel("agent access was turned off")
		view.setPairing(nil)
		view.setNote("")
		view.setAccess(false)
		remember(false)
	else
		view.setAccess(true)
		start()
		remember(true)
	end
end)

if Access.remembered(rememberedPlaces(), game.PlaceId) then
	-- A person turned access on for this place earlier and has not turned it off.
	view.setAccess(true)
	start()
end

plugin.Unloading:Connect(function()
	stopProposals()
	view.destroy()
	-- An undo recording still open now would never be finished, and Studio would refuse
	-- every later one.
	pcall(Recording.abandon)
	if connection then
		connection.stop()
	end
	-- A preview interrupted by the unload must not leave its clone in the place.
	Preview.sweep()
end)
