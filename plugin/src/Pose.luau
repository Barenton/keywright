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

Pose.TURNS_NOTE =
	"For each joint: where the far end of its part moves when the pose's rotation about X, then Y, then Z, is positive, in the rig's own directions. \"twist\" means the part turns about its own length. A negative rotation goes the other way."

local function direction(move: Vector3, length: number): string
	if move.Magnitude < 0.3 * length then
		return "twist"
	end
	local x, y, z = math.abs(move.X), math.abs(move.Y), math.abs(move.Z)
	if x >= y and x >= z then
		return if move.X > 0 then "right" else "left"
	elseif y >= z then
		return if move.Y > 0 then "up" else "down"
	end
	-- A rig faces along negative Z.
	return if move.Z > 0 then "back" else "forward"
end

-- For each joint, which way the far end of its part moves under a positive rotation about
-- each of the pose's axes, worked out from the rig's rest pose. A list of three words per
-- joint, for X, Y and Z.
function Pose.turns(scan: Rig.Scan, identity: CFrame): { [string]: { string } }
	local resting: { [string]: CFrame } = {}
	for name in scan.joints do
		resting[name] = identity
	end
	local placed = Pose.place(scan, resting, identity)
	placed[Rig.ROOT] = identity
	local turns: { [string]: { string } } = {}
	for name, joint in scan.joints do
		local parent = placed[Rig.R15_PARENTS[name]]
		local part = placed[name]
		if not parent or not part then
			continue
		end
		-- The joint turns about the point where it sits on the parent, in that frame.
		local pivot = parent * (Rig.rest(joint))
		-- The far end is where the next joint down sits, if there is one: for the lower
		-- torso that is the waist, with the whole upper body on it, whichever side of the
		-- joint the lower torso's own middle happens to be. Otherwise it is the part's middle.
		local far = part.Position
		for _, other in Rig.R15_ORDER do
			local child = scan.joints[other]
			if child and Rig.R15_PARENTS[other] == name then
				far = (part * (Rig.rest(child))).Position
				break
			end
		end
		local reach = far - pivot.Position
		-- A joint often sits at a corner of its part, as a shoulder does, so the far end
		-- is rarely straight out from it. What matters is which way the part extends:
		-- the one of its own three directions that the far end lies furthest along.
		local best: Vector3 = part.UpVector
		for _, axis in { part.RightVector, part.LookVector } do
			if math.abs(reach:Dot(axis)) > math.abs(reach:Dot(best)) then
				best = axis
			end
		end
		reach = best * reach:Dot(best)
		local length = math.max(reach.Magnitude, 1e-6)
		turns[name] = {
			direction(pivot.RightVector:Cross(reach), length),
			direction(pivot.UpVector:Cross(reach), length),
			direction((-pivot.LookVector):Cross(reach), length),
		}
	end
	return turns
end

export type Tracked = {
	-- The middle of the part: x toward the rig's right, y up, z toward its back, in studs
	-- from the root part.
	position: { number },
	-- The height of the part's lowest point: what touches the ground first.
	lowest: number,
}

local function thousandths(value: number): number
	return math.round(value * 1000) / 1000
end

-- Where the named parts are for a set of joint transforms, relative to the root part.
function Pose.track(
	scan: Rig.Scan,
	transforms: { [string]: CFrame },
	identity: CFrame,
	names: { string }
): { [string]: Tracked }
	local placed = Pose.place(scan, transforms, identity)
	local tracked: { [string]: Tracked } = {}
	for _, name in names do
		local cframe = placed[name]
		local joint = scan.joints[name]
		if not cframe or not joint then
			continue
		end
		local size = joint.part1.Size
		-- How far the box reaches below its middle, whichever way it is turned.
		local drop = (
			math.abs(cframe.RightVector.Y) * size.X
			+ math.abs(cframe.UpVector.Y) * size.Y
			+ math.abs(cframe.LookVector.Y) * size.Z
		) / 2
		local position = cframe.Position
		tracked[name] = {
			position = { thousandths(position.X), thousandths(position.Y), thousandths(position.Z) },
			lowest = thousandths(position.Y - drop),
		}
	end
	return tracked
end

-- Adds to each moment after the first how fast each tracked part moved since the moment
-- before: `velocity`, in studs per second along x, y and z, and `speed`, its size.
-- `times` gives the time of each moment.
function Pose.speeds(moments: { { [string]: any } }, times: { number })
	for index = 2, #moments do
		local seconds = times[index] - times[index - 1]
		if seconds <= 0 then
			continue
		end
		for name, tracked in moments[index] do
			local before = moments[index - 1][name]
			if before then
				local velocity = {}
				local squares = 0
				for axis = 1, 3 do
					local rate = (tracked.position[axis] - before.position[axis]) / seconds
					velocity[axis] = math.round(rate * 100) / 100
					squares += rate * rate
				end
				tracked.velocity = velocity
				tracked.speed = math.round(math.sqrt(squares) * 100) / 100
			end
		end
	end
end

-- Over several moments, how far each tracked part ranges: the least and greatest of each
-- coordinate of its middle and of its lowest point, and the difference between them.
function Pose.ranges(moments: { { [string]: Tracked } }): { [string]: any }
	local ranges: { [string]: any } = {}
	for _, moment in moments do
		for name, tracked in moment do
			local values = { tracked.position[1], tracked.position[2], tracked.position[3], tracked.lowest }
			local range = ranges[name]
			if not range then
				range = { low = table.clone(values), high = table.clone(values) }
				ranges[name] = range
			end
			for index, value in values do
				range.low[index] = math.min(range.low[index], value)
				range.high[index] = math.max(range.high[index], value)
			end
		end
	end
	local summary: { [string]: any } = {}
	for name, range in ranges do
		local function span(index: number): { number }
			return { range.low[index], range.high[index], thousandths(range.high[index] - range.low[index]) }
		end
		-- Each is the least, the greatest, and the distance between them.
		summary[name] = { x = span(1), y = span(2), z = span(3), lowest = span(4) }
	end
	return summary
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
