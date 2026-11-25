--!strict
-- The rig's body as the operations need it: whether it can be measured, the floor, the
-- parts measured against it, and the mirror image of a side.

local Need = require("./Need")
local Pose = require("../../Rigs/Pose")
local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")

local rounded = Need.rounded

local Body = {}

-- Whether the joints given are the rig's own, with its parts, and not only their names.
local function hasGeometry(joints: { [string]: any }, names: { string }): boolean
	for _, name in names do
		local joint = joints[name]
		if type(joint) ~= "table" or joint.part1 == nil or joint.instance == nil then
			return false
		end
	end
	return true
end

-- Parts are measured against the floor as boxes of their size. A lower leg's box reaches
-- down beside the ankle, so in a deep crouch, with the shin tilted forward, the box's back
-- corner dips below the floor while the shin itself, which is slimmer there, stays above
-- it (seen in Studio, 2026-11-25). The lower legs are left out of every floor measure.
local NOT_FLOORED = { LeftLowerLeg = true, RightLowerLeg = true }

-- The parts measured against the floor.
local FLOORED: { string } = {}
for _, name in Rig.R15_ORDER do
	if not NOT_FLOORED[name] then
		table.insert(FLOORED, name)
	end
end

-- The floor: how high the rig's lowest point is in its rest pose, relative to the root
-- part. For a character, that is the soles of its feet.
local function floorOf(joints: { [string]: any }): number
	local identity = Roblox.CFrame.new()
	local rest: { [string]: CFrame } = {}
	for _, name in Rig.R15_ORDER do
		rest[name] = identity
	end
	local floor = math.huge
	for _, part in Pose.track({ joints = joints } :: any, rest, identity, Rig.R15_ORDER) do
		floor = math.min(floor, part.lowest)
	end
	return floor
end

-- The name of a joint's counterpart on the other side, or its own name in the middle.
local function counterpart(name: string): string
	if string.sub(name, 1, 4) == "Left" then
		return "Right" .. string.sub(name, 5)
	elseif string.sub(name, 1, 5) == "Right" then
		return "Left" .. string.sub(name, 6)
	end
	return name
end

local MIRROR_SIGN = {
	["rotation.x"] = 1,
	["rotation.y"] = -1,
	["rotation.z"] = -1,
	["position.x"] = -1,
	["position.y"] = 1,
	["position.z"] = 1,
}

-- A frame seen in the mirror.
local function reflected(cframe: CFrame): CFrame
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cframe:GetComponents()
	return Roblox.CFrame.new(-x, y, z, r00, -r01, -r02, -r10, r11, r12, -r20, r21, r22)
end

-- Why the rig's sides are not mirror images of each other, or nil when they are. Joints
-- in the middle must be their own mirror image.
local function asymmetry(joints: { [string]: any }): string?
	for _, name in Rig.R15_ORDER do
		local other = counterpart(name)
		local c0, c1 = Rig.rest(joints[name])
		local d0, d1 = Rig.rest(joints[other])
		for _, pair in { { reflected(c0), d0 }, { reflected(c1), d1 } } do
			local a, b = pair[1], pair[2]
			local studs = (a.Position - b.Position).Magnitude
			local turn = (a.RightVector - b.RightVector).Magnitude + (a.UpVector - b.UpVector).Magnitude
			if studs > 0.01 or turn > 0.02 then
				return if other == name
					then `"{name}" is not centred between the rig's sides ({rounded(studs, 3)} studs off).`
					else `"{name}" and "{other}" are not mirror images of each other ({rounded(studs, 3)} studs apart).`
			end
		end
	end
	return nil
end

Body.hasGeometry = hasGeometry
Body.NOT_FLOORED = NOT_FLOORED
Body.FLOORED = FLOORED
Body.floorOf = floorOf
Body.counterpart = counterpart
Body.MIRROR_SIGN = MIRROR_SIGN
Body.reflected = reflected
Body.asymmetry = asymmetry

return Body
