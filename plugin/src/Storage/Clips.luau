--!strict
-- Working copies: editable KeyframeSequence instances kept in Keywright's own
-- container, with a revision that changes whenever the instance tree changes. Each rig's
-- working copies sit on that rig's shelf (see WorkingStore), so that copies left in the
-- place by an earlier plugin session can be picked up again.

local ServerStorage = game:GetService("ServerStorage")

local Curves = require("../Editing/Curves")
local Digest = require("../Inspection/Digest")
local Errors = require("../Core/Errors")
local Operations = require("../Editing/Operations")
local Reading = require("../Inspection/Reading")
local WorkingStore = require("./WorkingStore")

local Clips = {}

Clips.CONTAINER_NAME = "Keywright"
Clips.WORKING_NAME = "WorkingCopies"
Clips.SOURCES_NAME = "Sources"
Clips.TIME_TOLERANCE = Operations.TIME_TOLERANCE

export type Working = {
	id: string,
	instance: Instance,
	-- The shelf it is kept on: it is a working copy only while it stays there.
	shelf: Instance?,
	rigId: string,
	source: Instance?,
	revision: number,
	suppress: number,
	signals: { RBXScriptConnection },
	watched: { [Instance]: RBXScriptConnection },
	-- Whether the source has been changed by anything but this plugin since the working
	-- copy was opened, and what watches for that.
	sourceChanged: boolean,
	sourceQuiet: number,
	sourceSignals: { RBXScriptConnection },
	-- The fingerprint of its content at its revision, for telling whether an undo or redo
	-- changed it: a curve's keys change without any event to say so.
	content: string?,
	-- Whether a new fingerprint is already due.
	refreshing: boolean?,
}

local registry: { [string]: Working } = {}
local known: { [Instance]: Working } = {}
local nextId = 1

-- The name the plugin's folder had before the project was called Keywright.
Clips.FORMER_CONTAINER_NAME = "Motion" .. "Bridge"

-- The plugin's folder in the place, under its name or its former one.
local function existingRoot(): Instance?
	return ServerStorage:FindFirstChild(Clips.CONTAINER_NAME)
		or ServerStorage:FindFirstChild(Clips.FORMER_CONTAINER_NAME)
end

function Clips.container(): Folder
	local root: Instance
	local existing = existingRoot()
	if existing then
		-- A folder from before the rename is kept, with everything in it, under the new name.
		existing.Name = Clips.CONTAINER_NAME
		root = existing
	else
		local created = Instance.new("Folder")
		created.Name = Clips.CONTAINER_NAME
		created.Parent = ServerStorage
		root = created
	end
	local working = root:FindFirstChild(Clips.WORKING_NAME)
	if not working then
		local created = Instance.new("Folder")
		created.Name = Clips.WORKING_NAME
		created.Parent = root
		working = created
	end
	return working :: Folder
end

-- The folder of records saying what each working copy was opened from. Made if `make`
-- is true and there is none, which must then be inside an undo recording.
local function links(make: boolean): Instance?
	local root = if make then Clips.container().Parent else existingRoot()
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

-- Takes the fingerprint of a working copy's content as it is now, at its revision.
local function fingerprint(working: Working)
	local ok, digest = pcall(Digest.of, working.instance)
	working.content = if ok then digest else nil
end

-- A new fingerprint once the changes now under way are done, however many there are.
local function refreshSoon(working: Working)
	if working.refreshing then
		return
	end
	working.refreshing = true
	task.defer(function()
		working.refreshing = false
		fingerprint(working)
	end)
end

local function watch(working: Working)
	local function bump()
		if working.suppress == 0 then
			working.revision += 1
			refreshSoon(working)
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
local function watchSource(working: Working, source: Instance)
	local function note()
		if working.sourceQuiet == 0 then
			working.sourceChanged = true
		end
	end
	local function hook(instance: Instance)
		table.insert(working.sourceSignals, instance.Changed:Connect(note))
		-- Changed does not fire for attributes, which replacing the clip would overwrite.
		table.insert(working.sourceSignals, instance.AttributeChanged:Connect(note))
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

