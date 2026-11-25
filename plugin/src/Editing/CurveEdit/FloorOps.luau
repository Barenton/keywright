--!strict
-- Putting the body on the floor, and keeping a hand or foot off it.

local Frames = require("./Frames")
local Body = require("./Body")
local Limb = require("../../Rigs/Limb")
local Need = require("./Need")
local Pose = require("../../Rigs/Pose")
local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")
local Store = require("./Store")
local Write = require("./Write")

local count = Frames.count
local FLOORED = Body.FLOORED
local floorOf = Body.floorOf
local FRAME_SLACK = Frames.FRAME_SLACK
local hasGeometry = Body.hasGeometry
local isFinite = Need.isFinite
local milliseconds = Need.milliseconds
local needBlends = Need.needBlends
local needJoint = Need.needJoint
local needJoints = Need.needJoints
local needOneOf = Need.needOneOf
local needRange = Need.needRange
local readChannels = Frames.readChannels
local refuse = Need.refuse
local rounded = Need.rounded
local smoothstep = Frames.smoothstep
local spanOf = Frames.spanOf
local transformsAt = Frames.transformsAt
local writeFrames = Write.writeFrames
local writeTurns = Write.writeTurns

type Changed = Frames.Changed
type Context = Frames.Context

local Ops = {}

Ops.place_on_floor = {
	-- Its range may run across a looping clip's end (see Seam).
	wraps = true,

	check = function(where: string, operation: any, joints: { [string]: any })
		needRange(where, operation, true)
		if operation.mode ~= nil then
			needOneOf(where, operation.mode, "mode", Store.FLOOR_MODES)
		end
		needJoints(where, operation.parts, joints)
		needBlends(where, operation)
	end,

	apply = function(where: string, clip: Instance, operation: any, context: Context, changed: Changed)
		local joints = context.joints
		if not hasGeometry(joints, Rig.R15_ORDER) then
			refuse(where, "this rig's parts could not be measured, so the floor cannot be found.")
		end
		local duration = Store.duration(clip)
		if operation.time_to > duration + Store.TIME_TOLERANCE then
			refuse(
				where,
				`the clip ends at {milliseconds(duration)} seconds, before time_to.`,
				"Key the clip out to its full length first."
			)
		end
		local from, to = operation.time_from, operation.time_to
		local first = math.max(0, from - (operation.blend_in or 0))
		local last = math.min(duration, to + (operation.blend_out or 0))
		local rate = Store.FRAME_RATE
		local firstFrame = math.ceil(first * rate - FRAME_SLACK)
		local lastFrame = math.floor(last * rate + FRAME_SLACK)
		if lastFrame < firstFrame then
			refuse(where, "the range holds no whole frame; Studio shows a curve clip only at whole frames.")
		end
		local touch = operation.mode == "touch"
		local parts = operation.parts or FLOORED
		local floor = floorOf(joints)
		local channels = readChannels(clip)
		local scan = { joints = joints } :: any
		local identity = Roblox.CFrame.new()
		-- The hips' position is measured in the root joint's own frame; straight up in the
		-- rig is this direction there.
		local c0 = Rig.rest(joints.LowerTorso)
		local up = c0:VectorToObjectSpace(Roblox.Vector3.new(0, 1, 0))

		local moves: { number } = {}
		local raised, lowered, moved = 0, 0, 0
		for frame = firstFrame, lastFrame do
			local time = frame / rate
			local lowest = math.huge
			for _, part in Pose.track(scan, transformsAt(channels, time), identity, parts) do
				lowest = math.min(lowest, part.lowest)
			end
			local move = floor - lowest
			if not touch then
				move = math.max(0, move)
			end
			if time < from - Store.TIME_TOLERANCE then
				move *= smoothstep((time - first) / math.max(from - first, 1e-6))
			elseif time > to + Store.TIME_TOLERANCE then
				move *= smoothstep((last - time) / math.max(last - to, 1e-6))
			end
			if math.abs(move) > 0.001 then
				moved += 1
			end
			raised = math.max(raised, move)
			lowered = math.max(lowered, -move)
			table.insert(moves, move)
		end
		count(changed, "frames_moved", moved)
		if moved == 0 then
			return
		end
		changed.largest_raise_studs = math.max(changed.largest_raise_studs or 0, rounded(raised, 3))
		if lowered > 0 then
			changed.largest_drop_studs = math.max(changed.largest_drop_studs or 0, rounded(lowered, 3))
		end
		local own = channels.LowerTorso or {}
		for axis, letter in { "x", "y", "z" } do
			local share = ({ up.X, up.Y, up.Z })[axis]
			if math.abs(share) < 1e-9 then
				continue
			end
			local channel = `position.{letter}`
			local original = own[channel] or {}
			local values = {}
			for index, move in moves do
				values[index] = Store.evaluate(original, (firstFrame + index - 1) / rate) + move * share
			end
			writeFrames(clip, "LowerTorso", channel, original, {
				first = firstFrame,
				last = lastFrame,
				values = values,
				duration = duration,
			}, changed)
		end
	end,
}

