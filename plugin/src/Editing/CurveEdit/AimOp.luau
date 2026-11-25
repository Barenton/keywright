--!strict
-- Turning a joint to face a point, or holding its facing.

local Body = require("./Body")
local Limb = require("../../Rigs/Limb")
local Need = require("./Need")
local Pose = require("../../Rigs/Pose")
local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")
local Store = require("./Store")
local Write = require("./Write")

local count = Write.count
local hasGeometry = Body.hasGeometry
local isFinite = Need.isFinite
local needBlends = Need.needBlends
local needJoint = Need.needJoint
local needRange = Need.needRange
local needTime = Need.needTime
local needVector = Need.needVector
local readChannels = Write.readChannels
local refuse = Need.refuse
local spanOf = Write.spanOf
local transformsAt = Write.transformsAt
local writeTurns = Write.writeTurns

type Changed = Write.Changed
type Context = Write.Context

local Ops = {}

Ops.aim = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needJoint(where, operation.joint, joints)
		needRange(where, operation)
		needVector(where, operation.target, "target", Store.MAX_POSITION)
		if operation.hold ~= nil and type(operation.hold) ~= "boolean" then
			refuse(where, "hold must be true or false.")
		end
		if (operation.target ~= nil) == (operation.hold == true) then
			refuse(where, "give target, or hold, but not both.")
		end
		if operation.at ~= nil then
			needTime(where, operation.at, "at")
		end
		local weight = operation.weight
		if weight ~= nil and (not isFinite(weight) or weight < 0 or weight > 1) then
			refuse(where, "weight must be from 0 to 1.")
		end
		local limit = operation.limit_degrees
		if limit ~= nil and (not isFinite(limit) or limit <= 0 or limit > 180) then
			refuse(where, "limit_degrees must be more than 0 and at most 180.")
		end
		needBlends(where, operation)
	end,

	apply = function(where: string, clip: Instance, operation: any, context: Context, changed: Changed)
		local joints = context.joints
		if not hasGeometry(joints, Rig.R15_ORDER) then
			refuse(where, "this rig's joints could not be measured, so nothing can be aimed on it.")
		end
		local span = spanOf(where, clip, operation)
		local channels = readChannels(clip)
		local scan = { joints = joints } :: any
		local identity = Roblox.CFrame.new()
		local joint = operation.joint
		local parentName = Rig.R15_PARENTS[joint]
		local c0, c1 = Rig.rest(joints[joint])
		local function turnOf(cframe: CFrame): CFrame
			return cframe - cframe.Position
		end
		local held: CFrame? = nil
		if operation.hold then
			local reference = Pose.place(scan, transformsAt(channels, operation.at or operation.time_from), identity)
			held = turnOf(reference[joint])
		end
		local target = if operation.target
			then Roblox.Vector3.new(operation.target[1], operation.target[2], operation.target[3])
			else nil
		local limit = math.rad(operation.limit_degrees or 180)
		local weight = operation.weight or 1
		local rate = Store.FRAME_RATE
		local turns: { CFrame } = {}
		for frame = span.first, span.last do
			local time = frame / rate
			local transforms = transformsAt(channels, time)
			local placed = Pose.place(scan, transforms, identity)
			local part = placed[joint]
			local parent = placed[parentName] or identity
			-- The turn in the room that would face the part where it is wanted.
			local turn = identity
			if target then
				-- The joint turns about its pivot, which moves the part's middle, and with
				-- it the way to the target: worked out again from where the turn puts it,
				-- a few times over, which settles it.
				local pivot = (parent * c0).Position
				local middle = part.Position
				for _ = 1, 4 do
					local toward = target - middle
					if toward.Magnitude < 1e-6 then
						break
					end
					turn = Limb.arc(part.LookVector, toward.Unit)
					middle = pivot + turn:VectorToWorldSpace(part.Position - pivot)
				end
			else
				turn = (held :: CFrame) * turnOf(part):Inverse()
			end
			local axis, angle = turn:ToAxisAngle()
			angle = math.min(angle, limit) * weight * span.weight(time)
			if math.abs(angle) > 1e-9 and axis.Magnitude > 1e-9 then
				turn = Roblox.CFrame.fromAxisAngle(axis.Unit, angle)
			else
				turn = identity
			end
			-- The joint's own rotation that gives the part that facing, about the point
			-- where the joint is: placed = parent * C0 * transform * C1:Inverse().
			local wanted = turn * turnOf(part)
			local own = turnOf(c0):Inverse() * turnOf(parent):Inverse() * wanted * turnOf(c1)
			turns[frame - span.first + 1] = Roblox.CFrame.new(transforms[joint].Position) * own
		end
		writeTurns(
			clip,
			joint,
			channels[joint] or {},
			span.first,
			span.last,
			turns,
			Store.duration(clip),
			changed,
			true
		)
		count(changed, "frames_aimed", span.last - span.first + 1)
	end,
}

return Ops
