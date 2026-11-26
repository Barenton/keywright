--!strict
-- Offline tests for where working copies are kept and how they are found again, and for
-- telling places apart for agent access. Run with: lune run plugin/test/storage/workingstore.test.luau
--
-- Real here: Lune's instances. Not tested here: Studio's undo, plugin settings, and the
-- plugin picking copies up when it actually reloads.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Access = require("../../src/Network/Access")
local WorkingStore = require("../../src/Storage/WorkingStore")

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
		print(`FAIL [{name}] raised: {tostring(problem)}`)
	end
end

local function create(className: string): any
	return Instance.new(className)
end

local function buildPlace()
	local workspace = Instance.new("Folder")
	workspace.Name = "Workspace"
	local root = Instance.new("Folder")
	root.Name = "WorkingCopies"
	local function rig(name: string): any
		local model = Instance.new("Model")
		model.Name = name
		model.Parent = workspace
		return model
	end
	return { workspace = workspace, root = root, rig = rig }
end

local function clip(name: string, parent: any): any
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = name
	sequence.Parent = parent
	return sequence
end

local function names(found: { any }): string
	local list = {}
	for _, entry in found do
		table.insert(list, `{entry.model.Name}/{entry.instance.Name}`)
	end
	return table.concat(list, ",")
end

