--!strict
-- Smoothing: one smooth curve through each joint's keys, written out as poses.

local Errors = require("../../Core/Errors")
local Need = require("./Need")
local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")
local Sequence = require("./Sequence")
local Smooth = require("../Smooth")
local Write = require("./Write")

local count = Write.count
local dropPose = Write.dropPose
local inRange = Write.inRange
local isFinite = Need.isFinite
local needRange = Need.needRange
local needTime = Need.needTime
local refuse = Need.refuse
local weighted = Write.weighted

type Changed = Sequence.Changed
type Context = Sequence.Context

local Ops = {}

Ops.smooth_motion = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needRange(where, operation)
		if operation.time_to - operation.time_from < Sequence.TIME_TOLERANCE then
			refuse(where, "the range must have some length.")
		end
		if operation.joints ~= nil then
			if
				type(operation.joints) ~= "table"
				or #operation.joints == 0
				or #operation.joints > Sequence.MAX_JOINTS
			then
				refuse(where, `joints must list from 1 to {Sequence.MAX_JOINTS} joint names.`)
			end
			for _, name in operation.joints do
				if type(name) ~= "string" or not joints[name] then
					refuse(where, `the rig has no joint "{tostring(name)}".`, "Call inspect_rig for the joint names.")
				end
			end
		end
		local rate = operation.rate
		if rate ~= nil then
			if
				not isFinite(rate)
				or rate ~= math.floor(rate)
				or rate < Sequence.MIN_RATE
				or rate > Sequence.MAX_RATE
			then
				refuse(where, `rate must be a whole number from {Sequence.MIN_RATE} to {Sequence.MAX_RATE}.`)
			end
		end
		if operation.snap_at ~= nil then
			if type(operation.snap_at) ~= "table" or #operation.snap_at > Sequence.MAX_SNAPS then
				refuse(where, `snap_at must list at most {Sequence.MAX_SNAPS} times.`)
			end
			for _, time in operation.snap_at do
				needTime(where, time, "each time in snap_at")
			end
		end
		if operation.loop ~= nil and type(operation.loop) ~= "boolean" then
			refuse(where, "loop must be true or false.")
		end
	end,

	-- Replaces each chosen joint's keys in a range by one smooth curve through them,
	-- written out as a pose at every step. See Smooth for what the curve is.
	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local from, to = operation.time_from, operation.time_to
		local rate = operation.rate or Sequence.DEFAULT_RATE
		local existing = Sequence.keyframes(sequence)
		local names: { string } = operation.joints or Sequence.animated(sequence)

		-- A clip that loops, smoothed from its first keyframe to its last, carries its
		-- speed across the join unless told otherwise.
		local first, last = existing[1], existing[#existing]
		local whole = #existing > 0
			and math.abs(first.Time - from) < Sequence.TIME_TOLERANCE
			and math.abs(last.Time - to) < Sequence.TIME_TOLERANCE
		local loop = if operation.loop ~= nil then operation.loop else ((sequence :: any).Loop == true and whole)

		-- Everything is worked out before anything is changed.
		type Plan = { name: string, poses: { Pose }, times: { number }, samples: { { number } } }
		local plans: { Plan } = {}
		for _, name in names do
			local keys: { Smooth.Key } = {}
			local poses: { Pose } = {}
			for _, keyframe in existing do
				local pose = if inRange(keyframe.Time, from, to) then weighted(keyframe, name) else nil
				if pose and (#keys == 0 or keyframe.Time - keys[#keys].time > 1e-6) then
					local position = pose.CFrame.Position
					local x, y, z, w = Rig.quaternionOf(pose.CFrame)
					local before = keys[#keys]
					-- A rotation has two quaternions, one the negative of the other. The one
					-- nearer the key before is the one the curve should run to.
					if
						before
						and before.values[4] * x
								+ before.values[5] * y
								+ before.values[6] * z
								+ before.values[7] * w
							< 0
					then
						x, y, z, w = -x, -y, -z, -w
					end
					table.insert(
						keys,
						{ time = keyframe.Time, values = { position.X, position.Y, position.Z, x, y, z, w } }
					)
					table.insert(poses, pose)
				end
			end
			if #keys < 2 then
				continue
			end
			local start, finish = keys[1].time, keys[#keys].time
			local snap: { [number]: boolean } = {}
			for _, at in operation.snap_at or {} do
				for index, key in keys do
					if math.abs(key.time - at) < Sequence.TIME_TOLERANCE then
						snap[index] = true
					end
				end
			end
			-- A pose at the joint's first key and its last, and at every step between.
			local times = { start }
			local step = math.ceil((start - from) * rate - 1e-6)
			while true do
				local time = from + step / rate
				if time > finish - Sequence.TIME_TOLERANCE then
					break
				end
				if time > start + Sequence.TIME_TOLERANCE then
					table.insert(times, time)
				end
				step += 1
			end
			table.insert(times, finish)
			table.insert(plans, {
				name = name,
				poses = poses,
				times = times,
				samples = Smooth.sample(keys, times, {
					snap = snap,
					loop = loop
						and math.abs(start - from) < Sequence.TIME_TOLERANCE
						and math.abs(finish - to) < Sequence.TIME_TOLERANCE,
				}),
			})
		end
		if #plans == 0 then
			refuse(where, `no joint has two or more poses from {from} to {to} seconds to smooth between.`)
		end

		-- Out go the keys the curve was drawn through, and any keyframe they leave empty.
		local emptied: { [Instance]: boolean } = {}
		for _, plan in plans do
			for _, pose in plan.poses do
				local keyframe: Instance = pose
				while keyframe.Parent and not keyframe:IsA("Keyframe") do
					keyframe = keyframe.Parent :: Instance
				end
				emptied[keyframe] = true
				dropPose(pose)
				count(changed, "poses_removed")
			end
		end

		-- In go the poses of the curve. Keyframes are found by their time in thousandths
		-- of a second, which is how close two must be to count as one.
		local byTime: { [number]: Keyframe } = {}
		local total = 0
		for _, keyframe in Sequence.keyframes(sequence) do
			byTime[math.round(keyframe.Time * 1000)] = keyframe
			total += 1
		end
		for _, plan in plans do
			for index, time in plan.times do
				local slot = math.round(time * 1000)
				local keyframe = byTime[slot]
				if not keyframe then
					if total >= Sequence.MAX_KEYFRAMES then
						Errors.throw("LIMIT_EXCEEDED", `A clip holds at most {Sequence.MAX_KEYFRAMES} keyframes.`)
					end
					local created = Roblox.Instance.new("Keyframe")
					created.Time = time
					created.Parent = sequence
					keyframe = created
					byTime[slot] = created
					total += 1
					count(changed, "keyframes_created")
				end
				local values = plan.samples[index]
				local pose = Sequence.ensurePose(keyframe :: Keyframe, plan.name)
				pose.CFrame = Rig.decode(
					{ values[1], values[2], values[3] },
					nil,
					{ values[4], values[5], values[6], values[7] }
				)
				pose.Weight = 1
				-- The curve is in the poses now. Between two of them a straight line will do.
				pose.EasingStyle = Roblox.Enum.PoseEasingStyle.Linear
				pose.EasingDirection = Roblox.Enum.PoseEasingDirection.In
				emptied[keyframe :: Keyframe] = nil
				count(changed, "poses_created")
			end
		end
		for keyframe in emptied do
			if keyframe.Parent and #keyframe:GetChildren() == 0 then
				keyframe.Parent = nil
				count(changed, "keyframes_removed")
			end
		end
	end,
}

return Ops
