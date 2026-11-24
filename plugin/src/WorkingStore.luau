--!strict
-- Where working copies are kept, laid out so that they can be found again.
--
-- Working copies live in Keywright's own folder in ServerStorage, never in storage
-- the Animation Editor manages. Inside that folder each rig has a shelf: an ObjectValue
-- named after the rig whose value points back at it, with the rig's working copies as
-- its children. That is the same pattern the Animation Editor uses for saved clips, and
-- it is what lets a later plugin session tell which rig a clip left in the place is for.
--
-- Beside the shelves there is a record for each working copy that was opened from a
-- clip: an ObjectValue pointing at the working copy, holding another that points at the
-- clip, and the clip's fingerprint as it was then. That is what lets a later plugin
-- session restore a working copy to its source, or propose replacing the source, and
-- tell whether the source has changed in between.
--
-- This module only arranges and reads instances it is handed.

local WorkingStore = {}

export type Found = {
	instance: KeyframeSequence,
	model: Instance,
}

-- Returns the rig's shelf inside `root`, making it if the rig has none. `create` makes a
-- new instance of the given class. Must be called inside an undo recording.
function WorkingStore.shelf(root: Instance, model: Instance, create: (className: string) -> any): Instance
	for _, child in root:GetChildren() do
		if child:IsA("ObjectValue") and child.Value == model then
			return child
		end
	end
	local shelf = create("ObjectValue")
	shelf.Name = model.Name
	shelf.Value = model
	shelf.Parent = root
	return shelf
end

-- Lists the working copies in `root` whose rig can still be told, in a stable order, and
-- counts those whose rig cannot: clips on a shelf whose rig is gone, and clips lying in
-- the folder with no shelf at all.
function WorkingStore.discover(root: Instance): ({ Found }, number)
	local found: { Found } = {}
	local unassigned = 0
	for _, child in root:GetChildren() do
		if child:IsA("KeyframeSequence") then
			unassigned += 1
		elseif child:IsA("ObjectValue") then
			local model = child.Value
			local usable = model ~= nil and model.Parent ~= nil
			for _, clip in child:GetChildren() do
				if clip:IsA("KeyframeSequence") then
					if usable then
						table.insert(found, { instance = clip, model = model :: Instance })
					else
						unassigned += 1
					end
				end
			end
		end
	end
	table.sort(found, function(a, b)
		if a.model.Name ~= b.model.Name then
			return a.model.Name < b.model.Name
		end
		return a.instance.Name < b.instance.Name
	end)
	return found, unassigned
end

WorkingStore.SOURCE = "Source"
WorkingStore.FINGERPRINT = "Fingerprint"

export type Link = {
	record: Instance,
	source: Instance?,
	fingerprint: string?,
}

-- The record of what a working copy was opened from, if there is one in `links`.
function WorkingStore.recall(links: Instance, working: Instance): Link?
	for _, record in links:GetChildren() do
		if record:IsA("ObjectValue") and record.Value == working then
			local pointer = record:FindFirstChild(WorkingStore.SOURCE)
			local fingerprint = record:FindFirstChild(WorkingStore.FINGERPRINT)
			return {
				record = record :: Instance,
				source = if pointer and pointer:IsA("ObjectValue") then pointer.Value else nil,
				fingerprint = if fingerprint and fingerprint:IsA("StringValue") then fingerprint.Value else nil,
			}
		end
	end
	return nil
end

-- Records in `links` that a working copy was opened from `source`, whose fingerprint was
-- `fingerprint` then. Replaces what was recorded for that working copy before. Must be
-- called inside an undo recording.
function WorkingStore.remember(
	links: Instance,
	working: Instance,
	source: Instance,
	fingerprint: string,
	create: (className: string) -> any
)
	local existing = WorkingStore.recall(links, working)
	if existing then
		existing.record.Parent = nil
	end
	local record = create("ObjectValue")
	record.Name = working.Name
	record.Value = working
	local pointer = create("ObjectValue")
	pointer.Name = WorkingStore.SOURCE
	pointer.Value = source
	pointer.Parent = record
	local stamp = create("StringValue")
	stamp.Name = WorkingStore.FINGERPRINT
	stamp.Value = fingerprint
	stamp.Parent = record
	record.Parent = links
end

-- Takes the record for a working copy out of `links`, as when the copy is discarded.
-- Taken out, not destroyed, so that an undo brings it back with the copy.
function WorkingStore.forget(links: Instance, working: Instance)
	local existing = WorkingStore.recall(links, working)
	if existing then
		existing.record.Parent = nil
	end
end

return WorkingStore
