--!strict
-- Which places a person turned agent access on for.
--
-- A place is known by its PlaceId. A place that has never been saved to Roblox has the
-- id zero, as does every other such place, so it is never remembered: access there is
-- off each time until a person turns it on. Turning access on in one place never turns
-- it on in another.
--
-- Each place is remembered in a setting of its own (see Settings), so that a window
-- writing for one place never touches another's. Before that, all places were kept in
-- one list; a place with no setting of its own is still looked up there.

local Access = {}

-- The key a place is known by, or nil for a place that cannot be told apart.
function Access.key(placeId: any): string?
	if type(placeId) ~= "number" or placeId ~= placeId or placeId < 1 or placeId ~= math.floor(placeId) then
		return nil
	end
	return string.format("%d", placeId)
end

-- True only when the old list, as decoded, says access was turned on for exactly this place.
function Access.remembered(stored: any, placeId: any): boolean
	local name = Access.key(placeId)
	return name ~= nil and type(stored) == "table" and stored[name] == true
end

return Access
