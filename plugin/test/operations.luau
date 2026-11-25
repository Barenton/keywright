--!strict
-- Offline tests for the edit operations. Run with: lune run plugin/test/operations.luau
--
-- Real here: Lune's instances and CFrame arithmetic, and the operations themselves.
-- Not tested here: undo, revisions and working copies (Edit and Clips, which need
-- Studio), and how Studio plays what these operations write.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Roblox = require("../src/Roblox") :: any
Roblox.Instance = roblox.Instance
Roblox.CFrame = roblox.CFrame
Roblox.Enum = roblox.Enum

local Digest = require("../src/Digest")
local Operations = require("../src/Operations")
local Rig = require("../src/Rig")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
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
	local ok, problem = pcall(run)
	if not ok then
		count += 1
		failures += 1
		print(
			`FAIL [{name}] raised: {if type(problem) == "table" then (problem :: any).message else tostring(problem)}`
		)
	end
end

-- Every standard joint, as the rig's joint table would have it.
local JOINTS: { [string]: any } = {}
for _, name in Rig.R15_ORDER do
	JOINTS[name] = true
end

local function blank(): any
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "Clip"
	sequence.Loop = false
	sequence.Priority = Enum.AnimationPriority.Action
	return sequence
end

local function run(sequence: any, operations: { any }, source: any?): { [string]: number }
	Operations.check(operations, JOINTS)
	return Operations.run(sequence, operations, { joints = JOINTS, source = source })
end

-- What a batch is refused with, or nil if it went through.
local function refusal(sequence: any, operations: any, source: any?): any
	local ok, problem = pcall(run, sequence, operations, source)
	return if ok then nil else problem
end

local function refused(name: string, sequence: any, operations: any, pattern: string, code: string?)
	local problem = refusal(sequence, operations)
	check(
		name,
		type(problem) == "table"
			and problem.code == (code or "INVALID_ARGUMENT")
			and string.find(problem.message, pattern, 1, true) ~= nil,
		if type(problem) == "table" then `{problem.code}: {problem.message}` else problem
	)
end

local function times(sequence: any): string
	local list = {}
	for _, keyframe in Operations.keyframes(sequence) do
		table.insert(list, string.format("%.3f", keyframe.Time))
	end
	return table.concat(list, " ")
end

local function pose(sequence: any, joint: string, time: number): any
	local keyframe = Operations.findKeyframe(sequence, time)
	return keyframe and Operations.findPose(keyframe, joint)
end

local function yaw(cframe: any): number
	local _, y = cframe:ToEulerAnglesXYZ()
	return math.deg(y)
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 0.001
end

-- A clip with three keyframes, a pose with the deprecated easing style, and content the
-- operations do not understand: a NumberPose in the first keyframe and a Folder in the clip.
local function rich(): any
	local sequence = blank()
	run(sequence, {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 10, 0 } },
		{ type = "set_pose", joint = "LeftUpperArm", time = 0, rotation = { 0, 0, -45 } },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 20, 0 }, position = { 0, 0.5, 0 } },
		{ type = "set_pose", joint = "Head", time = 2, rotation = { 0, 30, 0 } },
		{ type = "set_marker", time = 1, name = "Step", value = "left" },
	})
	pose(sequence, "LeftUpperArm", 0).EasingStyle = Enum.PoseEasingStyle.Cubic
	local face = Instance.new("NumberPose")
	face.Name = "JawDrop"
	face.Value = 0.25
	face.Parent = Operations.findKeyframe(sequence, 0)
	local folder = Instance.new("Folder")
	folder.Name = "Notes"
	folder.Parent = sequence
	return sequence
end

-- The instances of a clip and what each holds, to show what an edit left alone.
local function snapshot(sequence: any): { [any]: string }
	local seen: { [any]: string } = {}
	for _, instance in sequence:GetDescendants() do
		local text = instance.ClassName .. "|" .. instance.Name
		if instance:IsA("Pose") then
			local parts = { instance.CFrame:GetComponents() }
			for index, value in parts do
				parts[index] = string.format("%.6f", value)
			end
			text ..= `|{table.concat(parts, ",")}|{instance.Weight}|{instance.EasingStyle}|{instance.EasingDirection}`
		elseif instance:IsA("Keyframe") then
			text ..= `|{instance.Time}`
		elseif instance:IsA("KeyframeMarker") or instance:IsA("NumberPose") then
			text ..= `|{instance.Value}`
		end
		seen[instance] = text
	end
	return seen
