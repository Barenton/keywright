--!strict
-- Keyframe clip batches: checked before anything is applied, refused whole, limits held, only what is named changed, restoring.
-- Run with: lune run plugin/test/editing/operations/batch.test.luau

local Kit = require("./kit")

local blank = Kit.blank
local differing = Kit.differing
local Digest = Kit.Digest
local Operations = Kit.Operations
local pose = Kit.pose
local refusal = Kit.refusal
local refused = Kit.refused
local rich = Kit.rich
local run = Kit.run
local Sequence = Kit.Sequence
local snapshot = Kit.snapshot

local check, case, finish = Kit.suite("operation batch")
case("a batch is checked before anything is applied", function()
	local sequence = blank()
	check("not a list", (refusal(sequence, "set_pose") :: any).code == "INVALID_ARGUMENT")
	check("an empty list", (refusal(sequence, {}) :: any).code == "INVALID_ARGUMENT")
	local many = {}
	for index = 1, Operations.MAX_OPERATIONS + 1 do
		many[index] = { type = "add_keyframe", time = index / 10 }
	end
	check("too many operations", (refusal(sequence, many) :: any).code == "LIMIT_EXCEEDED")
	refused("an unknown type", sequence, { { type = "explode" } }, 'unknown operation type "explode"')
	local unknown = refusal(sequence, { { type = "explode" } }) :: any
	check("the hint lists the types", string.find(unknown.hint, "set_pose") and string.find(unknown.hint, "scale_time"))
	refused("the place in the list is named", sequence, {
		{ type = "add_keyframe", time = 0 },
		{ type = "add_keyframe", time = -1 },
	}, "operations[2]")
	check("nothing was applied", #Operations.keyframes(sequence) == 0)
end)

case("each operation refuses what it cannot use", function()
	local sequence = blank()
	local bad: { [string]: any } = {
		["a joint the rig lacks"] = { type = "set_pose", joint = "Tail", time = 0, rotation = { 0, 0, 0 } },
		["a pose with nothing to set"] = { type = "set_pose", joint = "Head", time = 0 },
		["a time past the limit"] = { type = "set_pose", joint = "Head", time = 301, rotation = { 0, 0, 0 } },
		["a time that is not a number"] = { type = "add_keyframe", time = 0 / 0 },
		["a position past the limit"] = { type = "set_pose", joint = "Head", time = 0, position = { 0, 1001, 0 } },
		["a rotation of two numbers"] = { type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0 } },
		["the deprecated easing style"] = {
			type = "set_easing",
			joint = "Head",
			time_from = 0,
			time_to = 1,
			easing_style = "Cubic",
		},
		["an easing direction that does not exist"] = {
			type = "set_easing",
			joint = "Head",
			time_from = 0,
			time_to = 1,
			easing_direction = "Sideways",
		},
		["easing with nothing to set"] = { type = "set_easing", joint = "Head", time_from = 0, time_to = 1 },
		["a range that runs backwards"] = {
			type = "offset_pose",
			joint = "Head",
			time_from = 2,
			time_to = 1,
			rotation = { 0, 0, 0 },
		},
		["a move with no destination"] = { type = "move_keyframe", time = 0 },
		["a shift by nothing"] = { type = "shift_time", time_from = 0, time_to = 1, offset = 0 },
		["a scale of zero"] = { type = "scale_time", time_from = 0, time_to = 1, factor = 0 },
		["a scale of one"] = { type = "scale_time", time_from = 0, time_to = 1, factor = 1 },
		["properties with nothing to set"] = { type = "set_properties" },
		["an empty name"] = { type = "set_properties", name = "" },
		["a loop that is not a boolean"] = { type = "set_properties", loop = "yes" },
		["a priority that does not exist"] = { type = "set_properties", priority = "Highest" },
		["a marker without a name"] = { type = "set_marker", time = 0 },
		["a marker value that is too long"] = {
			type = "set_marker",
			time = 0,
			name = "A",
			value = string.rep("x", 201),
		},
	}
	for name, operation in bad do
		local problem = refusal(sequence, { operation }) :: any
		check(name, type(problem) == "table" and problem.code == "INVALID_ARGUMENT", problem)
	end
	local cubic = refusal(sequence, { bad["the deprecated easing style"] }) :: any
	check("the hint for Cubic names its replacement", string.find(cubic.hint or "", "CubicV2") ~= nil, cubic.hint)
	check("nothing was applied", #sequence:GetChildren() == 0)
end)

case("an edit changes only what it names", function()
	local sequence = rich()
	local before = snapshot(sequence)
	run(sequence, { { type = "set_pose", joint = "Head", time = 1, rotation = { 0, 99, 0 } } })
	local after = snapshot(sequence)
	check("exactly one instance differs", differing(before, after) == 1, differing(before, after))
	check("and it is the pose named", before[pose(sequence, "Head", 1)] ~= after[pose(sequence, "Head", 1)])

	-- Every kind of edit, on the middle keyframe only: the first and last keep their
	-- instances and everything in them.
	local first, last = Operations.findKeyframe(sequence, 0) :: any, Operations.findKeyframe(sequence, 2) :: any
	local function outside(): string
		local lines = {}
		for _, keyframe in { first, last } do
			for instance, text in snapshot(keyframe) do
				table.insert(lines, tostring(instance) .. text)
			end
			table.insert(lines, `{keyframe.Time}`)
		end
		table.sort(lines)
		return table.concat(lines, "\n")
	end
	local untouched = outside()
	run(sequence, {
		{ type = "set_pose", joint = "RightHand", time = 1, rotation = { 10, 0, 0 } },
		{ type = "offset_pose", joint = "Head", time_from = 1, time_to = 1, rotation = { 0, 1, 0 } },
		{ type = "set_easing", joint = "Head", time_from = 1, time_to = 1, easing_style = "Bounce" },
		{ type = "set_marker", time = 1, name = "Step", value = "right" },
		{ type = "remove_pose", joint = "RightHand", time = 1 },
		{ type = "move_keyframe", time = 1, to = 1.25 },
		{ type = "duplicate_keyframe", time = 1.25, to = 1.5 },
		{ type = "remove_keyframe", time = 1.5 },
	})
	check("the keyframes not named are identical", outside() == untouched)
	check(
		"content that is not understood is still there",
		first:FindFirstChild("JawDrop").Value == 0.25 and sequence:FindFirstChild("Notes") ~= nil
	)
end)

case("a copy of a clip has the same fingerprint, unknown content included", function()
	local sequence = rich()
	local fingerprint = Digest.of(sequence)
	check("a copy matches", Digest.of(sequence:Clone()) == fingerprint)
	check("a copy of a copy matches", Digest.of(sequence:Clone():Clone()) == fingerprint)
	local altered = sequence:Clone()
	altered:FindFirstChild("JawDrop", true).Value = 0.5
	check("a change to content that is not understood shows", Digest.of(altered) ~= fingerprint)
	local dropped = sequence:Clone()
	dropped:FindFirstChild("JawDrop", true).Parent = nil
	check("and so does losing it", Digest.of(dropped) ~= fingerprint)
	local without = sequence:Clone()
	without:FindFirstChild("Notes").Parent = nil
	check("at the top of the clip too", Digest.of(without) ~= fingerprint)
end)

case("a batch that fails on a scratch copy leaves the clip alone", function()
	local sequence = rich()
	local fingerprint = Digest.of(sequence)
	local scratch = sequence:Clone()
	local problem = refusal(scratch, {
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 99, 0 } },
		{ type = "remove_keyframe", time = 2 },
		{ type = "move_keyframe", time = 2, to = 3 },
	}) :: any
	check(
		"the third operation is the one refused",
		string.find(problem.message, "operations[3]", 1, true) ~= nil,
		problem.message
	)
	check("the scratch copy took the first two", Digest.of(scratch) ~= fingerprint)
	check("the clip did not", Digest.of(sequence) == fingerprint)
