--!strict
-- Reaching: the turns of a limb's three joints that put the part at its end where it is
-- wanted, as an arm puts a hand on a wall or a leg keeps a foot on the ground.
--
-- A limb here is a chain of three joints: the upper joint (hip or shoulder), the middle
-- one (knee or elbow) and the end one (ankle or wrist). The middle joint is a hinge: it
-- turns only about its own X axis, which is how an R15 knee and elbow bend. With that,
-- how far the end joint lies from the upper one depends on the middle joint's angle
-- alone, so the angle is worked out exactly first. The upper joint is then turned so the
-- end joint lands on the point wanted, by the smallest turn from the pose the limb
-- already has, so the knee or elbow keeps pointing the way it was animated unless a
-- direction is asked for. Last, the end part itself can be turned to a rotation wanted.
--
-- The rest offsets of the three joints are used as they are, so a knee that sits off
-- the line of the leg, as on a real R15 rig, is reached exactly too. A point out of
-- reach is reached for as far as the limb goes, and the result says by how much it fell
-- short.
--
-- Nothing here reads or writes anything; every function only computes from what it is
-- handed. Positions are relative to the rig's root part, as in Pose.

local Roblox = require("../Core/Roblox")
local Rig = require("./Rig")

local Limb = {}

-- The three joints of each limb, from the body outward, by the part each drives.
Limb.CHAINS = {
	LeftFoot = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" },
	RightFoot = { "RightUpperLeg", "RightLowerLeg", "RightFoot" },
	LeftHand = { "LeftUpperArm", "LeftLowerArm", "LeftHand" },
	RightHand = { "RightUpperArm", "RightLowerArm", "RightHand" },
} :: { [string]: { string } }

-- Which way the middle joint bends, as the sign of its turn about X: a positive turn
-- swings the far end forward, so a knee bends with a negative one and an elbow with a
-- positive one.
Limb.BEND = { LeftFoot = -1, RightFoot = -1, LeftHand = 1, RightHand = 1 } :: { [string]: number }

export type Solution = {
	-- The new transforms of the three joints, in chain order. Each keeps the position
	-- part of the transform it had.
	transforms: { CFrame },
	-- How far the end joint is from where it was wanted, in studs: 0 when it was reached.
	miss: number,
	-- Whether the point was out of the limb's reach, too far or too near for it to fold
	-- to, as against only softened.
	beyond: boolean,
}

local function turnOf(cframe: CFrame): CFrame
	return cframe - cframe.Position
end

local function wrap(angle: number): number
	return (angle + math.pi) % (2 * math.pi) - math.pi
end

-- The smallest turn that takes one direction to another.
local function arc(from: Vector3, to: Vector3): CFrame
	local identity = Roblox.CFrame.new()
	if from.Magnitude < 1e-9 or to.Magnitude < 1e-9 then
		return identity
	end
	local a, b = from.Unit, to.Unit
	local axis = a:Cross(b)
	local sine, cosine = axis.Magnitude, a:Dot(b)
	if sine < 1e-9 then
		if cosine > 0 then
			return identity
		end
		-- Opposite directions: half a turn about any direction square to them.
		local other = if math.abs(a.X) < 0.9 then Roblox.Vector3.new(1, 0, 0) else Roblox.Vector3.new(0, 1, 0)
		return Roblox.CFrame.fromAxisAngle(a:Cross(other).Unit, math.pi)
	end
	return Roblox.CFrame.fromAxisAngle(axis.Unit, math.atan2(sine, cosine))
end

Limb.arc = arc

export type Request = {
	-- Where the part the limb hangs from is: the lower torso for a leg, the upper torso
	-- for an arm.
	parent: CFrame,
	-- The limb's three joints and the transforms they have now, in chain order.
	joints: { Rig.Joint },
	current: { CFrame },
	-- Where the end joint (the ankle or wrist) is to be.
	pivot: Vector3,
	-- If given, the rotation the end part (the foot or hand) is to have. Otherwise it
	-- keeps the turn it has against the joint before it.
	tip: CFrame?,
	-- The sign the middle joint bends with; see Limb.BEND.
	bend: number,
	-- If given, a point the middle joint is to point toward.
	pole: Vector3?,
	-- How much of the turn toward the pole to make, from 0 to 1. Default 1.
	poleWeight: number?,
	-- The last share of the limb's reach, from 0 to 0.5, over which a point is reached for
	-- ever more slowly and never quite reached, so the limb never locks straight and its
	-- middle joint does not snap through its last few degrees. Default 0: exact.
	soft: number?,
}

-- How far the end joint of a limb can be from its upper joint: with the middle joint as
-- straight as it goes. `current` is the limb's three transforms, whose positions are kept.
function Limb.fullest(joints: { Rig.Joint }, current: { CFrame }): number
	local CFrame = Roblox.CFrame
	local _, c1u = Rig.rest(joints[1])
	local c0m, c1m = Rig.rest(joints[2])
	local c0t = Rig.rest(joints[3])
	local toMiddle = c1u:Inverse() * c0m * CFrame.new(current[2].Position)
	local toEnd = c1m:Inverse() * c0t * CFrame.new(current[3].Position)
	local u = toMiddle:Inverse().Position
	local n = toEnd.Position
	local p = u.Y * n.Y + u.Z * n.Z
	local q = u.Z * n.Y - u.Y * n.Z
	local size = math.sqrt(p * p + q * q)
	return math.sqrt(math.max(0, n:Dot(n) + u:Dot(u) - 2 * u.X * n.X + 2 * size))