end

-- How many instances differ between two snapshots, counting ones only in the first.
local function differing(before: { [any]: string }, after: { [any]: string }): number
	local different = 0
	for instance, text in before do
		if after[instance] ~= text then
			different += 1
		end
	end
	return different
end

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

case("setting a pose creates what it needs and nothing more", function()
	local sequence = blank()
	local changed = run(sequence, { { type = "set_pose", joint = "Head", time = 1, rotation = { 0, 30, 0 } } })
	check("one keyframe and one pose are counted", changed.keyframes_created == 1 and changed.poses_created == 1)
	local head = pose(sequence, "Head", 1)
	check("the pose turns the head", head and near(yaw(head.CFrame), 30) and head.Weight == 1)
	local ancestors = {}
	local above = head.Parent
	while above:IsA("Pose") do
		table.insert(ancestors, 1, `{above.Name}:{above.Weight}`)
		above = above.Parent
	end
	check(
		"it is nested under weightless poses for the parts above it",
		table.concat(ancestors, " ") == "HumanoidRootPart:0 LowerTorso:0 UpperTorso:0",
		table.concat(ancestors, " ")
	)

	changed = run(sequence, { { type = "set_pose", joint = "Head", time = 1.0004, position = { 0, 2, 0 } } })
	check("a time within a millisecond is the same keyframe", times(sequence) == "1.000" and changed.poses_changed == 1)
	check("a position alone keeps the rotation", near(yaw(head.CFrame), 30) and near(head.CFrame.Position.Y, 2))
	run(sequence, { { type = "set_pose", joint = "Head", time = 1, rotation = { 0, -15, 0 } } })
	check("a rotation alone keeps the position", near(yaw(head.CFrame), -15) and near(head.CFrame.Position.Y, 2))
	run(sequence, { { type = "set_pose", joint = "Head", time = 1, rotation = { 0, 10, 0 }, relative = true } })
	check("a relative pose is applied on top", near(yaw(head.CFrame), -5), yaw(head.CFrame))

	changed = run(sequence, {
		{
			type = "set_pose",
			joint = "UpperTorso",
			time = 1,
			rotation = { 5, 0, 0 },
			easing_style = "Bounce",
			easing_direction = "Out",
		},
	})
	local torso = pose(sequence, "UpperTorso", 1)
	check("a placeholder that gets a pose counts as created", changed.poses_created == 1 and torso.Weight == 1)
	check("and still holds the pose under it", torso:FindFirstChild("Head") == head)
	check(
		"easing can be set with the pose",
		torso.EasingStyle == Enum.PoseEasingStyle.Bounce and torso.EasingDirection == Enum.PoseEasingDirection.Out
	)
end)

