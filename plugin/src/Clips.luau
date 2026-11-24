--!strict
-- Working copies: editable KeyframeSequence instances kept in Motion Bridge's own
-- container, with a revision that changes whenever the instance tree changes. Each rig's
-- working copies sit on that rig's shelf (see WorkingStore), so that copies left in the
-- place by an earlier plugin session can be picked up again.

local ServerStorage = game:GetService("ServerStorage")

local Errors = require("./Errors")
local Rig = require("./Rig")
local WorkingStore = require("./WorkingStore")

local Clips = {}

Clips.CONTAINER_NAME = "MotionBridge"
Clips.WORKING_NAME = "WorkingCopies"
Clips.TIME_TOLERANCE = 0.001

export type Working = {
	id: string,
	instance: KeyframeSequence,
	rigId: string,
	source: KeyframeSequence?,
	revision: number,
	suppress: number,
	signals: { RBXScriptConnection },
	watched: { [Instance]: RBXScriptConnection },
}

local registry: { [string]: Working } = {}
local known: { [Instance]: Working } = {}
local nextId = 1

function Clips.container(): Folder
	local root = ServerStorage:FindFirstChild(Clips.CONTAINER_NAME)
	if not root then
		root = Instance.new("Folder")
		root.Name = Clips.CONTAINER_NAME
		root.Parent = ServerStorage
	end
	local working = root:FindFirstChild(Clips.WORKING_NAME)
	if not working then
		working = Instance.new("Folder")
		working.Name = Clips.WORKING_NAME
		working.Parent = root
	end
	return working :: Folder
end

function Clips.revisionOf(working: Working): string
	return "r" .. working.revision
end

local function watch(working: Working)
	local function bump()
		if working.suppress == 0 then
			working.revision += 1
		end
	end
	local function hook(instance: Instance)
		working.watched[instance] = instance.Changed:Connect(bump)
	end
	hook(working.instance)
	for _, descendant in working.instance:GetDescendants() do
		hook(descendant)
	end
	table.insert(
		working.signals,
		working.instance.DescendantAdded:Connect(function(descendant)
			hook(descendant)
			bump()
		end)
	)
	table.insert(
		working.signals,
		working.instance.DescendantRemoving:Connect(function(descendant)
			local signal = working.watched[descendant]
			if signal then
				signal:Disconnect()
				working.watched[descendant] = nil
			end
			bump()
		end)
	)
end

local function register(instance: KeyframeSequence, rigId: string, source: KeyframeSequence?): Working
	local working: Working = {
		id = "clip_" .. nextId,
		instance = instance,
		rigId = rigId,
		source = source,
		revision = 1,
		suppress = 0,
		signals = {},
		watched = {},
	}
	nextId += 1
	registry[working.id] = working
	known[instance] = working
	watch(working)
	return working
end

-- Creates a working copy for the rig. Must be called inside an undo recording.
function Clips.open(rigId: string, name: string, source: KeyframeSequence?, model: Model): Working
	local instance: KeyframeSequence
	if source then
		instance = source:Clone()
	else
		instance = Instance.new("KeyframeSequence")
		instance.Loop = false
		instance.Priority = Enum.AnimationPriority.Action
	end
	instance.Name = name
	instance.Parent = WorkingStore.shelf(Clips.container(), model, function(className: string)
		return Instance.new(className)
	end)
	return register(instance, rigId, source)
end

-- Picks up working copies that are in the place but not known to this session, as after
-- a plugin reload. `rigIdOf` gives the id of a rig, or nil if the model is not one that
-- can be worked on. What a copy was opened from is not kept across sessions. Returns how
-- many working copies in the place could not be matched to a rig. Changes nothing.
function Clips.restore(rigIdOf: (model: Instance) -> string?): number
	local root = ServerStorage:FindFirstChild(Clips.CONTAINER_NAME)
	local folder = root and root:FindFirstChild(Clips.WORKING_NAME)
	if not folder then
		return 0
	end
	local found, unassigned = WorkingStore.discover(folder)
	for _, entry in found do
		if not known[entry.instance] then
			local rigId = rigIdOf(entry.model)
			if rigId then
				register(entry.instance, rigId, nil)
			else
				unassigned += 1
			end
		end
	end
	return unassigned
end

function Clips.get(clipId: string): Working
	local working = registry[clipId]
	if not working or working.instance.Parent == nil then
		Errors.throw("NOT_FOUND", `No working copy "{clipId}".`, "Call get_workspace to list working copies.")
	end
	return working
end

