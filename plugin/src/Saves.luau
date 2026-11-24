--!strict
-- Saved clips, kept where Roblox's Animation Editor keeps them, so that a clip saved
-- here shows up in the editor for that rig.
--
-- The editor's layout, as seen in Studio after its first save for a rig: the rig holds
-- an ObjectValue named AnimSaves; its value is an ObjectValue named after the rig inside
-- the Model ServerStorage.RBX_ANIMSAVES; that one's own value points back at the rig, and
-- the rig's saved clips are its children. A copy of a clip written by this plugin and
-- placed there by hand loaded in the editor and showed the expected pose.
--
-- This module adds a new clip to that storage, and for a rig that has never been saved
-- it first makes the same layout the editor makes. It never changes or removes a clip,
-- and it never repairs or replaces a reference it does not recognise.

local Errors = require("./Errors")

local Saves = {}

Saves.REFERENCE_NAME = "AnimSaves"
Saves.ROOT_NAME = "RBX_ANIMSAVES"
Saves.MAX_NAME_LENGTH = 100
-- Most names listed for one rig.
Saves.MAX_LISTED = 50

-- Returns the instance that holds the rig's saved clips, or nil and the reason there is
-- none that can be used. `storage` is the place's ServerStorage.
function Saves.container(model: Instance, storage: Instance): (Instance?, string?)
	local reference = model:FindFirstChild(Saves.REFERENCE_NAME)
	if not reference then
		return nil, "the rig has never had an animation saved in the Animation Editor"
	elseif not reference:IsA("ObjectValue") then
		return nil, "the rig's AnimSaves is not the reference the Animation Editor makes"
	end
	local container = reference.Value
	if not container then
		return nil, "the rig's AnimSaves reference points at nothing"
	end
	local root = container.Parent
	if not root or root.Name ~= Saves.ROOT_NAME or root.Parent ~= storage then
		return nil, "the rig's AnimSaves reference does not point into the Animation Editor's storage"
	end
	-- The storage names its rig. A rig that was duplicated carries a reference to the
	-- original's storage, and saving there would put the clip under the wrong rig.
	if not container:IsA("ObjectValue") or container.Value ~= model then
		return nil, "the rig's AnimSaves reference points at storage that belongs to another rig"
	end
	return container, nil
end

-- Returns the instance that holds the rig's saved clips, making the editor's layout for
-- a rig that has no AnimSaves at all. A reference that exists but is not usable is left
-- alone and reported. `create` makes a new instance of the given class. Must be called
-- inside an undo recording.
function Saves.ensure(model: Instance, storage: Instance, create: (className: string) -> any): (Instance?, string?)
	if model:FindFirstChild(Saves.REFERENCE_NAME) then
		return Saves.container(model, storage)
	end
	local root: any = storage:FindFirstChild(Saves.ROOT_NAME)
	if root and not root:IsA("Model") then
		return nil, "ServerStorage has something named RBX_ANIMSAVES that is not the Animation Editor's storage"
	end
	if not root then
		root = create("Model")
		root.Name = Saves.ROOT_NAME
		root.Parent = storage
	end
	local container = create("ObjectValue")
	container.Name = model.Name
	container.Value = model
	container.Parent = root
	local reference = create("ObjectValue")
	reference.Name = Saves.REFERENCE_NAME
	reference.Value = container
	reference.Parent = model
	return container, nil
end

-- Names of the clips saved for a rig, in order. Empty when the rig has no usable storage.
function Saves.names(model: Instance, storage: Instance): ({ string }, number)
	local container = Saves.container(model, storage)
	local names: { string } = {}
	local total = 0
	if container then
		for _, child in container:GetChildren() do
			if child:IsA("KeyframeSequence") or child:IsA("CurveAnimation") then
				table.insert(names, child.Name)
			end
		end
		table.sort(names)
		total = #names
		while #names > Saves.MAX_LISTED do
			table.remove(names)
		end
	end
	-- The second value is how many there are in all, for saying when the list was cut.
	return names, total
end

-- Returns nil when a clip may be saved under this name, or the reason it may not. Without
-- a container only the name itself is judged.
function Saves.nameProblem(container: Instance?, name: any): string?
	if type(name) ~= "string" or name == "" then
		return "a name is required"
	elseif #name > Saves.MAX_NAME_LENGTH then
		return `the name is longer than {Saves.MAX_NAME_LENGTH} characters`
	elseif string.find(name, "%c") then
		return "the name contains a control character"
	elseif string.match(name, "^%s") or string.match(name, "%s$") then
		return "the name begins or ends with a space"
	elseif container and container:FindFirstChild(name) then
		return `a clip named "{name}" is already saved for this rig`
	end
	return nil
end

-- Adds a copy of the clip to the rig's saved clips under the given name. Nothing that is
-- already saved is touched: a name that is taken is refused. Must be called inside an
-- undo recording, so that anything made here is undone with it. Returns the saved copy.
function Saves.save(
	sequence: KeyframeSequence,
	model: Instance,
	storage: Instance,
	name: string,
	create: (className: string) -> any
): KeyframeSequence
	-- The name is judged before anything is made, so that a bad one leaves no trace.
	local unusable = Saves.nameProblem(nil, name)
	if unusable then
		Errors.throw("INVALID_ARGUMENT", `The clip cannot be saved because {unusable}.`, "Choose another name.")
	end
	local container, why = Saves.ensure(model, storage, create)
	if not container then
		Errors.throw(
			"NOT_FOUND",
			`The clip cannot be saved because {why}.`,
			"Open the rig in the Animation Editor and check how its animations are stored."
		)
	end
	local target = container :: Instance
	local taken = Saves.nameProblem(target, name)
	if taken then
		Errors.throw("INVALID_ARGUMENT", `The clip cannot be saved because {taken}.`, "Choose another name.")
	end
	local copy = sequence:Clone()
	copy.Name = name
	copy.Parent = target
	return copy
end

return Saves
