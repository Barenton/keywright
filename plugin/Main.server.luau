--!strict
-- Plugin entry point: the agent access switch, pairing, and connection status.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Connection = require("./src/Network/Connection")
local Edit = require("./src/Editing/Edit")
local Handlers = require("./src/Handlers")
local Panel = require("./src/Panel")
local Preview = require("./src/Preview/Preview")
local Proposals = require("./src/Storage/Proposals")
local Recording = require("./src/Editing/Recording")
local Settings = require("./src/Network/Settings")

local PLUGIN_VERSION = require("./src/Version")
local DEFAULT_PORT = 47318
local CODE_ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789"

-- Only the edit data model talks to the broker.
if not RunService:IsEdit() then
	return
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
local store: Settings.Store = {
	get = function(key: string): any
		return plugin:GetSetting(key)
	end,
	set = function(key: string, value: any)
		plugin:SetSetting(key, value)
	end,
	wait = function(seconds: number)
		task.wait(seconds)
	end,
	decode = function(text: string): any
		return HttpService:JSONDecode(text)
	end,
	encode = function(value: any): string
		return HttpService:JSONEncode(value)
	end,
}
local version = PLUGIN_VERSION
local fault = script.Parent:FindFirstChild("Fault")
if fault and fault:IsA("ModuleScript") then
	local Fault = require(fault) :: any
	Fault.install(Edit, Recording)
	store = Fault.settings(store)
	version ..= "+fault"
	view.addNotice("Test build: some edits fail on purpose.")
end
view.setVersion(`v{version}`)
local settings = Settings.new(store)

local sessionId = string.lower((string.gsub(HttpService:GenerateGUID(false), "[^%x]", "")))
local methods, _, panel = Handlers.create()

local connection: any = nil

local function start()
	local port = settings.read(Settings.PORT)
	local credential = settings.credential()
	local code = if credential then nil else newPairingCode()
	view.setPairing(code)
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
				if not settings.saveCredential(newCredential) then
					view.setNote("Paired for this session, but the credential could not be saved.")
				end
			else
				settings.saveCredential(nil)
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
local function remember(on: boolean)
	if settings.rememberAccess(game.PlaceId, on) then
		return
	end
	if on then
		view.setNote("Agent access is on, but could not be remembered for this place.")
	else
		-- Access is off for now either way. Not saying so would let it come back unseen.
		view.setNote(
			"Agent access is off, but Studio did not save that, so it may turn on again the next time this place opens. Turn it on and off again to retry."
		)
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

if settings.accessOn(game.PlaceId) then
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
