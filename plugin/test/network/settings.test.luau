--!strict
-- Offline tests for the plugin's settings. Run with: lune run plugin/test/network/settings.test.luau
--
-- Real here: the read-back and retry, and the test build's dropped writes. Simulated: the
-- settings themselves, as one table every "window" shares, and another window's write,
-- made while this one waits to read its own back. Not tested here: how Studio stores and
-- shares settings between its windows, which needs two Studio windows.

local process = require("@lune/process")
local serde = require("@lune/serde")

local Fault = require("../../fault/Fault")
local Settings = require("../../src/Network/Settings")

local failures = 0
local count = 0

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

type Shared = {
	values: { [string]: any },
	writes: number,
	-- Run while a window waits to read back what it wrote, as if another window wrote then.
	meanwhile: { () -> () },
	-- When true, writes are dropped without an error.
	dropping: boolean,
}

local function shared(): Shared
	return { values = {}, writes = 0, meanwhile = {}, dropping = false }
end

local function window(on: Shared): Settings.Store
	return {
		get = function(key: string): any
			return on.values[key]
		end,
		set = function(key: string, value: any)
			on.writes += 1
			if not on.dropping then
				on.values[key] = value
			end
		end,
		wait = function(_seconds: number)
			local now = table.remove(on.meanwhile, 1)
			if now then
				now()
			end
		end,
		decode = function(text: string): any
			return serde.decode("json", text)
		end,
		encode = function(value: any): string
			return serde.encode("json", value)
		end,
	}
end

local CREDENTIAL = { id = string.rep("a", 16), keyHex = string.rep("b", 64) }

-- Writing and reading back.
do
	local on = shared()
	local settings = Settings.new(window(on))
	check("a write that holds is done in one try", settings.write("KeywrightPort", 47400) and on.writes == 1)
	check("and is read back", settings.read("KeywrightPort") == 47400)
	check("an unset setting reads as nil", settings.read("KeywrightOther") == nil)
end

-- A setting stored under the former name.
do
	local on = shared()
	on.values["MotionBridgeCredential"] = `{CREDENTIAL.id}:{CREDENTIAL.keyHex}`
	local settings = Settings.new(window(on))
	local credential = settings.credential()
	check("a credential stored under the former name is read", credential and credential.id == CREDENTIAL.id)
	check("and saved under the new name", settings.saveCredential(credential) and on.values[Settings.CREDENTIAL] ~= nil)
	on.values[Settings.CREDENTIAL] = ""
	check("the new name wins once written, even when empty", settings.credential() == nil)
end

-- The credential.
do
	local on = shared()
	local settings = Settings.new(window(on))
	check("no credential at first", settings.credential() == nil)
	check("one is saved", settings.saveCredential(CREDENTIAL))
	local read = settings.credential()
	check("and read back whole", read and read.id == CREDENTIAL.id and read.keyHex == CREDENTIAL.keyHex)
	check("forgetting it is saved too", settings.saveCredential(nil) and settings.credential() == nil)
	for _, bad in { "nonsense", `{CREDENTIAL.id}:abc`, `abc:{CREDENTIAL.keyHex}`, 12 } do
		on.values[Settings.CREDENTIAL] = bad
		check(`a malformed credential is not used: {bad}`, settings.credential() == nil)
	end
end

-- Remembering access per place, each place in a setting of its own.
local function own(place: number): string
	return `{Settings.ACCESS}_{place}`
end

do
	local on = shared()
	local settings = Settings.new(window(on))
	check("access is off for a place never turned on", not settings.accessOn(101))
	check("turning it on is remembered", settings.rememberAccess(101, true) and settings.accessOn(101))
	check("in that place's own setting", on.values[own(101)] == true)
	check("for that place only", not settings.accessOn(202))
	check(
		"a second place is added",
		settings.rememberAccess(202, true) and settings.accessOn(101) and settings.accessOn(202)
	)
	check(
		"turning one off keeps the other",
		settings.rememberAccess(101, false) and not settings.accessOn(101) and settings.accessOn(202)
	)
	check("off is written as off, not removed", on.values[own(101)] == false)
	local writes = on.writes
	check("a place never saved to Roblox counts as done", settings.rememberAccess(0, true))
	check("without writing anything", on.writes == writes and not settings.accessOn(0))
end

-- Places turned on before each place had a setting of its own were kept in one list.
do
	local on = shared()
	on.values[Settings.ACCESS] = serde.encode("json", { ["101"] = true, ["202"] = true })
	local settings = Settings.new(window(on))
	check("a place in the old list is still on", settings.accessOn(101) and settings.accessOn(202))
	check(
		"turning it off is kept, though the old list still names it",
		settings.rememberAccess(101, false) and not settings.accessOn(101)
	)
	check("and the other place in the list is untouched", settings.accessOn(202))
	on.values[Settings.ACCESS] = "{not json"
	check("an unreadable old list names no place", not settings.accessOn(202))
end

