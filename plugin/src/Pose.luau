--!strict
-- Works out where every part of a rig is for a set of joint transforms.
--
-- This is plain forward kinematics: each driven part sits at its parent's position, moved
-- by the joint's rest offsets and its transform. Nothing here reads where Studio has
-- drawn anything, and nothing is written. Positions are relative to the rig's root part,
-- so the result says nothing about where the rig stands in the place.
--
-- The result is what the relay draws a picture of the pose from. For a Motor6D this is
-- the engine's own rule. An AnimationConstraint is documented to apply its transform the
-- same way; that has not been compared against Studio.

local Errors = require("./Errors")
local Rig = require("./Rig")

local Pose = {}

export type Part = {
	name: string,
	-- Size of the part's box in studs.
	size: { number },
	-- Position, then the nine entries of the rotation matrix, row by row.
	cframe: { number },
}

local function round(value: number): number
	return math.round(value * 10000) / 10000
end

-- Returns one entry for each driven part of the rig, in the rig's standard order.
-- `transforms` must hold the transform of every joint; `identity` is the identity CFrame.
function Pose.parts(scan: Rig.Scan, transforms: { [string]: CFrame }, identity: CFrame): { Part }
	local placed: { [string]: CFrame } = { [Rig.ROOT] = identity }
	local parts: { Part } = {}
	for _, name in Rig.R15_ORDER do
		local joint = scan.joints[name]
		if not joint then
			continue
		end
		local parent = placed[Rig.R15_PARENTS[name]]
		local transform = transforms[name]
		if not parent or not transform then
			Errors.throw("PREVIEW_UNAVAILABLE", `The pose of "{name}" could not be worked out.`)
		end
		local c0, c1 = Rig.rest(joint)
		local cframe = parent * c0 * transform * c1:Inverse()
		placed[name] = cframe
		local components = { cframe:GetComponents() }
		for index, value in components do
			components[index] = round(value)
		end
		local size = joint.part1.Size
		table.insert(parts, {
			name = name,
			size = { round(size.X), round(size.Y), round(size.Z) },
			cframe = components,
		})
	end
	return parts
end

return Pose
