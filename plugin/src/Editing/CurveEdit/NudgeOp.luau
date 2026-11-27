--!strict
-- Moving a hand or foot off its own path for a few frames, by an offset that eases in and
-- out: a kicking foot lifted at the chamber, a punch carried a little higher. Unlike pin,
-- which holds the part at one point, the part keeps travelling along its own motion,
-- moved by the offset, so a fast limb is not dragged back toward where a pin held it.

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
local FRAME_SLACK = Frames.FRAME_SLACK
local hasGeometry = Body.hasGeometry
local isFinite = Need.isFinite
local milliseconds = Need.milliseconds
local needBlends = Need.needBlends
local needJoint = Need.needJoint
local needOneOf = Need.needOneOf
local needRange = Need.needRange
local readChannels = Frames.readChannels
local refuse = Need.refuse
local rounded = Need.rounded
local smoothstep = Frames.smoothstep
local transformsAt = Frames.transformsAt
local writeTurns = Write.writeTurns

type Changed = Frames.Changed
type Context = Frames.Context

local Ops = {}

Ops.nudge = {
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
		local offset = operation.offset
		if type(offset) ~= "table" or #offset ~= 3 then
			refuse(where, "offset must be three numbers: studs toward the rig's right, up, and toward its back.")
		end
		for _, value in offset do
			if not isFinite(value) or math.abs(value) > Store.MAX_POSITION then
				refuse(where, `each number of offset must be finite and at most {Store.MAX_POSITION} studs.`)
			end
		end
		if operation.hold ~= nil then
			needOneOf(where, operation.hold, "hold", Store.HOLDS)
		end
		local soft = operation.soft
		if soft ~= nil and (not isFinite(soft) or soft < 0 or soft > 0.5) then
			refuse(where, "soft must be from 0 to 0.5.")
		end
		needBlends(where, operation)
	end,

	apply = function(where: string, clip: Instance, operation: any, context: Context, changed: Changed)
		local chain = Limb.CHAINS[operation.part]
		local joints = context.joints
		if not hasGeometry(joints, chain) then
			refuse(where, "this rig's limb could not be measured, so nothing can be moved on it.")
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

		-- Everything is worked out from the clip as it is, before anything is written.
		local channels = readChannels(clip)
		local scan = { joints = joints } :: any
		local identity = Roblox.CFrame.new()
		local limb = { joints[chain[1]], joints[chain[2]], joints[chain[3]] }
		local shift = Roblox.Vector3.new(operation.offset[1], operation.offset[2], operation.offset[3])
		-- full: the part is moved without turning, as a point dragged along its trail.
		-- position: only where it is moves, and it turns with the limb.
		local full = (operation.hold or "full") == "full"

		local frames: { { CFrame } } = {}
		local missed, worst, softened, largest = 0, 0, 0, 0
		local missedFrom, missedTo = math.huge, -math.huge
		for frame = firstFrame, lastFrame do
			local time = frame / rate
			local transforms = transformsAt(channels, time)
			local current = { transforms[chain[1]], transforms[chain[2]], transforms[chain[3]] }
			-- How much of the offset applies here: all of it from time_from to time_to,
			-- easing in before and out after.
			local weight = 1
			if time < from - Store.TIME_TOLERANCE then
				weight = smoothstep((time - first) / math.max(from - first, 1e-6))
			elseif time > to + Store.TIME_TOLERANCE then
				weight = smoothstep((last - time) / math.max(last - to, 1e-6))
			end
			if weight <= 0 then
				table.insert(frames, current)
				continue
			end
			local placed = Pose.place(scan, transforms, identity)
			-- Where the part's own motion has it now, moved by its share of the offset.
			local tip = Roblox.CFrame.new(shift * weight) * placed[chain[3]]
			local solution = Limb.solve({
				parent = placed[Rig.R15_PARENTS[chain[1]]],
				joints = limb,
				current = current,
				pivot = Limb.pivotOf(limb[3], tip),
				tip = if full then tip else nil,
				bend = Limb.BEND[operation.part],
				-- Eased in with the offset, so a limb near full stretch doesn't jump on the
				-- first frame of the blend.
				soft = if operation.soft then operation.soft * weight else nil,
			})
			largest = math.max(largest, shift.Magnitude * weight)
			if not solution.beyond and solution.miss > 0.001 then
				-- Short of the point only because the reach was softened.
				softened = math.max(softened, solution.miss)
			elseif solution.miss > 0.001 then
				missed += 1
				worst = math.max(worst, solution.miss)
				missedFrom = math.min(missedFrom, time)
				missedTo = math.max(missedTo, time)
			end
			table.insert(frames, solution.transforms)
		end

		-- The three joints' rotation keys in the range are replaced by one key a frame.
		for index, joint in chain do
			local turns = {}
			for frame, entry in frames do
				turns[frame] = entry[index]
			end
			writeTurns(clip, joint, channels[joint] or {}, firstFrame, lastFrame, turns, duration, changed, false)
		end
		count(changed, "frames_nudged", #frames)
		changed.largest_nudge_studs = math.max(changed.largest_nudge_studs or 0, rounded(largest, 3))
		if softened > 0 then
			changed.largest_soft_studs = math.max(changed.largest_soft_studs or 0, rounded(softened, 3))
		end
		if missed > 0 then
			count(changed, "frames_out_of_reach", missed)
			changed.largest_miss_studs = math.max(changed.largest_miss_studs or 0, rounded(worst, 3))
			changed.out_of_reach_from = math.min(changed.out_of_reach_from or math.huge, milliseconds(missedFrom))
			changed.out_of_reach_to = math.max(changed.out_of_reach_to or -math.huge, milliseconds(missedTo))
		end
	end,
}

return Ops