case("removing a pose keeps what hangs from it", function()
	local sequence = blank()
	run(sequence, {
		{ type = "set_pose", joint = "UpperTorso", time = 0, rotation = { 5, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 30, 0 } },
		{ type = "set_pose", joint = "LeftHand", time = 0, rotation = { 0, 0, 10 } },
	})
	local keyframe = Operations.findKeyframe(sequence, 0) :: any
	local changed = run(sequence, { { type = "remove_pose", joint = "UpperTorso", time = 0 } })
	local torso = keyframe:FindFirstChild("UpperTorso", true)
	check("a pose with poses under it becomes a placeholder", changed.poses_removed == 1 and torso.Weight == 0)
	check("which no longer turns its joint", near(select(1, torso.CFrame:ToEulerAnglesXYZ()), 0))
	check("the pose under it is untouched", near(yaw(pose(sequence, "Head", 0).CFrame), 30))

	run(sequence, { { type = "remove_pose", joint = "LeftHand", time = 0 } })
	check("a pose at the end of a chain is removed", keyframe:FindFirstChild("LeftHand", true) == nil)
	check("with the placeholders that only held it", keyframe:FindFirstChild("LeftUpperArm", true) == nil)
	check("but not ones that hold something else", keyframe:FindFirstChild("UpperTorso", true) ~= nil)

	run(sequence, { { type = "remove_pose", joint = "Head", time = 0 } })
	check("removing the last pose empties the keyframe", #keyframe:GetChildren() == 0)
	check("and leaves the keyframe itself", times(sequence) == "0.000")
	refused("a pose that is not there", sequence, { { type = "remove_pose", joint = "Head", time = 0 } }, "has no pose")
	refused(
		"a keyframe that is not there",
		sequence,
		{ { type = "remove_pose", joint = "Head", time = 9 } },
		"no keyframe at 9"
	)
end)

case("an offset applies to every pose of the joint in the range", function()
	local sequence = rich()
	local changed = run(sequence, {
		{
			type = "offset_pose",
			joint = "Head",
			time_from = 1,
			time_to = 2,
			rotation = { 0, 5, 0 },
			position = { 0, 1, 0 },
		},
	})
	check("two poses changed", changed.poses_changed == 2, changed.poses_changed)
	check("outside the range is untouched", near(yaw(pose(sequence, "Head", 0).CFrame), 10))
	check(
		"inside is turned further",
		near(yaw(pose(sequence, "Head", 1).CFrame), 25) and near(yaw(pose(sequence, "Head", 2).CFrame), 35)
	)
	refused(
		"a range with no pose of that joint",
		sequence,
		{ { type = "offset_pose", joint = "RightFoot", time_from = 0, time_to = 2, rotation = { 0, 5, 0 } } },
		"has no pose from 0 to 2"
	)
end)

case("easing is set per pose, and the deprecated style is left where it is", function()
	local sequence = rich()
	run(sequence, {
		{
			type = "set_easing",
			joint = "Head",
			time_from = 0,
			time_to = 1,
			easing_style = "Elastic",
			easing_direction = "InOut",
		},
	})
	check(
		"poses in the range take the easing",
		pose(sequence, "Head", 0).EasingStyle == Enum.PoseEasingStyle.Elastic
			and pose(sequence, "Head", 1).EasingDirection == Enum.PoseEasingDirection.InOut
	)
	check("a pose outside does not", pose(sequence, "Head", 2).EasingStyle == Enum.PoseEasingStyle.Linear)
	check(
		"a pose with the deprecated style keeps it",
		pose(sequence, "LeftUpperArm", 0).EasingStyle == Enum.PoseEasingStyle.Cubic
	)
	run(sequence, { { type = "set_pose", joint = "LeftUpperArm", time = 0, rotation = { 0, 0, -50 } } })
	check(
		"even when the pose itself is edited",
		pose(sequence, "LeftUpperArm", 0).EasingStyle == Enum.PoseEasingStyle.Cubic
	)
	run(sequence, { { type = "set_easing", joint = "Head", time_from = 2, time_to = 2, easing_direction = "Out" } })
	check(
		"a direction alone leaves the style",
		pose(sequence, "Head", 2).EasingStyle == Enum.PoseEasingStyle.Linear
			and pose(sequence, "Head", 2).EasingDirection == Enum.PoseEasingDirection.Out
	)
end)

case("keyframes are added, removed, moved and duplicated", function()
	local sequence = rich()
	run(sequence, { { type = "add_keyframe", time = 0.5 } })
	check("added", times(sequence) == "0.000 0.500 1.000 2.000", times(sequence))
	refused("adding where one is", sequence, { { type = "add_keyframe", time = 1.0005 } }, "already a keyframe")

	local changed = run(sequence, { { type = "duplicate_keyframe", time = 1, to = 3 } })
	local copy = Operations.findKeyframe(sequence, 3) :: any
	check(
		"a duplicate is a new keyframe",
		changed.keyframes_created == 1 and times(sequence) == "0.000 0.500 1.000 2.000 3.000"
	)
	check("with the poses of the original", near(yaw(pose(sequence, "Head", 3).CFrame), 20))
	check("and its markers", copy:FindFirstChild("Step") ~= nil and copy:FindFirstChild("Step").Value == "left")
	check("as separate instances", pose(sequence, "Head", 3) ~= pose(sequence, "Head", 1))
	refused(
		"duplicating onto another",
		sequence,
		{ { type = "duplicate_keyframe", time = 1, to = 2 } },
		"already a keyframe"
	)
	refused(
		"duplicating what is not there",
		sequence,
		{ { type = "duplicate_keyframe", time = 7, to = 8 } },
		"no keyframe at 7"
	)

	local moving = Operations.findKeyframe(sequence, 3)
	run(sequence, { { type = "move_keyframe", time = 3, to = 2.5 } })
	check(
		"moved",
		Operations.findKeyframe(sequence, 2.5) == moving and times(sequence) == "0.000 0.500 1.000 2.000 2.500"
	)
	refused("moving onto another", sequence, { { type = "move_keyframe", time = 2.5, to = 2 } }, "already a keyframe")
	check(
		"moving onto itself is allowed",
		refusal(sequence, { { type = "move_keyframe", time = 2.5, to = 2.5004 } }) == nil
	)

	changed = run(sequence, { { type = "remove_keyframe", time = 0.5 }, { type = "remove_keyframe", time = 2.5 } })
	check("removed", changed.keyframes_removed == 2 and times(sequence) == "0.000 1.000 2.000", times(sequence))
	refused("removing what is not there", sequence, { { type = "remove_keyframe", time = 0.5 } }, "no keyframe at 0.5")
end)

case("a range of keyframes is shifted", function()
	local sequence = rich()
	local changed = run(sequence, { { type = "shift_time", time_from = 1, time_to = 2, offset = 0.5 } })
	check(
		"the range moved together",
		changed.keyframes_moved == 2 and times(sequence) == "0.000 1.500 2.500",
		times(sequence)
	)
	run(sequence, { { type = "shift_time", time_from = 1.5, time_to = 2.5, offset = -0.5 } })
	check("and back", times(sequence) == "0.000 1.000 2.000", times(sequence))
	refused(
		"onto a keyframe outside the range",
		sequence,
		{ { type = "shift_time", time_from = 1, time_to = 1, offset = 1 } },
		"would land on the one at 2"
	)
	refused(
		"past a keyframe outside the range",
		sequence,
		{ { type = "shift_time", time_from = 1, time_to = 1, offset = 1.5 } },
		"would pass the one at 2"
	)
	refused(
		"before zero",
		sequence,
		{ { type = "shift_time", time_from = 0, time_to = 2, offset = -1 } },
		"outside 0 to"
	)
	refused(
		"past the limit",
		sequence,
		{ { type = "shift_time", time_from = 0, time_to = 2, offset = 299 } },
		"outside 0 to"
	)
	refused(
		"an empty range",
		sequence,
		{ { type = "shift_time", time_from = 5, time_to = 6, offset = 1 } },
		"no keyframes from 5 to 6"
	)
	check("refusals changed nothing", times(sequence) == "0.000 1.000 2.000", times(sequence))
end)

case("a range of keyframes is scaled", function()
	local sequence = rich()
	run(sequence, { { type = "scale_time", time_from = 0, time_to = 2, factor = 2 } })
	check("from the start of the range by default", times(sequence) == "0.000 2.000 4.000", times(sequence))
	run(sequence, { { type = "scale_time", time_from = 0, time_to = 4, factor = 0.5, anchor = 4 } })
	check("or about a chosen time", times(sequence) == "2.000 3.000 4.000", times(sequence))
	run(sequence, { { type = "add_keyframe", time = 5 }, { type = "add_keyframe", time = 2.05 } })
	refused(
		"past a keyframe outside the range",
		sequence,
		{ { type = "scale_time", time_from = 3, time_to = 4, factor = 4, anchor = 2 } },
		"would pass the one at 5"
	)
	refused(
		"onto a keyframe outside the range",
		sequence,
		{ { type = "scale_time", time_from = 3, time_to = 4, factor = 3, anchor = 2 } },
		"would land on the one at 5"
	)
	refused(
		"so small that keyframes meet",
		sequence,
		{ { type = "scale_time", time_from = 2, time_to = 2.05, factor = 0.01 } },
		"would land on each other"
	)
	check("refusals changed nothing", times(sequence) == "2.000 2.050 3.000 4.000 5.000", times(sequence))
end)

case("the clip's own settings are changed", function()
	local sequence = blank()
	local changed = run(sequence, { { type = "set_properties", name = "Wave", loop = true, priority = "Movement" } })
	check("counted once", changed.properties_changed == 1)
	check(
		"all three are set",
		sequence.Name == "Wave" and sequence.Loop == true and sequence.Priority == Enum.AnimationPriority.Movement
	)
	run(sequence, { { type = "set_properties", loop = false } })
	check(
		"one alone leaves the others",
		sequence.Name == "Wave" and sequence.Loop == false and sequence.Priority == Enum.AnimationPriority.Movement
	)
end)

case("markers are set and removed", function()
	local sequence = rich()
	local changed = run(sequence, { { type = "set_marker", time = 1.5, name = "Clap" } })
	check(
		"a marker at a new time creates its keyframe",
		changed.keyframes_created == 1 and times(sequence) == "0.000 1.000 1.500 2.000"
	)
	local keyframe = Operations.findKeyframe(sequence, 1.5) :: any
	check("with an empty value by default", keyframe:FindFirstChild("Clap").Value == "")
	run(sequence, { { type = "set_marker", time = 1.5, name = "Clap", value = "loud" } })
	check(
		"setting it again updates it",
		#keyframe:GetChildren() == 1 and keyframe:FindFirstChild("Clap").Value == "loud"
	)
	run(sequence, { { type = "set_marker", time = 1.5, name = "Stomp", value = "" } })
	check("a second name is a second marker", #keyframe:GetChildren() == 2)
	changed = run(sequence, { { type = "remove_marker", time = 1.5, name = "Clap" } })
	check(
		"removed by name",
		changed.markers_removed == 1
			and keyframe:FindFirstChild("Clap") == nil
			and keyframe:FindFirstChild("Stomp") ~= nil
	)
	refused(
		"a marker that is not there",
		sequence,
		{ { type = "remove_marker", time = 1.5, name = "Clap" } },
		'no marker "Clap"'
	)
	check(
		"the marker made earlier is untouched",
		(Operations.findKeyframe(sequence, 1) :: any):FindFirstChild("Step").Value == "left"
	)
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
	local limit = Operations.MAX_KEYFRAMES
	Operations.MAX_KEYFRAMES = 3
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
	Operations.MAX_KEYFRAMES = limit
end)

case("a keyframe can hold the pose the clip already has", function()
	local sequence = blank()
	run(sequence, {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 40, 0 } },
		{
			type = "set_pose",
			joint = "LeftHand",
			time = 0,
			rotation = { 0, 0, 0 },
			easing_style = "Bounce",
			easing_direction = "Out",
		},
		{ type = "set_pose", joint = "LeftHand", time = 1, rotation = { 0, 0, 60 } },
	})
	check("the joints a clip moves are found", table.concat(Operations.animated(sequence), " ") == "Head LeftHand")

	-- The engine supplies the poses; here they are given, as it would give them.
	local operations = { { type = "add_keyframe", time = 0.25 }, { type = "add_keyframe", time = 0.5, hold = true } }
	check("the places of such keyframes in a batch", table.concat(Operations.holds(operations), " ") == "2")
	Operations.check(operations, JOINTS)
	local holds = {}
	local changed = Operations.run(sequence, operations, {
		joints = JOINTS,
		held = { [2] = { Head = CFrame.Angles(0, math.rad(20), 0), LeftHand = CFrame.Angles(0, 0, math.rad(45)) } },
		holds = holds,
	})
	check(
		"a keyframe and a pose for each joint",
		changed.keyframes_created == 2 and changed.poses_created == 2,
		changed.poses_created
	)
	local head, hand = pose(sequence, "Head", 0.5), pose(sequence, "LeftHand", 0.5)
	check("each holds the pose it was given", near(yaw(head.CFrame), 20) and head.Weight == 1 and hand.Weight == 1)
	check(
		"each takes the easing of the pose before it",
		head.EasingStyle == Enum.PoseEasingStyle.Linear
			and hand.EasingStyle == Enum.PoseEasingStyle.Bounce
			and hand.EasingDirection == Enum.PoseEasingDirection.Out
	)
	check(
		"the plain keyframe added beside it is empty",
		#(Operations.findKeyframe(sequence, 0.25) :: any):GetChildren() == 0
	)
	check(
		"what is reported: the time and how many joints",
		#holds == 1 and holds[1].time == 0.5 and holds[1].joints == 2
	)
	check(
		"and the joints whose motion is no longer the same",
		holds[1].motion_changed and table.concat(holds[1].motion_changed, " ") == "LeftHand",
		holds[1].motion_changed and table.concat(holds[1].motion_changed, " ")
	)

	local straight = {}
	Operations.run(sequence, { { type = "add_keyframe", time = 0.75, hold = true } }, {
		joints = JOINTS,
		held = { [1] = { Head = CFrame.Angles(0, math.rad(30), 0) } },
		holds = straight,
	})
	check(
		"nothing is flagged when the easing is straight",
		straight[1].motion_changed == nil and straight[1].joints == 1
	)
	check("a joint not given a pose gets none", pose(sequence, "LeftHand", 0.75) == nil)

	-- A joint is keyed only between two of its own poses.
	run(sequence, { { type = "set_pose", joint = "RightFoot", time = 0.6, rotation = { 10, 0, 0 } } })
	local outside = {}
	Operations.run(
		sequence,
		{ { type = "add_keyframe", time = 0.4, hold = true }, { type = "add_keyframe", time = 0.9, hold = true } },
		{
			joints = JOINTS,
			held = {
				[1] = { Head = CFrame.Angles(0, math.rad(16), 0), RightFoot = CFrame.new() },
				[2] = { Head = CFrame.Angles(0, math.rad(36), 0), RightFoot = CFrame.Angles(math.rad(10), 0, 0) },
			},
			holds = outside,
		}
	)
	check("not before its first pose", pose(sequence, "RightFoot", 0.4) == nil and outside[1].joints == 1)
	check("nor after its last", pose(sequence, "RightFoot", 0.9) == nil and outside[2].joints == 1)
	check(
		"while a joint that is between two of its poses is",
		pose(sequence, "Head", 0.4) ~= nil and pose(sequence, "Head", 0.9) ~= nil
	)

	local missing = refusal(sequence, { { type = "add_keyframe", time = 0.95, hold = true } }) :: any
	check(
		"without poses from the engine it is refused",
		missing.code == "PREVIEW_UNAVAILABLE" and Operations.findKeyframe(sequence, 0.95) == nil,
		missing.code
	)
	refused(
		"onto an existing keyframe",
		sequence,
		{ { type = "add_keyframe", time = 0.5, hold = true } },
		"already a keyframe"
	)
	refused(
		"hold must be a boolean",
		sequence,
		{ { type = "add_keyframe", time = 0.95, hold = "yes" } },
		"hold must be true or false"
	)
	local many = {}
	for index = 1, Operations.MAX_HOLDS + 1 do
		many[index] = { type = "add_keyframe", time = 2 + index, hold = true }
	end
	check("a batch has a limit on them", (refusal(sequence, many) :: any).code == "LIMIT_EXCEEDED")
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

-- A clip for smoothing: the head turning through three keys, the chest through two, one
-- hand keyed once, and a marker on the head's middle key.
local function sparse(): any
	local sequence = blank()
	run(sequence, {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 0.33, rotation = { 0, 40, 0 }, easing_style = "Bounce" },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 90, 0 } },
		{ type = "set_pose", joint = "UpperTorso", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "UpperTorso", time = 1, rotation = { 10, 0, 0 } },
		{ type = "set_pose", joint = "LeftHand", time = 0.5, rotation = { 0, 0, 20 } },
		{ type = "set_marker", time = 0.33, name = "Hit" },
	})
	return sequence
