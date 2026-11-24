--!strict
-- Working copies: editable KeyframeSequence instances kept in Motion Bridge's own
-- container, with a revision that changes whenever the instance tree changes. Each rig's
-- working copies sit on that rig's shelf (see WorkingStore), so that copies left in the
-- place by an earlier plugin session can be picked up again.

local ServerStorage = game:GetService("ServerStorage")

local Digest = require("./Digest")
local Errors = require("./Errors")
local Operations = require("./Operations")
local Reading = require("./Reading")
local WorkingStore = require("./WorkingStore")

local Clips = {}

Clips.CONTAINER_NAME = "MotionBridge"
Clips.WORKING_NAME = "WorkingCopies"
Clips.SOURCES_NAME = "Sources"
Clips.TIME_TOLERANCE = Operations.TIME_TOLERANCE

export type Working = {
	id: string,
	instance: KeyframeSequence,
	rigId: string,
	source: KeyframeSequence?,
	revision: number,
	suppress: number,
	signals: { RBXScriptConnection },
	watched: { [Instance]: RBXScriptConnection },
	-- Whether the source has been changed by anything but this plugin since the working
	-- copy was opened, and what watches for that.
	sourceChanged: boolean,
	sourceQuiet: number,
	sourceSignals: { RBXScriptConnection },
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

-- The folder of records saying what each working copy was opened from. Made if `make`
-- is true and there is none, which must then be inside an undo recording.
local function links(make: boolean): Instance?
	local root = if make then Clips.container().Parent else ServerStorage:FindFirstChild(Clips.CONTAINER_NAME)
	if not root then
		return nil
	end
	local folder = root:FindFirstChild(Clips.SOURCES_NAME)
	if not folder and make then
		local created = Instance.new("Folder")
		created.Name = Clips.SOURCES_NAME
		created.Parent = root
		folder = created
	end
	return folder
end

local function create(className: string): any
	return Instance.new(className)
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

-- Notes any change to the clip a working copy was opened from: to it, to anything in it,
-- or to what it holds. Replacing that clip is refused once it has changed.
local function watchSource(working: Working, source: KeyframeSequence)
	local function note()
		if working.sourceQuiet == 0 then
			working.sourceChanged = true
		end
	end
	local function hook(instance: Instance)
		table.insert(working.sourceSignals, instance.Changed:Connect(note))
	end
	hook(source)
	for _, descendant in source:GetDescendants() do
		hook(descendant)
	end
	table.insert(
		working.sourceSignals,
		source.DescendantAdded:Connect(function(descendant)
			hook(descendant)
			note()
		end)
	)
	table.insert(working.sourceSignals, source.DescendantRemoving:Connect(note))
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
		sourceChanged = false,
		sourceQuiet = 0,
		sourceSignals = {},
	}
	nextId += 1
	registry[working.id] = working
	known[instance] = working
	watch(working)
	if source then
		watchSource(working, source)
	end
	return working
end

-- Where the clip a working copy was opened from stands: "none" if it was opened blank or
-- the link was lost in a plugin reload, "missing" if the clip is no longer in the place,
-- "changed" if it has been altered since, otherwise "unchanged".
function Clips.sourceState(working: Working): "none" | "missing" | "changed" | "unchanged"
	local source = working.source
	if not source then
		return "none"
	elseif source.Parent == nil then
		return "missing"
	end
	return if working.sourceChanged then "changed" else "unchanged"
end

-- Makes the source hold what the working copy holds. Must be called inside an undo
-- recording; `finish` receives the outcome before signals are flushed, as in `mutate`,
-- so that the recording is closed while the changes still count as this plugin's own.
function Clips.replaceSource(working: Working, finish: (ok: boolean) -> ())
	local source = working.source :: KeyframeSequence
	working.sourceQuiet += 1
	local ok, problem = pcall(function()
		Operations.copyContent(working.instance, source)
		-- The record follows: the source is now what the working copy holds.
		local folder = links(false)
		local link = if folder then WorkingStore.recall(folder, working.instance) else nil
		local stamp = if link then link.record:FindFirstChild(WorkingStore.FINGERPRINT) else nil
		if stamp and stamp:IsA("StringValue") then
			stamp.Value = Digest.of(source)
		end
	end)
	local finished, finishProblem = pcall(finish :: any, ok)
	task.wait()
	working.sourceQuiet -= 1
	if not ok then
		error(problem, 0)
	end
	if not finished then
		error(finishProblem, 0)
	end
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
	instance.Parent = WorkingStore.shelf(Clips.container(), model, create)
	if source then
		-- Written down in the place, so that the link outlasts this plugin session.
		WorkingStore.remember(links(true) :: Instance, instance, source, Digest.of(source), create)
	end
	return register(instance, rigId, source)
end

-- Takes a working copy's record of its source out of the place. For when the copy is
-- discarded; must be called inside that undo recording.
function Clips.unlink(working: Working)
	local folder = links(false)
	if folder then
		WorkingStore.forget(folder, working.instance)
	end
end

-- Picks up working copies that are in the place but not known to this session, as after
-- a plugin reload. `rigIdOf` gives the id of a rig, or nil if the model is not one that
-- can be worked on. What a copy was opened from is read back from its record. Returns how
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
				-- What it was opened from, if that was written down and is still there.
				local records = links(false)
				local link = if records then WorkingStore.recall(records, entry.instance) else nil
				local source = if link
						and link.source
						and link.source:IsA("KeyframeSequence")
						and link.source.Parent
					then link.source
					else nil
				local working = register(entry.instance, rigId, source)
				if source and link then
					-- Nothing watched the source while no plugin was running, so its
					-- fingerprint says whether it is still what the copy was opened from.
					working.sourceChanged = Digest.of(source) ~= link.fingerprint
				end
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
	for _, signal in working.sourceSignals do
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

-- Reading a clip's keyframes and poses is the same whether or not it is a working copy.
Clips.sortedKeyframes = Operations.keyframes
Clips.findKeyframe = Operations.findKeyframe
Clips.findPose = Operations.findPose
Clips.ensurePose = Operations.ensurePose

-- A read of a working copy: what Reading returns for its clip, with the ids and the
-- revision that make it a working copy.
function Clips.read(working: Working, options: Reading.Options?): any
	local result = Reading.read(working.instance, options or {})
	result.clip_id = working.id
	result.rig_id = working.rigId
	result.revision = Clips.revisionOf(working)
	return result
end

return Clips