local function register(instance: Instance, rigId: string, source: Instance?): Working
	local working: Working = {
		id = "clip_" .. nextId,
		instance = instance,
		shelf = instance.Parent,
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
	fingerprint(working)
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
	local source = working.source :: Instance
	working.sourceQuiet += 1
	local ok, problem = pcall(function()
		Operations.copyContent(working.instance, source)
		-- The record follows: the source is now what the working copy holds.
		local folder = links(false)
		local link = if folder then WorkingStore.recall(folder, working.instance) else nil
		local stamp = if link then link.record:FindFirstChild(WorkingStore.FINGERPRINT) else nil
		if stamp and stamp:IsA("StringValue") then
			stamp.Value = Digest.ofSource(source)
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
-- `format` is "keyframes" or "curves". A source of the other kind is converted: a
-- keyframe clip into curves through its poses, never the other way.
function Clips.open(rigId: string, name: string, source: Instance?, model: Model, format: string?): Working
	local instance: Instance
	local wantCurves = format == "curves" or (format == nil and source ~= nil and source:IsA("CurveAnimation"))
	if source and source:IsA("CurveAnimation") ~= wantCurves then
		if not wantCurves then
			Errors.throw(
				"UNSUPPORTED_CLIP_FORMAT",
				"A clip made of curves cannot be turned into a keyframe clip.",
				'Open it with format "curves".'
			)
		end
		instance = Curves.fromKeyframes(source, Operations.keyframes(source), Operations.findPose)
	elseif source then
		instance = source:Clone()
	elseif wantCurves then
		instance = Instance.new("CurveAnimation");
		(instance :: any).Loop = false
		(instance :: any).Priority = Enum.AnimationPriority.Action
	else
		instance = Instance.new("KeyframeSequence");
		(instance :: any).Loop = false
		(instance :: any).Priority = Enum.AnimationPriority.Action
	end
	instance.Name = name
	instance.Parent = WorkingStore.shelf(Clips.container(), model, create)
	if source then
		-- Written down in the place, so that the link outlasts this plugin session.
		WorkingStore.remember(links(true) :: Instance, instance, source, Digest.ofSource(source), create)
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
	local root = existingRoot()
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
						and (link.source:IsA("KeyframeSequence") or link.source:IsA("CurveAnimation"))
						and link.source.Parent
					then link.source
					else nil
				local working = register(entry.instance, rigId, source)
				if source and link then
					-- Nothing watched the source while no plugin was running, so its
					-- fingerprint says whether it is still what the copy was opened from.
					working.sourceChanged = not Digest.sameSource(source, link.fingerprint or "")
				end
			else
				unassigned += 1
			end
		end
	end
	return unassigned
end

-- Whether a working copy is still one: on a rig's shelf in Keywright's folder of working
-- copies. One a person has moved elsewhere, such as among the Animation Editor's saved
-- clips, or discarded, is not; moved back, or brought back by an undo, it is again.
local function onShelf(working: Working): boolean
	local shelf = working.instance.Parent
	local folder = shelf and shelf.Parent
	local root = existingRoot()
	return folder ~= nil
		and root ~= nil
		and folder.Parent == root
		and folder.Name == Clips.WORKING_NAME
		and WorkingStore.onShelf(working.instance, working.shelf, folder)
end

function Clips.get(clipId: string): Working
	local working = registry[clipId]
	if not working or not onShelf(working) then
		Errors.throw("NOT_FOUND", `No working copy "{clipId}".`, "Call get_workspace to list working copies.")
	end
	return working
end

function Clips.list(): { any }
	local list = {}
	for _, working in registry do
		if onShelf(working) then
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
	fingerprint(working)
end

-- After an undo or a redo in Studio: a working copy whose content no longer matches its
-- fingerprint was changed by it, and gets a new revision, so that an agent holding the
-- old one re-reads it. A curve's keys change without any event, so this is the only way
-- to see an undo that restores only keys.
function Clips.noticeHistory()
	for _, working in registry do
		if working.instance.Parent ~= nil then
			local ok, now = pcall(Digest.of, working.instance)
			if ok and working.content ~= nil and now ~= working.content then
				working.revision += 1
			end
			if ok then
				working.content = now
			end
		end
	end
end

-- Reading a clip's keyframes and poses is the same whether or not it is a working copy.
Clips.sortedKeyframes = Operations.keyframes
Clips.findKeyframe = Operations.findKeyframe
Clips.findPose = Operations.findPose
Clips.ensurePose = Operations.ensurePose

-- A read of a working copy: what Reading returns for its clip, with the ids and the
-- revision that make it a working copy.
-- The time of a clip's last keyframe or key, whichever kind of clip it is.
function Clips.duration(clip: Instance): number
	if clip:IsA("CurveAnimation") then
		return Curves.duration(clip)
	end
	local last = 0
	for _, keyframe in Operations.keyframes(clip) do
		last = math.max(last, keyframe.Time)
	end
	return last
end

-- The times of a clip's keyframes, or of its curves' keys.
function Clips.keyTimes(clip: Instance): { number }
	if clip:IsA("CurveAnimation") then
		return Curves.keyTimes(clip)
	end
	local list = {}
	for _, keyframe in Operations.keyframes(clip) do
		table.insert(list, math.round(keyframe.Time * 1000) / 1000)
	end
	return list
end

function Clips.read(working: Working, options: Reading.Options?): any
	local result = Reading.read(working.instance, options or {})
	result.clip_id = working.id
	result.rig_id = working.rigId
	result.revision = Clips.revisionOf(working)
	return result
end

return Clips
