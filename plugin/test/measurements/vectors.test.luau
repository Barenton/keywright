--!strict
-- E10: a fixed set of CFrames, as Studio holds them and as Lune works them out.
-- Run from the repository root with: lune run plugin/test/measurements/vectors.test.luau
--
-- plugin/test/measurements/studio-vectors.json holds Studio's numbers. They were not typed in: for each
-- pose the measuring script (scripts/measure.mjs) had the plugin build it in Studio, read
-- the clip's fingerprint, and searched for the single-precision numbers that give exactly
-- that fingerprint. test/scripts/measure.test.ts checks that every entry still hashes to its
-- fingerprint, so the numbers here are Studio's, digit for digit.
--
-- This file builds each pose the way the plugin does, with Lune's CFrame, and requires
-- every number to be within 1e-5 of Studio's.
--
-- Not covered: a CFrame stored on a Pose under Lune. Lune keeps that less exactly (the
-- cosine of 30 degrees comes back as 0.866027832), which is still within the limit but is
-- why fingerprints of clips with poses differ between the two.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde")

local CFrame = roblox.CFrame
local LIMIT = 1e-5

local failures = 0
local count = 0

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

-- As Rig.decode builds a pose from a position and Euler angles in degrees.
local function decode(position: { number }?, rotation: { number }): any
	local p = position or { 0, 0, 0 }
	return CFrame.new(p[1], p[2], p[3])
		* CFrame.fromEulerAnglesXYZ(math.rad(rotation[1]), math.rad(rotation[2]), math.rad(rotation[3]))
end

local recorded = serde.decode("json", fs.readFile("plugin/test/measurements/studio-vectors.json")) :: any
check("the set has ten poses", #recorded.vectors == 10, #recorded.vectors)

local worst = 0
for _, vector in recorded.vectors do
	-- A step after the first is applied on top of the pose so far, as a relative edit is.
	local pose = nil
	for _, step in vector.steps do
		local this = decode(step.position, step.rotation)
		pose = if pose then pose * this else this
	end
	local ours = { pose:GetComponents() }
	local largest = 0
	for index, studio in vector.studio do
		largest = math.max(largest, math.abs(ours[index] - studio))
	end
	worst = math.max(worst, largest)
	check(`"{vector.name}" agrees with Studio within {LIMIT}`, #vector.studio == 12 and largest <= LIMIT, largest)
end

print(`{count - failures}/{count} vector checks passed; largest difference from Studio {string.format("%.3g", worst)}`)
if failures > 0 then
	process.exit(1)
end
