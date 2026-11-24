--!strict
-- Remembers, per place, whether a person turned agent access on.
--
-- A place is known by its PlaceId. A place that has never been saved to Roblox has the
-- id zero, as does every other such place, so it is never remembered: access there is
-- off each time until a person turns it on. Turning access on in one place never turns
-- it on in another.
--
-- This module only computes. What it returns is what the plugin keeps in its settings,
-- which are shared by every Studio window on the machine.

local Access = {}

-- Most places remembered at once.
Access.MAX_PLACES = 200

export type Stored = { [string]: boolean }

-- The key a place is remembered under, or nil for a place that cannot be told apart.
local function key(placeId: any): string?
	if type(placeId) ~= "number" or placeId ~= placeId or placeId < 1 or placeId ~= math.floor(placeId) then
		return nil
	end
	return string.format("%d", placeId)
end

-- True only when access was turned on for exactly this place and not turned off since.
function Access.remembered(stored: any, placeId: any): boolean
	local name = key(placeId)
	return name ~= nil and type(stored) == "table" and stored[name] == true
end

-- Returns what to store after access is turned on or off for a place. Only places with
-- access on are kept, and no more than the limit: when there are too many, others are
-- dropped, never the one just set.
function Access.update(stored: any, placeId: any, on: boolean): Stored
	local result: Stored = {}
	local kept = 0
	local name = key(placeId)
	if name and on then
		result[name] = true
		kept = 1
	end
	if type(stored) == "table" then
		local names: { string } = {}
		for existing, value in stored do
			if
				type(existing) == "string"
				and value == true
				and existing ~= name
				and string.match(existing, "^%d+$")
			then
				table.insert(names, existing)
			end
		end
		table.sort(names)
		for _, existing in names do
			if kept >= Access.MAX_PLACES then
				break
			end
			result[existing] = true
			kept += 1
		end
	end
	return result
end

return Access