end

case("smoothing replaces a joint's keys by a curve through them", function()
	local sequence = sparse()
	local hand = pose(sequence, "LeftHand", 0.5)
	local handBefore = snapshot(sequence)[hand]
	local changed = run(sequence, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 10 } })
	check(
		"a keyframe at every step, and the one that holds a marker is kept",
		times(sequence) == "0.000 0.100 0.200 0.300 0.330 0.400 0.500 0.600 0.700 0.800 0.900 1.000",
		times(sequence)
	)
	check("the keys it was drawn through are gone", pose(sequence, "Head", 0.33) == nil)
	check("the marker is still there", (Operations.findKeyframe(sequence, 0.33) :: any):FindFirstChild("Hit") ~= nil)
	check(
		"what changed is counted",
		changed.poses_removed == 5 and changed.poses_created == 22 and changed.keyframes_created == 8,
		`{changed.poses_removed} {changed.poses_created} {changed.keyframes_created}`
	)

	local rising, last = true, -1
	for step = 0, 10 do
		local head = pose(sequence, "Head", step / 10)
		rising = rising and head ~= nil and head.Weight == 1 and yaw(head.CFrame) > last
		rising = rising and head.EasingStyle == Enum.PoseEasingStyle.Linear
		last = if head then yaw(head.CFrame) else last
	end
	check("the head turns steadily onwards through every step, by straight stretches", rising)
	check(
		"it starts and ends where it was keyed",
		near(yaw(pose(sequence, "Head", 0).CFrame), 0) and near(yaw(pose(sequence, "Head", 1).CFrame), 90)
	)
	check(
		"and passes its middle key on the way",
		yaw(pose(sequence, "Head", 0.3).CFrame) < 40 and yaw(pose(sequence, "Head", 0.4).CFrame) > 40,
		yaw(pose(sequence, "Head", 0.3).CFrame)
	)
	local chest = pose(sequence, "UpperTorso", 0.5)
	local pitch = math.deg((select(1, chest.CFrame:ToEulerAnglesXYZ())))
	check("a joint with two keys is eased between them", near(pitch, 5) and chest.Weight == 1, pitch)
	check("poses stay nested as the rig is", pose(sequence, "Head", 0.5).Parent == chest)
	check("a joint keyed once is left exactly as it was", snapshot(sequence)[hand] == handBefore and hand.Parent ~= nil)
