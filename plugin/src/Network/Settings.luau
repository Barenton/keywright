--!strict
-- The plugin's settings: the pairing credential, the port, and the places where agent
-- access is on.
--
-- Plugin settings are shared by every Studio window on the machine, and a write can fail
-- without an error. So each write is read back and tried again, up to three times, and
-- the places where access is on are read just before each write, so that a place another
-- window has just added is kept. Within one window, the latest write to a setting wins: an
-- earlier one still waiting to read itself back stops, and does not write again over it.
--
-- The settings themselves are reached through a store that is passed in: in the plugin
-- it is Plugin:GetSetting and Plugin:SetSetting; in tests, a table.

local Access = require("./Access")

local Settings = {}

Settings.PORT = "KeywrightPort"
Settings.CREDENTIAL = "KeywrightCredential"
Settings.ACCESS = "KeywrightAccess"

-- How many times a write is tried, and how long to wait before reading it back.
Settings.TRIES = 3
Settings.SETTLE = 0.1

-- The start of the names settings had before the project was called Keywright.
local FORMER_PREFIX = "Motion" .. "Bridge"

export type Store = {
	get: (key: string) -> any,
	set: (key: string, value: any) -> (),
	wait: (seconds: number) -> (),
	-- Decodes and encodes JSON.
	decode: (text: string) -> any,
	encode: (value: any) -> string,
}

export type Credential = { id: string, keyHex: string }

export type Settings = {
	read: (key: string) -> any,
	write: (key: string, value: any) -> boolean,
	credential: () -> Credential?,
	saveCredential: (credential: Credential?) -> boolean,
	accessOn: (placeId: any) -> boolean,
	rememberAccess: (placeId: any, on: boolean) -> boolean,
}

function Settings.new(store: Store): Settings
	local function get(key: string): any
		local ok, value = pcall(store.get, key)
		return if ok then value else nil
	end

	local function read(key: string): any
		local value = get(key)
		if value ~= nil then
			return value
		end
		-- A setting stored under the former name is still read, so that a pairing and the
		-- places where access was on carry over. It is written under the new name from then on.
		return get(FORMER_PREFIX .. string.sub(key, #"Keywright" + 1))
	end

	-- How many writes each setting has been given, so that a write knows when a later one
	-- has started.
	local started: { [string]: number } = {}

	-- Writes what `make` returns, given what is stored now, until `holds` says the stored
	-- value is right. A write overtaken by a later one to the same setting leaves it to that
	-- one, and is not a failure.
	local function settle(key: string, make: (current: any) -> any, holds: (stored: any) -> boolean): boolean
		local mine = (started[key] or 0) + 1
		started[key] = mine
		for _ = 1, Settings.TRIES do
			local value = make(read(key))
			pcall(store.set, key, value)
			store.wait(Settings.SETTLE)
			if started[key] ~= mine then
				return true
			end
			if holds(read(key)) then
				return true
			end
		end
		return false
	end

	local function write(key: string, value: any): boolean
		return settle(key, function()
			return value
		end, function(stored)
			return stored == value
		end)
	end

	local function places(stored: any): any
		if type(stored) ~= "string" then
			return nil
		end
		local ok, decoded = pcall(store.decode, stored)
		return if ok then decoded else nil
	end

	local self = {}
	self.read = read
	self.write = write

	function self.credential(): Credential?
		local stored = read(Settings.CREDENTIAL)
		if type(stored) ~= "string" then
			return nil
		end
		local id, keyHex = string.match(stored, "^(%x+):(%x+)$")
		if id and keyHex and #id == 16 and #keyHex == 64 then
			return { id = id, keyHex = keyHex }
		end
		return nil
	end

	-- Nil forgets the credential.
	function self.saveCredential(credential: Credential?): boolean
		return write(Settings.CREDENTIAL, if credential then `{credential.id}:{credential.keyHex}` else "")
	end

	function self.accessOn(placeId: any): boolean
		return Access.remembered(places(read(Settings.ACCESS)), placeId)
	end

	-- A place that cannot be told apart from others is never remembered, which counts as
	-- done.
	function self.rememberAccess(placeId: any, on: boolean): boolean
		if not Access.remembered(Access.update(nil, placeId, true), placeId) then
			return true
		end
		return settle(Settings.ACCESS, function(current)
			return store.encode(Access.update(places(current), placeId, on))
		end, function(stored)
			return Access.remembered(places(stored), placeId) == on
		end)
	end

	return self
end

return Settings