end)

case("the keyframe limit holds for every way of making one", function()
	local limit = Sequence.MAX_KEYFRAMES
	Sequence.MAX_KEYFRAMES = 3
	local sequence = rich()
	local ways: { [string]: any } = {
		["a new keyframe"] = { type = "add_keyframe", time = 5 },
		["a pose at a new time"] = { type = "set_pose", joint = "Head", time = 5, rotation = { 0, 0, 0 } },
		["a marker at a new time"] = { type = "set_marker", time = 5, name = "A" },
		["a duplicate"] = { type = "duplicate_keyframe", time = 1, to = 5 },
	}
	for name, operation in ways do
		local problem = refusal(sequence, { operation }) :: any
		check(name, type(problem) == "table" and problem.code == "LIMIT_EXCEEDED", problem)
	end
	check(
		"a pose at an existing time is still allowed",
		refusal(sequence, { { type = "set_pose", joint = "RightFoot", time = 1, rotation = { 0, 0, 0 } } }) == nil
	)
	Sequence.MAX_KEYFRAMES = limit
end)

case("restoring puts the source's content back", function()
	local source = rich()
	local sequence = source:Clone()
	run(sequence, {
		{ type = "remove_keyframe", time = 2 },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 99, 0 } },
		{ type = "set_properties", loop = true, priority = "Core" },
	}, source)
	check("the copy differs after edits", Digest.of(sequence) ~= Digest.of(source))
	local changed = run(sequence, { { type = "restore_source" } }, source)
	check("restored", changed.restored == 1 and Digest.of(sequence) == Digest.of(source))
	check("the source was only read", #source:GetChildren() == 4)
	local empty = blank()
	run(empty, { { type = "add_keyframe", time = 1 } })
	run(empty, { { type = "restore_source" } })
	check("a clip opened blank is restored to blank", #empty:GetChildren() == 0)
end)

finish()
