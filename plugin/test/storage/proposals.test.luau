--!strict
-- Offline tests for proposals to replace a clip. Run with: lune run plugin/test/storage/proposals.test.luau
--
-- Real here: the bookkeeping of proposals, and copying one clip's content into another.
-- Not tested here: the panel's buttons, the checks an approval makes on the working copy
-- and its source, and Studio's undo of a replacement. Those need Studio and a person.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Roblox = require("../../src/Core/Roblox") :: any
Roblox.Instance = roblox.Instance
Roblox.CFrame = roblox.CFrame
Roblox.Enum = roblox.Enum

local Digest = require("../../src/Inspection/Digest")
local Operations = require("../../src/Editing/Operations")
local Proposals = require("../../src/Storage/Proposals")
local Rig = require("../../src/Rigs/Rig")

local Instance = roblox.Instance
local Enum = roblox.Enum

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
	for _, id in { "clip_1", "clip_2", "clip_3" } do
		Proposals.forget(id)
	end
	local ok, problem = pcall(run)
	if not ok then
		count += 1
		failures += 1
		print(
			`FAIL [{name}] raised: {if type(problem) == "table" then (problem :: any).message else tostring(problem)}`
		)
	end
end

case("a proposal waits until it is settled, once", function()
	check("none to begin with", Proposals.get("clip_1") == nil and #Proposals.pending() == 0)
	local proposal, made = Proposals.propose("clip_1", "r4", "Wave edit", "Wave")
	check("made, and waiting", made and proposal.status == "pending" and proposal.revision == "r4")
	check("with the names the panel shows", proposal.name == "Wave edit" and proposal.source == "Wave")
	check("listed as waiting", #Proposals.pending() == 1 and Proposals.pending()[1] == proposal)

	local settled = Proposals.settle("clip_1", true)
	check("approved", settled == proposal and proposal.status == "approved" and proposal.reason == nil)
	check("no longer waiting", #Proposals.pending() == 0)
	check(
		"and cannot be settled again",
		Proposals.settle("clip_1", false, "changed my mind") == nil and proposal.status == "approved"
	)
	check("nothing to settle for a clip with no proposal", Proposals.settle("clip_2", true) == nil)
end)

case("asking again for the same revision changes nothing", function()
	local first = Proposals.propose("clip_1", "r4", "Wave edit", "Wave")
	local again, made = Proposals.propose("clip_1", "r4", "Wave edit", "Wave")
	check("the same proposal, not a second one", again == first and not made and #Proposals.pending() == 1)
	Proposals.settle("clip_1", false, "A person rejected it in Studio.")
	local after, remade = Proposals.propose("clip_1", "r4", "Wave edit", "Wave")
	check("a rejection stands for that revision", after == first and not remade and after.status == "rejected")
	check("with its reason", after.reason == "A person rejected it in Studio.")
	check("and is not waiting", #Proposals.pending() == 0)
end)

case("a new revision is a new proposal", function()
	local old = Proposals.propose("clip_1", "r4", "Wave edit", "Wave")
	Proposals.settle("clip_1", false, "no")
	local new, made = Proposals.propose("clip_1", "r5", "Wave edit", "Wave")
	check("made afresh, and waiting", made and new ~= old and new.status == "pending" and new.reason == nil)
	check("the old one is gone", Proposals.get("clip_1") == new)
	local replaced = Proposals.propose("clip_1", "r6", "Wave edit", "Wave")
	check(
		"a waiting proposal for an older revision is dropped too",
		#Proposals.pending() == 1 and Proposals.pending()[1] == replaced
	)
end)

case("proposals wait in the order they were made, and are forgotten with their clip", function()
	Proposals.propose("clip_2", "r1", "B", "b")
	Proposals.propose("clip_1", "r1", "A", "a")
	Proposals.propose("clip_3", "r1", "C", "c")
	local order = {}
	for _, proposal in Proposals.pending() do
		table.insert(order, proposal.clipId)
	end
	check("oldest first", table.concat(order, " ") == "clip_2 clip_1 clip_3", table.concat(order, " "))
	Proposals.forget("clip_2")
	check("a discarded clip's proposal is gone", Proposals.get("clip_2") == nil and #Proposals.pending() == 2)
	Proposals.forget("clip_2")
	check("forgetting twice is harmless", #Proposals.pending() == 2)
end)

case("listeners hear of every change, and can stop", function()
	local heard = 0
	local stop = Proposals.subscribe(function()
		heard += 1
	end)
	Proposals.subscribe(function()
		error("a listener that fails")
	end)
	Proposals.propose("clip_1", "r1", "A", "a")
	check("a new proposal", heard == 1)
	Proposals.propose("clip_1", "r1", "A", "a")
	check("not asking again", heard == 1)
	Proposals.settle("clip_1", true)
	check("a decision", heard == 2)
	Proposals.settle("clip_1", true)
	check("not a decision that changed nothing", heard == 2)
	Proposals.forget("clip_1")
	check("a proposal forgotten", heard == 3)
	stop()
	Proposals.propose("clip_1", "r2", "A", "a")
	check("nothing after stopping", heard == 3)
end)

case("replacing copies the working copy's content into the clip", function()
	local joints: { [string]: any } = {}
	for _, name in Rig.R15_ORDER do
		joints[name] = true
	end
	local function clip(name: string, operations: { any }): any
		local sequence = Instance.new("KeyframeSequence")
		sequence.Name = name
		sequence.Loop = false
		sequence.Priority = Enum.AnimationPriority.Action
		Operations.run(sequence, operations, { joints = joints })
		return sequence
	end
	local source = clip("Wave", {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 10, 0 } },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 20, 0 } },
	})
	local working = clip("Wave edit", {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 10, 0 } },
		{ type = "set_pose", joint = "LeftHand", time = 0.5, rotation = { 0, 0, 30 } },
		{ type = "set_marker", time = 0.5, name = "Clap" },
		{ type = "set_properties", loop = true, priority = "Movement" },
	})
	local kept = source:GetChildren()
	local workingBefore = Digest.of(working)
	Operations.copyContent(working, source)
	check("the clip now plays what the working copy plays", Digest.of(source) == workingBefore)
	check("with its settings", source.Loop == true and source.Priority == Enum.AnimationPriority.Movement)
	check("under its own name", source.Name == "Wave")
	check("the working copy is unchanged", Digest.of(working) == workingBefore and #working:GetChildren() == 2)
	check("and shares no instance with the clip", source:GetChildren()[1] ~= working:GetChildren()[1])
	local stillWhole = true
	for _, keyframe in kept do
		-- Taken out, not destroyed: an undo can put it back.
		stillWhole = stillWhole and keyframe.Parent == nil and #keyframe:GetDescendants() > 0
	end
	check("what the clip held before is taken out whole", stillWhole and #kept == 2)
end)

print(`{count - failures}/{count} proposal checks passed`)
if failures > 0 then
	process.exit(1)
end
