--!strict
-- Keyframe clips as stored: the limits and names used throughout, and finding a clip's keyframes and poses.

local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")

local Sequence = {}

Sequence.MAX_OPERATIONS = 256
Sequence.MAX_TIME = 300
Sequence.MAX_POSITION = 1000
Sequence.MAX_KEYFRAMES = 2000
Sequence.MAX_NAME = 100
Sequence.MAX_MARKER_VALUE = 200
Sequence.MAX_HOLDS = 8
-- For smoothing: how many poses a second are written, and how many snaps one call takes.
Sequence.MIN_RATE = 10
Sequence.MAX_RATE = 60
Sequence.DEFAULT_RATE = 30
Sequence.MAX_SNAPS = 16
Sequence.MAX_JOINTS = 32
Sequence.MIN_SCALE = 0.01
Sequence.MAX_SCALE = 100
Sequence.TIME_TOLERANCE = 0.001

-- Easing styles an edit may write. "Cubic" is deprecated: it is kept where a clip
-- already has it, but never written.
Sequence.EASING_STYLES = { "Linear", "Constant", "Elastic", "CubicV2", "Bounce" }
Sequence.EASING_DIRECTIONS = { "In", "Out", "InOut" }
Sequence.PRIORITIES = { "Idle", "Movement", "Action", "Action2", "Action3", "Action4", "Core" }

export type Context = {
	-- The rig's joints by the name of the driven part.
	joints: { [string]: any },
	-- The clip the working copy was opened from, if any.
	source: Instance?,
	-- For a keyframe that holds the pose the clip already has at its time: the pose of
	-- each animated joint there, by the operation's place in the batch. The engine works
	-- these out, not this module, so whoever runs the batch supplies them.
	held: { [number]: { [string]: CFrame } }?,
	-- Filled in while applying: for each such keyframe, what a caller should know.
	holds: { any }?,
}

export type Changed = { [string]: number }

-- ---------------------------------------------------------------------------------------
-- Reading a clip

function Sequence.keyframes(sequence: Instance): { Keyframe }
	local keyframes = {}
	for _, child in sequence:GetChildren() do
		if child:IsA("Keyframe") then
			table.insert(keyframes, child)
		end
	end
	table.sort(keyframes, function(a, b)
		return a.Time < b.Time
	end)
	return keyframes
end

function Sequence.findKeyframe(sequence: Instance, time: number): Keyframe?
	for _, child in sequence:GetChildren() do
		if child:IsA("Keyframe") and math.abs(child.Time - time) < Sequence.TIME_TOLERANCE then
			return child
		end
	end
	return nil
end

function Sequence.findPose(keyframe: Instance, joint: string): Pose?
	local found = keyframe:FindFirstChild(joint, true)
	if found and found:IsA("Pose") then
		return found
	end
	return nil
end

-- The pose for a joint in a keyframe, created along with any ancestors it needs. Poses
-- are nested the way the rig's parts are; an ancestor made only to hold the nesting has
-- no weight, so it does not move its joint.
function Sequence.ensurePose(keyframe: Instance, joint: string): (Pose, boolean)
	local existing = Sequence.findPose(keyframe, joint)
	if existing then
		return existing, false
	end
	local parent: Instance = keyframe
	local pose: Pose? = nil
	for _, name in Rig.chain(joint) do
		local child = parent:FindFirstChild(name)
		if not child or not child:IsA("Pose") then
			local created = Roblox.Instance.new("Pose")
			created.Name = name
			created.Weight = if name == joint then 1 else 0
			created.Parent = parent
			child = created
		end
		pose = child :: Pose
		parent = child :: Pose
	end
	return pose :: Pose, true
end

-- Makes one clip hold what another holds: its keyframes and everything in them, and its
-- loop and priority settings. The name is left alone. What `to` held is taken out, not
-- destroyed, so that an undo can put it back.
function Sequence.copyContent(from: Instance, to: Instance)
	for _, child in to:GetChildren() do
		child.Parent = nil
	end
	for _, child in from:GetChildren() do
		child:Clone().Parent = to
	end
	(to :: any).Loop = (from :: any).Loop;
	(to :: any).Priority = (from :: any).Priority
end

-- ---------------------------------------------------------------------------------------
-- Checking what was asked for

-- The joints a clip moves: those with a pose that has weight, in any keyframe.
function Sequence.animated(sequence: Instance): { string }
	local seen: { [string]: boolean } = {}
	for _, keyframe in Sequence.keyframes(sequence) do
		for _, descendant: any in keyframe:GetDescendants() do
			if descendant:IsA("Pose") and descendant.Weight > 0 then
				seen[descendant.Name] = true
			end
		end
	end
	local names = {}
	for name in seen do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return Sequence
