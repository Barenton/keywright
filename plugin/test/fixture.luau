--!strict
-- Checks the prepared fixture place without Studio: it must contain the marker named in
-- its manifest, pass the same guard the probe uses, and hold nothing else of note.
-- Run from the project root after `npm run prepare:fixture`: lune run plugin/test/fixture.luau

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde")

local FixtureGuard = require("../probe/FixtureGuard")

local DIR = "build/fixture/"
local ALLOWED_CLASSES = { Workspace = true, ServerStorage = true, StringValue = true, Part = true }

local failures = 0
local count = 0
local function check(name: string, condition: boolean, detail: string?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL {name}{if detail then ": " .. detail else ""}`)
	end
end

local manifest = serde.decode("json", fs.readFile(DIR .. "manifest.json"))
local place = roblox.deserializePlace(fs.readFile(DIR .. manifest.place))

local serverStorage = place:GetService("ServerStorage")
local children = serverStorage:GetChildren()
check("ServerStorage holds exactly the marker", #children == 1, `{#children} children`)
local marker = children[1]
check("marker name", marker ~= nil and marker.Name == FixtureGuard.MARKER_NAME)
check("marker name matches manifest", marker ~= nil and marker.Name == manifest.marker_name)
check("marker value matches manifest", marker ~= nil and marker.Value == manifest.marker_value)
local armed = if marker then marker:GetAttribute(FixtureGuard.ARM_ATTRIBUTE) else nil
check("the fixture is prepared unarmed", armed == nil, tostring(armed))
local shoot, why = FixtureGuard.screenshots({
	markerClass = if marker then marker.ClassName else nil,
	markerValue = if marker then marker.Value else nil,
	placeId = 0,
	gameId = 0,
	isEdit = true,
}, armed, manifest.id)
check("screenshots are refused in the fixture as prepared", shoot == false, why)

local allowed, id = FixtureGuard.check({
	markerClass = if marker then marker.ClassName else nil,
	markerValue = if marker then marker.Value else nil,
	placeId = 0,
	gameId = 0,
	isEdit = true,
})
check("guard accepts the fixture", allowed, id)
check("guard returns the manifest id", id == manifest.id, id)

local scripts, unexpected = 0, {}
for _, instance in place:GetDescendants() do
	local class = instance.ClassName
	if class == "Script" or class == "LocalScript" or class == "ModuleScript" then
		scripts += 1
	end
	if not ALLOWED_CLASSES[class] then
		table.insert(unexpected, class)
	end
end
check("the place contains no scripts", scripts == 0, `{scripts} found`)
check("the place contains only the expected classes", #unexpected == 0, table.concat(unexpected, ", "))

print(`{count - failures}/{count} fixture checks passed`)
if failures > 0 then
	process.exit(1)
end