end)

case("smoothing touches only the joints and the range it is given", function()
	local sequence = sparse()
	local chestStart, chestEnd = pose(sequence, "UpperTorso", 0), pose(sequence, "UpperTorso", 1)
	local before = snapshot(sequence)
	run(sequence, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 10, joints = { "Head" } } })
	local after = snapshot(sequence)
	check(
		"the other joint's keys are the same instances, unchanged",
		after[chestStart] == before[chestStart] and after[chestEnd] == before[chestEnd]
	)
	local between = pose(sequence, "UpperTorso", 0.5)
	check("and it gains no poses of its own, only placeholders", between ~= nil and between.Weight == 0)

	-- Keys off the steps: a pose at the first key, at each step between, and at the last.
	local offset = blank()
	run(offset, {
		{ type = "set_pose", joint = "RightFoot", time = 0.04, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "RightFoot", time = 0.96, rotation = { 30, 0, 0 } },
	})
	run(offset, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 10 } })
	check(
		"steps are counted from the start of the range",
		times(offset) == "0.040 0.100 0.200 0.300 0.400 0.500 0.600 0.700 0.800 0.900 0.960",
		times(offset)
	)

	local narrow = sparse()
	refused(
		"a range holding fewer than two keys of any joint",
		narrow,
		{ { type = "smooth_motion", time_from = 0.2, time_to = 0.8 } },
		"no joint has two or more poses"
	)
	check("which changes nothing", times(narrow) == "0.000 0.330 0.500 1.000", times(narrow))