function Clips.list(): { any }
	local list = {}
	for _, working in registry do
		if working.instance.Parent ~= nil then
			table.insert(list, {
				clip_id = working.id,
				name = working.instance.Name,
				rig_id = working.rigId,
				revision = Clips.revisionOf(working),
				has_source = working.source ~= nil,
			})
		end
	end
	table.sort(list, function(a, b)
		return a.clip_id < b.clip_id
	end)
	return list
end

function Clips.close(working: Working)
	for _, signal in working.signals do
		signal:Disconnect()
	end
	for _, signal in working.watched do
		signal:Disconnect()
	end
	registry[working.id] = nil
	known[working.instance] = nil
end

-- Runs `change` as one edit. Signals raised by our own writes are not counted as
-- external changes; the revision advances once, and only if the edit succeeded.
-- `finish` receives the outcome before signals are flushed, so it can commit or
-- cancel the undo recording while changes are still attributed to this edit.
function Clips.mutate(working: Working, change: () -> (), finish: (ok: boolean) -> ())
	working.suppress += 1
	local ok, problem = pcall(change :: any)
	local finished, finishProblem = pcall(finish :: any, ok)
	-- Signals may be deferred; let them run while still suppressed.
	task.wait()
	working.suppress -= 1
	if not ok then
		error(problem, 0)
	end
	if not finished then
		error(finishProblem, 0)
	end
	working.revision += 1
end

function Clips.sortedKeyframes(sequence: KeyframeSequence): { Keyframe }
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

function Clips.findKeyframe(sequence: KeyframeSequence, time: number): Keyframe?
	for _, child in sequence:GetChildren() do
		if child:IsA("Keyframe") and math.abs(child.Time - time) < Clips.TIME_TOLERANCE then
			return child
		end
	end
	return nil
end

function Clips.findPose(keyframe: Keyframe, joint: string): Pose?
	local found = keyframe:FindFirstChild(joint, true)
	if found and found:IsA("Pose") then
		return found
	end
	return nil
end

-- Returns the pose for a joint, creating it and any missing ancestors. Poses nest in
-- rig order from the root part; ancestors created here carry no weight of their own.
function Clips.ensurePose(keyframe: Keyframe, joint: string): (Pose, boolean)
	local existing = Clips.findPose(keyframe, joint)
	if existing then
		return existing, false
	end
	local parent: Instance = keyframe
	local pose: Pose? = nil
	for _, name in Rig.chain(joint) do
		local child = parent:FindFirstChild(name)
		if not child or not child:IsA("Pose") then
			local created = Instance.new("Pose")
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

function Clips.read(working: Working, joints: { string }?, timeFrom: number?, timeTo: number?): any
	local sequence = working.instance
	local keyframes = Clips.sortedKeyframes(sequence)
	local times = {}
	local animated: { [string]: boolean } = {}
	local markers = {}
	for _, keyframe in keyframes do
		table.insert(times, math.round(keyframe.Time * 1000) / 1000)
		for _, descendant in keyframe:GetDescendants() do
			if descendant:IsA("Pose") and descendant.Weight > 0 then
				animated[descendant.Name] = true
			elseif descendant:IsA("KeyframeMarker") then
				table.insert(markers, { name = descendant.Name, value = descendant.Value, time = keyframe.Time })
			end
		end
	end
	local animatedList = {}
	for name in animated do
		table.insert(animatedList, name)
	end
	table.sort(animatedList)

	local result: any = {
		clip_id = working.id,
		name = sequence.Name,
		rig_id = working.rigId,
		revision = Clips.revisionOf(working),
		loop = sequence.Loop,
		priority = sequence.Priority.Name,
		duration = if #keyframes > 0 then keyframes[#keyframes].Time else 0,
		keyframe_count = #keyframes,
		keyframe_times = times,
		animated_joints = animatedList,
		markers = markers,
	}

	if joints and #joints > 0 then
		local poses = {}
		for _, keyframe in keyframes do
			if
				(timeFrom and keyframe.Time < timeFrom - Clips.TIME_TOLERANCE)
				or (timeTo and keyframe.Time > timeTo + Clips.TIME_TOLERANCE)
			then
				continue
			end
			for _, joint in joints do
				local pose = Clips.findPose(keyframe, joint)
				if pose and pose.Weight > 0 then
					local encoded = Rig.encode(pose.CFrame)
					table.insert(poses, {
						joint = joint,
						time = math.round(keyframe.Time * 1000) / 1000,
						position = encoded.position,
						rotation = encoded.rotation,
						easing_style = pose.EasingStyle.Name,
						easing_direction = pose.EasingDirection.Name,
					})
				end
			end
		end
		result.poses = poses
	end
	return result
end

return Clips
