--!strict
-- Where working copies are kept, laid out so that they can be found again.
--
-- Working copies live in Motion Bridge's own folder in ServerStorage, never in storage
-- the Animation Editor manages. Inside that folder each rig has a shelf: an ObjectValue
-- named after the rig whose value points back at it, with the rig's working copies as
-- its children. That is the same pattern the Animation Editor uses for saved clips, and
-- it is what lets a later plugin session tell which rig a clip left in the place is for.
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

return WorkingStore