end)

case("a snap arrives fast, and a loop carries on across its join", function()
	local function punch(): any
		local sequence = blank()
		run(sequence, {
			{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
			{ type = "set_pose", joint = "Head", time = 0.2, rotation = { 0, 80, 0 } },
			{ type = "set_pose", joint = "Head", time = 0.6, rotation = { 0, 60, 0 } },
		})
		return sequence
	end
	local eased, snapped = punch(), punch()
	run(eased, { { type = "smooth_motion", time_from = 0, time_to = 0.6, rate = 20 } })
	run(snapped, { { type = "smooth_motion", time_from = 0, time_to = 0.6, rate = 20, snap_at = { 0.2 } } })
	local easedYaw, snappedYaw = yaw(pose(eased, "Head", 0.15).CFrame), yaw(pose(snapped, "Head", 0.15).CFrame)
	check("a step before the key, the eased move is most of the way there", easedYaw > 60, easedYaw)
	check("and the snapped one still has ground to cover", snappedYaw < easedYaw - 8, snappedYaw)
	check(
		"both land on the key",
		near(yaw(pose(eased, "Head", 0.2).CFrame), 80) and near(yaw(pose(snapped, "Head", 0.2).CFrame), 80)
	)

	local function cycle(): any
		local sequence = blank()
		run(sequence, {
			{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 5, 0 } },
			{ type = "set_pose", joint = "Head", time = 0.25, rotation = { 0, 9, 0 } },
			{ type = "set_pose", joint = "Head", time = 0.75, rotation = { 0, 1, 0 } },
			{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 5, 0 } },
			{ type = "set_properties", loop = true },
		})
		return sequence
	end
	local looping, stopping = cycle(), cycle()
	run(looping, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 20 } })
	run(stopping, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 20, loop = false } })
	local moving = yaw(pose(looping, "Head", 0.05).CFrame) - 5
	local resting = yaw(pose(stopping, "Head", 0.05).CFrame) - 5
	check(
		"a looping clip is already moving at its first step",
		moving > resting * 2 and moving > 0.5,
		`{moving} {resting}`
	)