case("each rig gets one shelf that points back at it", function()
	local place = buildPlace()
	local hero, villain = place.rig("Hero"), place.rig("Villain")
	local first = WorkingStore.shelf(place.root, hero, create)
	check("the shelf is in the folder", first.Parent == place.root)
	check("it is an ObjectValue named after the rig", first.ClassName == "ObjectValue" and first.Name == "Hero")
	check("it points back at the rig", first.Value == hero)
	check("asking again gives the same shelf", WorkingStore.shelf(place.root, hero, create) == first)
	check("nothing is made twice", #place.root:GetChildren() == 1)
	local second = WorkingStore.shelf(place.root, villain, create)
	check("another rig gets its own", second ~= first and second.Value == villain and #place.root:GetChildren() == 2)
	-- Two rigs that share a name are still told apart.
	local twin = place.rig("Hero")
	local third = WorkingStore.shelf(place.root, twin, create)
	check(
		"a same-named rig gets its own shelf",
		third ~= first and third.Value == twin and #place.root:GetChildren() == 3
	)
	check(
		"a renamed rig keeps its shelf",
		(function()
			hero.Name = "Champion"
			return WorkingStore.shelf(place.root, hero, create) == first
		end)()
	)
end)

case("working copies are found again with the rig they belong to", function()
	local place = buildPlace()
	local hero, villain = place.rig("Hero"), place.rig("Villain")
	clip("Wave", WorkingStore.shelf(place.root, hero, create))
	clip("Bow", WorkingStore.shelf(place.root, hero, create))
	clip("Laugh", WorkingStore.shelf(place.root, villain, create))
	local found, unassigned = WorkingStore.discover(place.root)
	check("all three are found, in a stable order", names(found) == "Hero/Bow,Hero/Wave,Villain/Laugh", names(found))
	check("none is unassigned", unassigned == 0, unassigned)
	check("each comes with its rig", found[1].model == hero and found[3].model == villain)
	local again = WorkingStore.discover(place.root)
	check("looking again changes nothing", names(again) == names(found) and #place.root:GetDescendants() == 5)
end)

case("a working copy counts only while it stays on its own shelf", function()
	local folder = roblox.Instance.new("Folder")
	local function shelfFor(name: string): any
		local shelf = roblox.Instance.new("ObjectValue")
		shelf.Name = name
		shelf.Parent = folder
		return shelf
	end
	local first, second = shelfFor("A"), shelfFor("B")
	local clip = roblox.Instance.new("KeyframeSequence")
	clip.Parent = first
	check("on the shelf it was opened on", WorkingStore.onShelf(clip, first, folder))
	clip.Parent = second
	check("not once moved to another rig's shelf", not WorkingStore.onShelf(clip, first, folder))
	local plain = roblox.Instance.new("Folder")
	plain.Parent = folder
	clip.Parent = plain
	check("nor into a folder of its own", not WorkingStore.onShelf(clip, plain, folder))
	clip.Parent = first
	first.Parent = nil
	check("nor once its shelf is taken out of the folder", not WorkingStore.onShelf(clip, first, folder))
end)

case("copies whose rig cannot be told are counted, not guessed at", function()
	local place = buildPlace()
	local hero, gone = place.rig("Hero"), place.rig("Gone")
	clip("Wave", WorkingStore.shelf(place.root, hero, create))
	clip("Lost", WorkingStore.shelf(place.root, gone, create))
	clip("Lost too", WorkingStore.shelf(place.root, gone, create))
	-- Left in the folder directly, as copies made before shelves existed are.
	clip("Old", place.root)
	-- A shelf whose reference was never set.
	local blank = Instance.new("ObjectValue")
	blank.Name = "Blank"
	blank.Parent = place.root
	clip("Nobody's", blank)
	-- Things that are not clips are neither found nor counted.
	local note = Instance.new("Folder")
	note.Parent = place.root
	local stray = Instance.new("StringValue")
	stray.Parent = WorkingStore.shelf(place.root, hero, create)

	gone.Parent = nil
	local found, unassigned = WorkingStore.discover(place.root)
	check("only the copy with a rig still in the place is found", names(found) == "Hero/Wave", names(found))
	check("the others are counted", unassigned == 4, unassigned)
end)

case("an empty or missing arrangement finds nothing", function()
	local place = buildPlace()
	local found, unassigned = WorkingStore.discover(place.root)
	check("nothing found", #found == 0 and unassigned == 0)
	WorkingStore.shelf(place.root, place.rig("Hero"), create)
	local later, count2 = WorkingStore.discover(place.root)
	check("an empty shelf holds nothing", #later == 0 and count2 == 0)
end)

case("a place is known by its id, and a place never saved to Roblox by none", function()
	check("a saved place has a key", Access.key(123) == "123")
	check("an unsaved place has none", Access.key(0) == nil)
	check("nor has a bad or negative id", Access.key(0 / 0) == nil and Access.key(-5) == nil and Access.key(1.5) == nil)
	check("nor anything that is not a number", Access.key("123") == nil)
end)

case("the old list of places is read defensively", function()
	check("nothing is remembered from nothing", Access.remembered(nil, 123) == false)
	check("a place on in the list is remembered", Access.remembered({ ["123"] = true }, 123))
	check("and only that place", not Access.remembered({ ["123"] = true }, 456))
	check("an unsaved place is not remembered even if the list says so", not Access.remembered({ ["0"] = true }, 0))
	for label, stored in
		{
			["text"] = "123",
			["a number"] = 123,
			["true"] = true,
			["a list"] = { 123 },
			["a place set to something other than true"] = { ["123"] = "yes" },
			["a place set to false"] = { ["123"] = false },
		} :: { [string]: any }
	do
		check(`not remembered from {label}`, not Access.remembered(stored, 123))
	end
end)

case("what a working copy was opened from is written down and read back", function()
	local links = Instance.new("Folder")
	local function create(className: string): any
		return Instance.new(className)
	end
	local working = Instance.new("KeyframeSequence")
	working.Name = "Wave edit"
	local source = Instance.new("KeyframeSequence")
	source.Name = "Wave"
	check("nothing recorded to begin with", WorkingStore.recall(links, working) == nil)

	WorkingStore.remember(links, working, source, "abc123", create)
	local link = WorkingStore.recall(links, working) :: any
	check("the source is recalled", link ~= nil and link.source == source)
	check("with its fingerprint", link.fingerprint == "abc123")
	check("one record, named after the working copy", #links:GetChildren() == 1 and link.record.Name == "Wave edit")
	check("another working copy has no record", WorkingStore.recall(links, Instance.new("KeyframeSequence")) == nil)

	WorkingStore.remember(links, working, source, "def456", create)
	check(
		"recording again replaces, not adds",
		#links:GetChildren() == 1 and (WorkingStore.recall(links, working) :: any).fingerprint == "def456"
	)

	local other = Instance.new("KeyframeSequence")
	WorkingStore.remember(links, other, source, "zzz", create)
	check(
		"two copies of one clip each have a record",
		#links:GetChildren() == 2 and (WorkingStore.recall(links, other) :: any).fingerprint == "zzz"
	)

	local record = (WorkingStore.recall(links, working) :: any).record
	WorkingStore.forget(links, working)
	check(
		"a forgotten record is out of the folder",
		WorkingStore.recall(links, working) == nil and #links:GetChildren() == 1
	)
	check(
		"but whole, so that an undo can bring it back",
		record.Parent == nil and record:FindFirstChild(WorkingStore.SOURCE) ~= nil
	)
	WorkingStore.forget(links, working)
	check("forgetting twice is harmless", #links:GetChildren() == 1)

	-- A record someone has damaged is read as far as it can be.
	local broken = Instance.new("ObjectValue")
	broken.Value = working
	broken.Parent = links
	local partial = WorkingStore.recall(links, working) :: any
	check(
		"a record with nothing in it gives no source",
		partial ~= nil and partial.source == nil and partial.fingerprint == nil
	)
end)

print(`{count - failures}/{count} working store checks passed`)
if failures > 0 then
	process.exit(1)
end
