--!strict
-- The plugin's settings: the pairing credential, the port, and the places where agent
-- access is on.
--
-- Plugin settings are shared by every Studio window on the machine, and a write can fail
-- without an error. So each write is read back and tried again, up to three times. Each
-- place has a setting of its own, so a window writing for one place never touches
-- another's. Within one window, the latest write to a setting wins: an earlier one still
-- waiting to read itself back stops, and does not write again over it.
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
	-- Reads a setting: whether it could be read at all, and its value.
	local function get(key: string): (boolean, any)
		local ok, value = pcall(store.get, key)
		return ok, if ok then value else nil
	end

	local function readChecked(key: string): (boolean, any)
		local ok, value = get(key)
		if not ok or value ~= nil then
			return ok, value
		end
		-- A setting stored under the former name is still read, so that a pairing and the
		-- places where access was on carry over. It is written under the new name from then on.
		return get(FORMER_PREFIX .. string.sub(key, #"Keywright" + 1))
	end

	-- A setting that cannot be read is taken as unset.
	local function read(key: string): any
		local _, value = readChecked(key)
		return value
	end

	-- How many writes each setting has been given, so that a write knows when a later one
	-- has started.
	local started: { [string]: number } = {}

	-- Writes a value until it reads back, up to TRIES times. Only a successful read that
	-- gives the value counts: a setting that cannot be read is never taken as written. A
	-- write overtaken by a later one to the same setting leaves it to that one, and is not
	-- a failure.
	local function write(key: string, value: any): boolean
		local mine = (started[key] or 0) + 1
		started[key] = mine
		for _ = 1, Settings.TRIES do
			pcall(store.set, key, value)
			store.wait(Settings.SETTLE)
			if started[key] ~= mine then
				return true
			end
			local readable, stored = readChecked(key)
			if readable and stored == value then
				return true
			end
		end
		return false
	end

	-- The old list of places, decoded, or nil.
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

	-- A place's own setting says whether access is on there. A place without one is looked
	-- up in the old list, so that access turned on before each place had its own is kept.
	-- A place whose own setting cannot be read is off: it may say off, and the old list
	-- must not turn access back on in its place.
	function self.accessOn(placeId: any): boolean
		local name = Access.key(placeId)
		if not name then
			return false
		end
		local readable, own = readChecked(`{Settings.ACCESS}_{name}`)
		if not readable then
			return false
		end
		if type(own) == "boolean" then
			return own
		end
		return Access.remembered(places(read(Settings.ACCESS)), placeId)
	end

	-- Writes only this place's own setting, true or false, so no other place's is touched.
	-- Off is written as false, not removed, so that the old list cannot turn it back on. A
	-- place that cannot be told apart from others is never remembered, which counts as done.
	function self.rememberAccess(placeId: any, on: boolean): boolean
		local name = Access.key(placeId)
		if not name then
			return true
		end
		return write(`{Settings.ACCESS}_{name}`, on)
	end

	return self
end

return Settings