Ops.clear_floor = {
	-- Its range may run across a looping clip's end (see Seam).
	wraps = true,

	check = function(where: string, operation: any, joints: { [string]: any })
		local chain = if type(operation.part) == "string" then Limb.CHAINS[operation.part] else nil
		if not chain then
			refuse(where, "part must be LeftFoot, RightFoot, LeftHand or RightHand.")
		end
		for _, name in chain :: { string } do
			needJoint(where, name, joints)
		end
		needRange(where, operation, true)
		local clearance = operation.clearance
		if clearance ~= nil and (not isFinite(clearance) or clearance < 0 or clearance > 2) then
			refuse(where, "clearance must be from 0 to 2 studs.")
		end
		needBlends(where, operation)
	end,

	apply = function(where: string, clip: Instance, operation: any, context: Context, changed: Changed)
		local joints = context.joints
		if not hasGeometry(joints, Rig.R15_ORDER) then
			refuse(where, "this rig's parts could not be measured, so the floor cannot be found.")
		end
		local span = spanOf(where, clip, operation)
		local chain = Limb.CHAINS[operation.part]
		local limb = { joints[chain[1]], joints[chain[2]], joints[chain[3]] }
		local channels = readChannels(clip)
		local scan = { joints = joints } :: any
		local identity = Roblox.CFrame.new()
		local lowestAllowed = floorOf(joints) + (operation.clearance or 0.05)
		local rate = Store.FRAME_RATE
		local turns: { [string]: { CFrame } } = { [chain[1]] = {}, [chain[2]] = {}, [chain[3]] = {} }
		local lifted, highest, missed = 0, 0, 0
		for frame = span.first, span.last do
			local index = frame - span.first + 1
			local time = frame / rate
			local transforms = transformsAt(channels, time)
			local placed = Pose.place(scan, transforms, identity)
			local current = { transforms[chain[1]], transforms[chain[2]], transforms[chain[3]] }
			local lowest = Pose.track(scan, transforms, identity, { chain[3] })[chain[3]].lowest
			-- How far short of the clearance it is, eased over the blends.
			local short = (lowestAllowed - lowest) * span.weight(time)
			local result = current
			if short > 0.0005 then
				-- Straight up by that much, turned as it is.
				local tip = Roblox.CFrame.new(0, short, 0) * placed[chain[3]]
				local solution = Limb.solve({
					parent = placed[Rig.R15_PARENTS[chain[1]]],
					joints = limb,
					current = current,
					pivot = Limb.pivotOf(limb[3], tip),
					tip = tip,
					bend = Limb.BEND[operation.part],
				})
				result = solution.transforms
				lifted += 1
				highest = math.max(highest, short)
				if solution.beyond then
					missed += 1
				end
			end
			for position, joint in chain do
				turns[joint][index] = result[position]
			end
		end
		count(changed, "frames_lifted", lifted)
		if lifted == 0 then
			return
		end
		for _, joint in chain do
			writeTurns(
				clip,
				joint,
				channels[joint] or {},
				span.first,
				span.last,
				turns[joint],
				Store.duration(clip),
				changed,
				true
			)
		end
		changed.largest_lift_studs = math.max(changed.largest_lift_studs or 0, rounded(highest, 3))
		if missed > 0 then
			count(changed, "frames_out_of_reach", missed)
		end
	end,
}

return Ops
