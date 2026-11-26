--!strict
-- Offline tests for the panel. Run with: lune run plugin/test/panel/panel.test.luau
--
-- Real here: what the panel says about each state of the connection. Not tested here: how
-- it looks and is laid out in Studio, at each size, which needs a person to look at it.

local process = require("@lune/process")

local Panel = require("../../src/Panel")

local failures = 0
local count = 0

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

-- Every state the connection reports has words and a colour of its own.
local states = {
	{ "ready", nil, "ready" },
	{ "connecting", nil, "busy" },
	{ "unpaired", nil, "busy" },
	{ "unpaired", "pairing", "busy" },
	{ "foreign", nil, "problem" },
	{ "denied", "plugin_older", "problem" },
	{ "denied", "adapter_older", "problem" },
	{ "denied", "credential", "problem" },
	{ "disconnected", nil, "problem" },
	{ "stopped", nil, "off" },
}
local said: { [string]: boolean } = {}
for _, case in states do
	local state, detail, tone = case[1], case[2], case[3]
	local text, given = Panel.describe(state, detail)
	local name = `{state}{if detail then "/" .. detail else ""}`
	check(`{name} has words`, #text > 0)
	check(`{name} has the colour it should`, given == tone, given)
	said[text] = true
end
check(
	"an older plugin is told how to update",
	string.find((Panel.describe("denied", "plugin_older")), "install:plugin", 1, true)
)
check("a refusal names its reason", string.find((Panel.describe("denied", "credential")), "credential", 1, true))
local distinct = 0
for _ in said do
	distinct += 1
end
check("each state is told apart from the others", distinct == #states, distinct)

print(`panel: {count - failures}/{count} checks passed`)
if failures > 0 then
	process.exit(1)
end