end)

case("a long turn is smoothed the short way round and stays a rotation", function()
	local sequence = blank()
	run(sequence, {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, -85, 0 }, position = { 0, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, 85, 0 }, position = { 0, 2, 0 } },
	})
	run(sequence, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 10 } })
	local middle = pose(sequence, "Head", 0.5).CFrame
	check("half way through it faces half way", near(yaw(middle), 0), yaw(middle))
	check("and is half way there", near(middle.Position.Y, 1), middle.Position.Y)
	local sound = true
	for step = 0, 10 do
		local parts = { pose(sequence, "Head", step / 10).CFrame:GetComponents() }
		-- Each of a rotation's three directions has a length of one.
		for column = 0, 2 do
			local length = math.sqrt(parts[4 + column] ^ 2 + parts[7 + column] ^ 2 + parts[10 + column] ^ 2)
			sound = sound and math.abs(length - 1) < 1e-4
		end
	end
	check("every pose written is a true rotation", sound)
end)

case("smoothing is held to its limits", function()
	local sequence = sparse()
	local bad: { [string]: any } = {
		["a rate that is too low"] = { type = "smooth_motion", time_from = 0, time_to = 1, rate = 5 },
		["a rate that is not whole"] = { type = "smooth_motion", time_from = 0, time_to = 1, rate = 30.5 },
		["a joint the rig lacks"] = { type = "smooth_motion", time_from = 0, time_to = 1, joints = { "Tail" } },
		["an empty list of joints"] = { type = "smooth_motion", time_from = 0, time_to = 1, joints = {} },
		["a range of no length"] = { type = "smooth_motion", time_from = 0.5, time_to = 0.5 },
		["a loop that is not a boolean"] = { type = "smooth_motion", time_from = 0, time_to = 1, loop = "yes" },
		["a snap time out of range"] = { type = "smooth_motion", time_from = 0, time_to = 1, snap_at = { -1 } },
	}
	for name, operation in bad do
		local problem = refusal(sequence, { operation }) :: any
		check(name, type(problem) == "table" and problem.code == "INVALID_ARGUMENT", problem)
	end
	local limit = Operations.MAX_KEYFRAMES
	Operations.MAX_KEYFRAMES = 8
	local scratch = sequence:Clone()
	local over = refusal(scratch, { { type = "smooth_motion", time_from = 0, time_to = 1, rate = 30 } }) :: any
	Operations.MAX_KEYFRAMES = limit
	check("more keyframes than a clip may hold", type(over) == "table" and over.code == "LIMIT_EXCEEDED", over)
	check("the clip itself was not touched", times(sequence) == "0.000 0.330 0.500 1.000", times(sequence))
end)

print(`{count - failures}/{count} operation checks passed`)
if failures > 0 then
	process.exit(1)
end
