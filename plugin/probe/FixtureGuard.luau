--!strict
-- Decides whether probe code may act in the open place. Probes are only ever allowed
-- in a disposable fixture prepared by scripts/prepare-studio-fixture.mjs: an unpublished
-- place, in edit mode, carrying the fixture marker. This module only computes, so the
-- same rules are tested headlessly.

local FixtureGuard = {}

FixtureGuard.MARKER_NAME = "MotionBridgeFixture"
FixtureGuard.MARKER_PREFIX = "motion-bridge-fixture/1/"
FixtureGuard.ID_LENGTH = 32
-- Attribute a person adds to the marker, set to true, to start the probe in screenshot
-- mode. It selects a mode and approves nothing: approval is given in the probe's panel.
FixtureGuard.MODE_ATTRIBUTE = "ScreenshotMode"

export type Observation = {
	markerClass: string?, -- ClassName of ServerStorage.MotionBridgeFixture, or nil if absent
	markerValue: string?,
	placeId: number,
	gameId: number,
	isEdit: boolean,
}

-- Returns true and the fixture id, or false and the reason probes must not run.
function FixtureGuard.check(observation: Observation): (boolean, string)
	if not observation.isEdit then
		return false, "Studio is not in edit mode"
	end
	if observation.placeId ~= 0 or observation.gameId ~= 0 then
		return false, "the place is published; probes run only in an unpublished fixture"
	end
	if observation.markerClass == nil then
		return false, "the place has no fixture marker"
	end
	if observation.markerClass ~= "StringValue" or type(observation.markerValue) ~= "string" then
		return false, "the fixture marker is not a StringValue"
	end
	local value = observation.markerValue :: string
	local prefix = FixtureGuard.MARKER_PREFIX
	if string.sub(value, 1, #prefix) ~= prefix then
		return false, "the fixture marker has an unknown format"
	end
	local id = string.sub(value, #prefix + 1)
	if #id ~= FixtureGuard.ID_LENGTH or string.match(id, "^[0-9a-f]+$") == nil then
		return false, "the fixture marker carries no valid fixture id"
	end
	return true, id
end

-- Screenshots are allowed only in the one fixture the probe was started in, and only
-- when the id a person typed into the probe's panel is that fixture's own. `selected` is
-- what they typed; it never comes from the place. A marker of the right form with any
-- other id, or any other value typed, is refused. Returns true and the fixture id, or
-- false and the reason.
function FixtureGuard.screenshots(observation: Observation, selected: any, pinnedId: any): (boolean, string)
	local allowed, detail = FixtureGuard.check(observation)
	if not allowed then
		return false, detail
	end
	if type(pinnedId) ~= "string" or #pinnedId ~= FixtureGuard.ID_LENGTH or detail ~= pinnedId then
		return false, "the fixture is not the one the probe was started in"
	end
	if type(selected) ~= "string" or selected ~= pinnedId then
		return false, "the fixture id typed in the panel is not this fixture's"
	end
	return true, detail
end

return FixtureGuard
