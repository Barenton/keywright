--!strict
-- Offline tests for saving a clip where the Animation Editor keeps a rig's clips.
-- Run with: lune run plugin/test/storage/saves.test.luau
--
-- Real here: Lune's instances, laid out the way the editor was seen to lay them out in
-- Studio. Not tested here: that the editor lists and loads what is saved, which was
-- checked by hand in Studio for one clip, and Studio's undo.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Saves = require("../../src/Storage/Saves")

local Instance = roblox.Instance

local failures = 0
local count = 0
local current = ""

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL [{current}] {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

local function case(name: string, run: () -> ())
	current = name
	local ok, problem = pcall(run)
	if not ok then
		count += 1
		failures += 1
		print(
			`FAIL [{name}] raised: {if type(problem) == "table" then (problem :: any).message else tostring(problem)}`
		)
	end
end

-- A place in which the Animation Editor has saved one clip, "Scratch", for the rig.
local function buildPlace(withStorage: boolean?)
	local storage = Instance.new("Folder")
	storage.Name = "ServerStorage"
	local rig = Instance.new("Model")
	rig.Name = "Rig"
	local place: any = { storage = storage, rig = rig }
	if withStorage ~= false then
		local root = Instance.new("Model")
		root.Name = "RBX_ANIMSAVES"
		root.Parent = storage
		local container = Instance.new("ObjectValue")
		container.Name = "Rig"
		container.Parent = root
		local scratch = Instance.new("KeyframeSequence")
		scratch.Name = "Scratch"
		scratch.Parent = container
		container.Value = rig
		local reference = Instance.new("ObjectValue")
		reference.Name = "AnimSaves"
		reference.Value = container
		reference.Parent = rig
		place.root, place.container, place.reference, place.scratch = root, container, reference, scratch
	end
	return place
end

-- A working copy with one keyframe and one pose in it.
local function buildClip(): any
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "Wave"
	local keyframe = Instance.new("Keyframe")
	keyframe.Time = 1
	keyframe.Parent = sequence
	local pose = Instance.new("Pose")
	pose.Name = "HumanoidRootPart"
	pose.Parent = keyframe
	return sequence
end

local function create(className: string): any
	return Instance.new(className)
end

local function expectError(run: () -> any): any
	local ok, problem = pcall(run)
	check("the call fails", not ok)
	return if ok then {} else problem
end

case("a clip is saved as a copy among the rig's clips", function()
	local place = buildPlace()
	local clip = buildClip()
	local working = Instance.new("Folder")
	clip.Parent = working
	local saved = Saves.save(clip, place.rig, place.storage, "Wave", create)
	check("the copy is among the rig's clips", saved.Parent == place.container)
	check("it has the name asked for", saved.Name == "Wave")
	check("it is a copy, not the working copy", saved ~= clip)
	check("the working copy stays where it was", clip.Parent == working and clip.Name == "Wave")
	check(
		"the copy holds the clip's content",
		#saved:GetDescendants() == 2 and saved:FindFirstChildOfClass("Keyframe").Time == 1
	)
	check(
		"the clip already saved is untouched",
		place.scratch.Parent == place.container and place.scratch.Name == "Scratch"
	)
	local names = Saves.names(place.rig, place.storage)
	check(
		"both clips are listed, in order",
		#names == 2 and names[1] == "Scratch" and names[2] == "Wave",
		table.concat(names, ",")
	)
	-- Later changes to the working copy do not reach the saved clip.
	clip:FindFirstChildOfClass("Keyframe").Time = 2
	check("the saved clip is independent of the working copy", saved:FindFirstChildOfClass("Keyframe").Time == 1)
end)

case("a name can be chosen, and the same clip can be saved under several", function()
	local place = buildPlace()
	local clip = buildClip()
	Saves.save(clip, place.rig, place.storage, "Wave v1", create)
	Saves.save(clip, place.rig, place.storage, "Wave v2", create)
	local names = table.concat(Saves.names(place.rig, place.storage), ",")
	check("each is saved under its own name", names == "Scratch,Wave v1,Wave v2", names)
end)

case("nothing already saved is ever replaced", function()
	local place = buildPlace()
	local clip = buildClip()
	local problem = expectError(function()
		return Saves.save(clip, place.rig, place.storage, "Scratch", create)
	end)
	check("it is refused as a bad argument", problem.code == "INVALID_ARGUMENT", problem.code)
	check("it says the name is taken", string.find(problem.message or "", "already saved") ~= nil, problem.message)
	check("the clip that was there is the same instance", place.container:FindFirstChild("Scratch") == place.scratch)
	check("nothing was added", #place.container:GetChildren() == 1, #place.container:GetChildren())
	-- A name is taken whatever kind of thing has it.
	local other = Instance.new("Folder")
	other.Name = "Notes"
	other.Parent = place.container
	check("a name used by anything there is taken", Saves.nameProblem(place.container, "Notes") ~= nil)
end)

for label, name in
	{
		["empty"] = "",
		["not text"] = 42,
		["missing"] = "<nil>",
		["too long"] = string.rep("x", 101),
		["with a line break"] = "Wave\nTwo",
		["with a leading space"] = " Wave",
		["with a trailing space"] = "Wave ",
	} :: { [string]: any }
do
	case(`a name that is {label} is refused`, function()
		local place = buildPlace()
		local problem = expectError(function()
			return Saves.save(buildClip(), place.rig, place.storage, if name == "<nil>" then nil else name, create)
		end)
		check("it is refused as a bad argument", problem.code == "INVALID_ARGUMENT", problem.code)
		check("nothing was added", #place.container:GetChildren() == 1)
	end)
end

case("a name of exactly the longest length is accepted", function()
	local place = buildPlace()
	local saved = Saves.save(buildClip(), place.rig, place.storage, string.rep("x", 100), create)
	check("saved", saved.Parent == place.container)
end)

for label, alter in
	{
		["AnimSaves is not a reference"] = function(place: any)
			place.reference.Parent = nil
			local folder = Instance.new("Folder")
			folder.Name = "AnimSaves"
			folder.Parent = place.rig
			return "not the reference"
		end,
		["the reference points at nothing"] = function(place: any)
			place.reference.Parent = nil
			local empty = Instance.new("ObjectValue")
			empty.Name = "AnimSaves"
			empty.Parent = place.rig
			return "points at nothing"
		end,
		["the reference points at storage that was deleted"] = function(place: any)
			place.container.Parent = nil
			return "does not point into the Animation Editor's storage"
		end,
		["the reference points somewhere else in the place"] = function(place: any)
			local elsewhere = Instance.new("Folder")
			elsewhere.Name = "Rig"
			elsewhere.Parent = place.storage
			place.reference.Value = elsewhere
			return "does not point into the Animation Editor's storage"
		end,
		["the storage is not in ServerStorage"] = function(place: any)
			place.root.Parent = Instance.new("Folder")
			return "does not point into the Animation Editor's storage"
		end,
		["the storage folder has another name"] = function(place: any)
			place.root.Name = "MyAnimations"
			return "does not point into the Animation Editor's storage"
		end,
		["the reference points at the rig itself"] = function(place: any)
			place.reference.Value = place.rig
			return "does not point into the Animation Editor's storage"
		end,
		["the storage belongs to another rig, as on a duplicated rig"] = function(place: any)
			local original = Instance.new("Model")
			original.Name = "Rig"
			place.container.Value = original
			return "belongs to another rig"
		end,
		["the storage is not the kind the editor makes"] = function(place: any)
			local folder = Instance.new("Folder")
			folder.Name = "Rig"
			folder.Parent = place.root
			place.reference.Value = folder
			return "belongs to another rig"
		end,
	} :: { [string]: (place: any) -> string }
do
	case(`nothing is saved when {label}`, function()
		local place = buildPlace()
		local expected = alter(place)
		local before = #place.storage:GetDescendants() + #place.rig:GetDescendants()
		local problem = expectError(function()
			return Saves.save(buildClip(), place.rig, place.storage, "Wave", create)
		end)
		check("it is reported as not found", problem.code == "NOT_FOUND", problem.code)
		check("it says why", string.find(problem.message or "", expected, 1, true) ~= nil, problem.message)
		check("it says what to do", string.find(problem.hint or "", "Animation Editor") ~= nil, problem.hint)
		check("nothing was created or changed", #place.storage:GetDescendants() + #place.rig:GetDescendants() == before)
		check("no clips are listed", #Saves.names(place.rig, place.storage) == 0)
	end)
end

case("a rig that has never been saved gets the layout the Animation Editor makes", function()
	local place = buildPlace(false)
	local saved = Saves.save(buildClip(), place.rig, place.storage, "Wave", create)
	local root = place.storage:FindFirstChild("RBX_ANIMSAVES")
	check(
		"ServerStorage has RBX_ANIMSAVES, a Model",
		root ~= nil and root.ClassName == "Model" and #place.storage:GetChildren() == 1
	)
	local container = root and root:FindFirstChild("Rig")
	check(
		"in it, an ObjectValue named after the rig",
		container ~= nil and container.ClassName == "ObjectValue" and #root:GetChildren() == 1
	)
	check("which points back at the rig", container.Value == place.rig)
	local reference = place.rig:FindFirstChild("AnimSaves")
	check(
		"the rig has an AnimSaves reference",
		reference ~= nil and reference.ClassName == "ObjectValue" and #place.rig:GetChildren() == 1
	)
	check("which points at the rig's storage", reference.Value == container)
	check("the clip is saved there", saved.Parent == container and saved.Name == "Wave")
	check("and what was made is what is read back", Saves.container(place.rig, place.storage) == container)
	-- A second save reuses it.
	Saves.save(buildClip(), place.rig, place.storage, "Wave 2", create)
	check(
		"nothing is made twice",
		#place.storage:GetChildren() == 1 and #root:GetChildren() == 1 and #place.rig:GetChildren() == 1
	)
	check("both clips are listed", table.concat(Saves.names(place.rig, place.storage), ",") == "Wave,Wave 2")
end)

case("a second rig gets storage of its own beside the first", function()
	local place = buildPlace()
	local other = Instance.new("Model")
	other.Name = "RigMotor6D"
	local saved = Saves.save(buildClip(), other, place.storage, "Wave", create)
	check(
		"the existing RBX_ANIMSAVES is reused",
		saved.Parent.Parent == place.root and #place.storage:GetChildren() == 1
	)
	check("the second rig has its own storage", saved.Parent ~= place.container and saved.Parent.Value == other)
	check("the first rig's clips are untouched", table.concat(Saves.names(place.rig, place.storage), ",") == "Scratch")
	-- Two rigs with the same name do not share storage either.
	local twin = Instance.new("Model")
	twin.Name = "Rig"
	local theirs = Saves.save(buildClip(), twin, place.storage, "Scratch", create)
	check("a same-named rig gets separate storage", theirs.Parent ~= place.container and theirs.Parent.Value == twin)
	check(
		"so a name taken for one is free for the other",
		theirs.Name == "Scratch" and place.scratch.Parent == place.container
	)
end)

case("a bad name makes no storage, and an unrecognised RBX_ANIMSAVES is left alone", function()
	local place = buildPlace(false)
	expectError(function()
		return Saves.save(buildClip(), place.rig, place.storage, "", create)
	end)
	check("ServerStorage is still empty", #place.storage:GetChildren() == 0)
	check("the rig is still empty", #place.rig:GetChildren() == 0)

	local folder = Instance.new("Folder")
	folder.Name = "RBX_ANIMSAVES"
	folder.Parent = place.storage
	local problem = expectError(function()
		return Saves.save(buildClip(), place.rig, place.storage, "Wave", create)
	end)
	check("it is reported as not found", problem.code == "NOT_FOUND", problem.code)
	check(
		"it says why",
		string.find(problem.message or "", "not the Animation Editor's storage") ~= nil,
		problem.message
	)
	check("nothing was put in it", #folder:GetChildren() == 0 and #place.rig:GetChildren() == 0)
end)

case("only clips are listed, and no more than the limit", function()
	local place = buildPlace()
	local folder = Instance.new("Folder")
	folder.Name = "AAA not a clip"
	folder.Parent = place.container
	for index = 1, 60 do
		local clip = Instance.new("KeyframeSequence")
		clip.Name = string.format("Clip %02d", index)
		clip.Parent = place.container
	end
	local names, total = Saves.names(place.rig, place.storage)
	check("the list is capped", #names == Saves.MAX_LISTED, #names)
	-- Sixty added here, and the one the place already had.
	check("and how many there are in all is given", total == 61, total)
	check("things that are not clips are left out", names[1] == "Clip 01", names[1])
end)

do
	-- Whose clip is it: a rig's saved clips, a clip inside a rig, or one lying elsewhere.
	local function rig(name: string): any
		local model = Instance.new("Model")
		model.Name = name
		Instance.new("Humanoid").Parent = model
		return model
	end
	local mine, theirs = rig("Mine"), rig("Theirs")
	local saved = Instance.new("ObjectValue")
	saved.Value = theirs
	local theirClip = Instance.new("KeyframeSequence")
	theirClip.Parent = saved
	check("a clip in another rig's saved clips is that rig's", Saves.otherRig(theirClip, mine) == theirs)
	check("one in this rig's own is not another's", Saves.otherRig(theirClip, theirs) == nil)
	local inside = Instance.new("KeyframeSequence")
	inside.Parent = theirs
	check("a clip inside another rig is that rig's", Saves.otherRig(inside, mine) == theirs)
	local nested = Instance.new("Model")
	nested.Parent = theirs
	local deep = Instance.new("KeyframeSequence")
	deep.Parent = nested
	check("one in a plain model inside another rig is that rig's", Saves.otherRig(deep, mine) == theirs)
	local loose = Instance.new("KeyframeSequence")
	loose.Parent = Instance.new("Folder")
	check("a clip lying elsewhere is no rig's in particular", Saves.otherRig(loose, mine) == nil)
end

print(`{count - failures}/{count} saves checks passed`)
if failures > 0 then
	process.exit(1)
end
