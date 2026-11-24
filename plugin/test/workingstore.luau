--!strict
-- Offline tests for where working copies are kept and how they are found again, and for
-- remembering agent access per place. Run with: lune run plugin/test/workingstore.luau
--
-- Real here: Lune's instances. Not tested here: Studio's undo, plugin settings, and the
-- plugin picking copies up when it actually reloads.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Access = require("../src/Access")
local WorkingStore = require("../src/WorkingStore")

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

case("agent access is remembered for a saved place and never for an unsaved one", function()
	check("nothing is remembered to begin with", Access.remembered(nil, 123) == false)
	local stored = Access.update(nil, 123, true)
	check("turning it on is remembered for that place", Access.remembered(stored, 123))
	check("and not for another", not Access.remembered(stored, 456))
	stored = Access.update(stored, 456, true)
	check(
		"a second place is remembered beside the first",
		Access.remembered(stored, 123) and Access.remembered(stored, 456)
	)
	stored = Access.update(stored, 123, false)
	check("turning it off is forgotten", not Access.remembered(stored, 123) and Access.remembered(stored, 456))
	-- A place that has never been saved to Roblox has no identity of its own.
	local unsaved = Access.update(stored, 0, true)
	check("an unsaved place is never remembered", not Access.remembered(unsaved, 0))
	check("and asking does not disturb what is stored", Access.remembered(unsaved, 456))
	check("an unsaved place is not remembered even if something says so", not Access.remembered({ ["0"] = true }, 0))
end)

case("what is stored is read defensively", function()
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
	check("a bad place id is never remembered", not Access.remembered({ ["nan"] = true }, 0 / 0))
	check("a negative place id is never remembered", not Access.remembered({ ["-5"] = true }, -5))
	local repaired = Access.update("garbage" :: any, 123, true)
	check("updating replaces something unreadable", Access.remembered(repaired, 123))
	local kept = Access.update({ ["456"] = true, junk = "x", ["789"] = false } :: any, 123, true)
	check(
		"updating keeps only places that are on",
		Access.remembered(kept, 456) and kept.junk == nil and kept["789"] == nil
	)
end)

case("the list of remembered places is kept to a limit", function()
	local stored: any = nil
	for place = 1, Access.MAX_PLACES + 20 do
		stored = Access.update(stored, place, true)
	end
	local total = 0
	for _ in stored do
		total += 1
	end
	check("no more than the limit are kept", total == Access.MAX_PLACES, total)
	check("the newest is among them", Access.remembered(stored, Access.MAX_PLACES + 20))
	-- Setting what is already set does not push anything out.
	local before = Access.remembered(stored, Access.MAX_PLACES + 19)
	stored = Access.update(stored, Access.MAX_PLACES + 20, true)
	check("repeating a setting changes nothing", Access.remembered(stored, Access.MAX_PLACES + 19) == before)
end)

print(`{count - failures}/{count} working store checks passed`)
if failures > 0 then
	process.exit(1)
end
