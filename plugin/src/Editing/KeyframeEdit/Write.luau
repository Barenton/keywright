--!strict
-- Editing helpers shared by the operations: counting changes, making and finding
-- keyframes, dropping poses, easing, and moving keyframes in time.

local Errors = require("../../Core/Errors")
local Need = require("./Need")
local Roblox = require("../../Core/Roblox")
local Sequence = require("./Sequence")

local refuse = Need.refuse

type Changed = Sequence.Changed

local Write = {}

local function count(changed: Changed, what: string, by: number?)
	changed[what] = (changed[what] or 0) + (by or 1)
end

local function inRange(time: number, from: number, to: number): boolean
	return time >= from - Sequence.TIME_TOLERANCE and time <= to + Sequence.TIME_TOLERANCE
end

local function newKeyframe(sequence: Instance, time: number, changed: Changed): Keyframe
	if #Sequence.keyframes(sequence) >= Sequence.MAX_KEYFRAMES then
		Errors.throw("LIMIT_EXCEEDED", `A clip holds at most {Sequence.MAX_KEYFRAMES} keyframes.`)
	end
	local created = Roblox.Instance.new("Keyframe")
	created.Time = time
	created.Parent = sequence
	count(changed, "keyframes_created")
	return created
end

-- Takes a pose out of its keyframe. If other poses hang from it, it stays to hold them
-- and stops moving its joint; otherwise it goes, along with any ancestors that were only
-- there to hold it.
local function dropPose(pose: Pose)
	if #pose:GetChildren() > 0 then
		pose.Weight = 0
		pose.CFrame = Roblox.CFrame.new()
		return
	end
	local above = pose.Parent
	pose.Parent = nil
	while above and above:IsA("Pose") and above.Weight == 0 and #above:GetChildren() == 0 do
		local next = above.Parent
		above.Parent = nil
		above = next
	end
end

local function needKeyframe(where: string, sequence: Instance, time: number): Keyframe
	local keyframe = Sequence.findKeyframe(sequence, time)
	if not keyframe then
		refuse(where, `there is no keyframe at {time} seconds.`, "read_animation lists the keyframe times.")
	end
	return keyframe :: Keyframe
end

local function needFree(where: string, sequence: Instance, time: number, except: Keyframe?)
	local occupant = Sequence.findKeyframe(sequence, time)
	if occupant and occupant ~= except then
		refuse(where, `there is already a keyframe at {time} seconds.`)
	end
end

-- The joint's pose in a keyframe, only if it is one that moves the joint.
local function weighted(keyframe: Instance, joint: string): Pose?
	local pose = Sequence.findPose(keyframe, joint)
	return if pose and pose.Weight > 0 then pose else nil
end

local function setEasing(pose: Pose, style: string?, direction: string?)
	if style then
		pose.EasingStyle = (Roblox.Enum.PoseEasingStyle :: any)[style]
	end
	if direction then
		pose.EasingDirection = (Roblox.Enum.PoseEasingDirection :: any)[direction]
	end
end

-- Moves the keyframes in a range to new times. Refused if a moved keyframe would land on
-- another, leave the allowed times, or pass a keyframe that is not being moved: any of
-- those would change the motion in a way the request did not spell out.
local function retime(
	where: string,
	sequence: Instance,
	operation: any,
	place: (time: number) -> number,
	changed: Changed
)
	local moved: { { keyframe: Keyframe, from: number, to: number } } = {}
	local still: { number } = {}
	for _, keyframe in Sequence.keyframes(sequence) do
		if inRange(keyframe.Time, operation.time_from, operation.time_to) then
			table.insert(moved, { keyframe = keyframe, from = keyframe.Time, to = place(keyframe.Time) })
		else
			table.insert(still, keyframe.Time)
		end
	end
	if #moved == 0 then
		refuse(where, `there are no keyframes from {operation.time_from} to {operation.time_to} seconds.`)
	end
	for index, entry in moved do
		if entry.to < -Sequence.TIME_TOLERANCE or entry.to > Sequence.MAX_TIME then
			refuse(
				where,
				`the keyframe at {entry.from} seconds would move to {entry.to}, outside 0 to {Sequence.MAX_TIME}.`
			)
		end
		local earlier = moved[index - 1]
		if earlier and entry.to - earlier.to < Sequence.TIME_TOLERANCE then
			refuse(where, `the keyframes at {earlier.from} and {entry.from} seconds would land on each other.`)
		end
		for _, other in still do
			if math.abs(entry.to - other) < Sequence.TIME_TOLERANCE then
				refuse(where, `the keyframe at {entry.from} seconds would land on the one at {other}.`)
			elseif (entry.from < other) ~= (entry.to < other) then
				refuse(
					where,
					`the keyframe at {entry.from} seconds would pass the one at {other}.`,
					"Widen the range to take that keyframe along, or move it first."
				)
			end
		end
	end
	for _, entry in moved do
		entry.keyframe.Time = math.max(0, entry.to)
	end
	count(changed, "keyframes_moved", #moved)
end

Write.count = count
Write.inRange = inRange
Write.newKeyframe = newKeyframe
Write.dropPose = dropPose
Write.needKeyframe = needKeyframe
Write.needFree = needFree
Write.weighted = weighted
Write.setEasing = setEasing
Write.retime = retime

return Write