end

-- Where a limb's upper joint (the hip or shoulder) is, on its parent part placed at `parent`.
function Limb.upperOf(parent: CFrame, joint: Rig.Joint, current: CFrame): Vector3
	local c0 = Rig.rest(joint)
	return (parent * c0 * Roblox.CFrame.new(current.Position)).Position
end

function Limb.solve(request: Request): Solution
	local CFrame = Roblox.CFrame
	local c0u, c1u = Rig.rest(request.joints[1])
	local c0m, c1m = Rig.rest(request.joints[2])
	local c0t, c1t = Rig.rest(request.joints[3])
	local current = request.current

	-- The upper joint's point, as a frame; a joint's own offset is kept as it is.
	local upper = request.parent * c0u * CFrame.new(current[1].Position)
	-- From the upper part's frame to the middle joint, and from the middle part's frame
	-- to the end joint.
	local toMiddle = c1u:Inverse() * c0m * CFrame.new(current[2].Position)
	local toEnd = c1m:Inverse() * c0t * CFrame.new(current[3].Position)

	-- The middle joint's angle: the one that puts the end joint as far from the upper
	-- joint as the point wanted. Seen from the middle joint, the upper joint is at `u`
	-- and the end joint at `n` turned about X; the distance between them is a sum of a
	-- cosine and a sine of the angle, which is solved exactly.
	local wanted = upper:PointToObjectSpace(request.pivot)
	local distance = wanted.Magnitude
	local u = toMiddle:Inverse().Position
	local n = toEnd.Position
	local p = u.Y * n.Y + u.Z * n.Z
	local q = u.Z * n.Y - u.Y * n.Z
	local size = math.sqrt(p * p + q * q)
	local fullest = Limb.fullest(request.joints, current)
	-- As near as the end joint comes to the upper one, with the middle joint folded as far
	-- as it goes: a point nearer than that is out of reach too.
	local nearest = math.sqrt(math.max(0, n:Dot(n) + u:Dot(u) - 2 * u.X * n.X - 2 * size))
	local beyond = distance > fullest + 1e-6 or distance < nearest - 1e-6
	local soft = request.soft or 0
	if soft > 0 and distance > 1e-6 then
		local start = (1 - soft) * fullest
		if distance > start then
			local room = fullest - start
			local eased = start + room * (1 - math.exp(-(distance - start) / room))
			wanted = wanted.Unit * eased
			distance = eased
		end
	end
	local c = (n:Dot(n) + u:Dot(u) - distance * distance) / 2 - u.X * n.X
	local now = select(1, current[2]:ToEulerAnglesXYZ())
	local angle = now
	if size > 1e-9 then
		local phi = math.atan2(q, p)
		local spread = math.acos(math.clamp(c / size, -1, 1))
		local first, second = wrap(phi + spread), wrap(phi - spread)
		local firstBends = first * request.bend >= -1e-6
		local secondBends = second * request.bend >= -1e-6
		if firstBends ~= secondBends then
			angle = if firstBends then first else second
		else
			angle = if math.abs(wrap(first - now)) <= math.abs(wrap(second - now)) then first else second
		end
	end
	local middle = CFrame.Angles(angle, 0, 0)

	-- The upper joint's turn: from the one it has, the smallest turn that brings the end
	-- joint onto the line to the point wanted.
	local reach = (toMiddle * middle * toEnd).Position
	local before = turnOf(current[1])
	local turned = arc(before:VectorToWorldSpace(reach), wanted) * before

	-- A direction for the middle joint: turn the whole limb about the line from the
	-- upper joint to the point, until the middle joint is on the side of the pole.
	if request.pole and distance > 1e-6 then
		local axis = wanted.Unit
		local knee = turned:VectorToWorldSpace(toMiddle.Position)
		local pole = upper:PointToObjectSpace(request.pole)
		local kneeFlat = knee - axis * axis:Dot(knee)
		local poleFlat = pole - axis * axis:Dot(pole)
		if kneeFlat.Magnitude > 1e-6 and poleFlat.Magnitude > 1e-6 then
			local spin = math.atan2(axis:Dot(kneeFlat:Cross(poleFlat)), kneeFlat:Dot(poleFlat))
				* (request.poleWeight or 1)
			turned = CFrame.fromAxisAngle(axis, spin) * turned
		end
	end

	local reached = upper:PointToWorldSpace(turned:VectorToWorldSpace(reach))
	local tipTurn = turnOf(current[3])
	if request.tip then
		local joint = upper * turned * toMiddle * middle * toEnd
		tipTurn = turnOf(joint:Inverse() * request.tip * c1t)
	end
	return {
		transforms = {
			CFrame.new(current[1].Position) * turned,
			CFrame.new(current[2].Position) * middle,
			CFrame.new(current[3].Position) * tipTurn,
		},
		miss = (reached - request.pivot).Magnitude,
		beyond = beyond,
	}
end

-- Where the end joint of a limb is, for the end part placed at `tip`.
function Limb.pivotOf(endJoint: Rig.Joint, tip: CFrame): Vector3
	local _, c1 = Rig.rest(endJoint)
	return (tip * c1).Position
end

return Limb
