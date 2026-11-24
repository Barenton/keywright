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
-- same way. `Pose.compare` is how that is checked: it measures the difference between
-- these positions and the ones Studio gave the parts of a rig.

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

-- Where each driven part is, relative to the root part, by name and unrounded.
-- `transforms` must hold the transform of every joint; `identity` is the identity CFrame.
function Pose.place(scan: Rig.Scan, transforms: { [string]: CFrame }, identity: CFrame): { [string]: CFrame }
	local placed: { [string]: CFrame } = { [Rig.ROOT] = identity }
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
		placed[name] = parent * c0 * transform * c1:Inverse()
	end
	placed[Rig.ROOT] = nil
	return placed
end

export type Difference = {
	-- How many parts were compared.
	parts: number,
	-- The largest distance between where a part was expected and where it was, in studs.
	studs: number,
	-- The largest turn between the expected and the actual rotation of a part, in degrees.
	degrees: number,
	-- The part with the largest distance, or the largest turn if no part is displaced.
	worst: string?,
}

-- The largest difference between two sets of part positions, matched by name.
function Pose.compare(expected: { [string]: CFrame }, actual: { [string]: CFrame }): Difference
	local difference: Difference = { parts = 0, studs = 0, degrees = 0, worst = nil }
	local worstTurn: string? = nil
	for name, wanted in expected do
		local found = actual[name]
		if not found then
			continue
		end
		difference.parts += 1
		local studs = (wanted.Position - found.Position).Magnitude
		if studs > difference.studs then
			difference.studs = studs
			difference.worst = name
		end
		-- The three directions of a rotation each move by an amount that depends on the
		-- angle turned; their squares add up to eight times the squared sine of half of
		-- it. Unlike reading the angle off the rotation itself, this stays exact for the
		-- very small angles being measured here.
		local squares = (wanted.RightVector - found.RightVector).Magnitude ^ 2
			+ (wanted.UpVector - found.UpVector).Magnitude ^ 2
			+ (wanted.LookVector - found.LookVector).Magnitude ^ 2
		local degrees = math.deg(2 * math.asin(math.min(1, math.sqrt(squares / 8))))
		if degrees > difference.degrees then
			difference.degrees = degrees
			worstTurn = name
		end
	end
	difference.worst = difference.worst or worstTurn
	return difference
end

-- Returns one entry for each driven part of the rig, in the rig's standard order.
-- `transforms` must hold the transform of every joint; `identity` is the identity CFrame.
function Pose.parts(scan: Rig.Scan, transforms: { [string]: CFrame }, identity: CFrame): { Part }
	local placed = Pose.place(scan, transforms, identity)
	local parts: { Part } = {}
	for _, name in Rig.R15_ORDER do
		local joint = scan.joints[name]
		local cframe = placed[name]
		if not joint or not cframe then
			continue
		end
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