-- Two windows on two places. Window B writes while A waits to read its own write back.
-- Each writes only its own place's setting, so neither can undo the other.
do
	local on = shared()
	local a = Settings.new(window(on))
	local b = Settings.new(window(on))
	a.rememberAccess(101, true)
	table.insert(on.meanwhile, function()
		b.rememberAccess(202, true)
	end)
	check("A turns its place off while B turns its own on", a.rememberAccess(101, false))
	check(
		"A's place stays off and B's is on",
		not a.accessOn(101) and a.accessOn(202) and b.accessOn(202) and not b.accessOn(101)
	)
	-- B, which had read nothing of A's place, writes again later: A's place is still off.
	check("a later write from B leaves A's place as A left it", b.rememberAccess(202, true) and not b.accessOn(101))
end

do
	-- Two windows on the same place, one of them writing over the other every time.
	local on = shared()
	local a = Settings.new(window(on))
	local b = window(on)
	for _ = 1, Settings.TRIES do
		table.insert(on.meanwhile, function()
			b.set(own(101), false)
		end)
	end
	check("gives up after its tries", not a.rememberAccess(101, true) and on.writes == 2 * Settings.TRIES)
end

do
	-- A write that lands, in a store that then cannot be read: never taken as written.
	local on = shared()
	local store = window(on)
	local settings = Settings.new(store)
	settings.rememberAccess(101, true)
	store.get = function(_key: string): any
		error("settings unreadable")
	end
	check("turning off is not reported done when it cannot be read back", not settings.rememberAccess(101, false))
	check("though the write itself was made", on.values[own(101)] == false)
end

-- One window, a person clicking the switch on and then off before the first write has
-- been read back. The last click is what is remembered.
do
	local on = shared()
	local settings = Settings.new(window(on))
	local second: boolean? = nil
	table.insert(on.meanwhile, function()
		second = settings.rememberAccess(101, false)
	end)
	local first = settings.rememberAccess(101, true)
	check("the later click is done", second == true)
	check("the earlier one does not report a failure", first == true)
	check("and the later click is what is remembered", not settings.accessOn(101), on.values[own(101)])
end

do
	-- Off, then on: on is remembered.
	local on = shared()
	on.values[Settings.ACCESS] = serde.encode("json", { ["101"] = true })
	local settings = Settings.new(window(on))
	table.insert(on.meanwhile, function()
		settings.rememberAccess(101, true)
	end)
	settings.rememberAccess(101, false)
	check("off then on quickly leaves it on", settings.accessOn(101))
end

do
	-- A newer write of the credential wins over an older one still being read back.
	local on = shared()
	local settings = Settings.new(window(on))
	local newer = { id = string.rep("c", 16), keyHex = string.rep("d", 64) }
	table.insert(on.meanwhile, function()
		settings.saveCredential(newer)
	end)
	settings.saveCredential(CREDENTIAL)
	local read = settings.credential()
	check("the newer credential is the one kept", read and read.id == newer.id)
end

-- Writes that fail without an error.
do
	local on = shared()
	on.dropping = true
	local settings = Settings.new(window(on))
	check("a dropped credential is reported", not settings.saveCredential(CREDENTIAL))
	check("after every try", on.writes == Settings.TRIES, on.writes)
	check("a dropped access write is reported", not settings.rememberAccess(101, true))
	check("and access is not remembered", not settings.accessOn(101))
end

do
	-- Only the first write is dropped.
	local on = shared()
	on.dropping = true
	table.insert(on.meanwhile, function()
		on.dropping = false
	end)
	local settings = Settings.new(window(on))
	check("a write dropped once is done on the next try", settings.saveCredential(CREDENTIAL) and on.writes == 2)
end

do
	-- A store that raises.
	local on = shared()
	local store = window(on)
	store.get = function(_key: string): any
		error("settings unreadable")
	end
	store.set = function(_key: string, _value: any)
		error("settings unwritable")
	end
	local settings = Settings.new(store)
	check("a store that raises reads as unset", settings.read(Settings.PORT) == nil and settings.credential() == nil)
	check(
		"and its writes are reported as failed",
		not settings.saveCredential(CREDENTIAL) and not settings.rememberAccess(101, true)
	)
end

-- The test build's fault.
do
	local on = shared()
	local active = false
	local settings = Settings.new(Fault.settings(window(on), function()
		return active
	end))
	check("with the fault off, writes are done", settings.rememberAccess(101, true) and settings.accessOn(101))
	active = true
	check("with it on, a write is reported as failed", not settings.saveCredential(CREDENTIAL))
	check("and nothing reaches the settings", on.values[Settings.CREDENTIAL] == nil)
	check("reads still work", settings.accessOn(101))
	check("turning access off is not done either", not settings.rememberAccess(101, false) and settings.accessOn(101))
	active = false
	check("with the fault off again, writes are done", settings.saveCredential(CREDENTIAL))
end

print(`{count - failures} of {count} settings checks passed`)
if failures > 0 then
	process.exit(1)
end
