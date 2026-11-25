--!strict
-- Shared by the operation suites in this folder: what they are run against, and the
-- helpers they use. Not a suite.
--
--
-- Real here: Lune's instances and CFrame arithmetic, and the operations themselves.
-- Not tested here: undo, revisions and working copies (Edit and Clips, which need
-- Studio), and how Studio plays what these operations write.

-- The suite that is running, for helpers here that record checks as they go.
local active: ((name: string, condition: any, detail: any?) -> ())? = nil
local function check(name: string, condition: any, detail: any?)
	(active :: any)(name, condition, detail)
end

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Roblox = require("../../../src/Core/Roblox") :: any
Roblox.Instance = roblox.Instance
Roblox.CFrame = roblox.CFrame
Roblox.Enum = roblox.Enum

local Digest = require("../../../src/Inspection/Digest")
local Operations = require("../../../src/Editing/Operations")
local Sequence = require("../../../src/Editing/KeyframeEdit/Sequence")
local Rig = require("../../../src/Rigs/Rig")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Enum = roblox.Enum

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

local Kit = {}

-- A suite's own count of checks: `check` records one, `case` runs a group of them and
-- counts one that raises, `finish` prints the tally and fails the run if any failed.
function Kit.suite(
	label: string
): ((name: string, condition: any, detail: any?) -> (), (name: string, run: () -> ()) -> (), () -> ())
	local failures, count, current = 0, 0, ""
	local function suiteCheck(name: string, condition: any, detail: any?)
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
	local function finish()
		print(`{count - failures}/{count} {label} checks passed`)
		if failures > 0 then
			process.exit(1)
		end
	end
	active = suiteCheck
	return suiteCheck, case, finish
end

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

Kit.blank = blank
Kit.run = run
Kit.refusal = refusal
Kit.refused = refused
Kit.times = times
Kit.pose = pose
Kit.yaw = yaw
Kit.near = near
Kit.rich = rich
Kit.snapshot = snapshot
Kit.differing = differing
Kit.sparse = sparse
Kit.process = process
Kit.roblox = roblox
Kit.Roblox = Roblox
Kit.Digest = Digest
Kit.Operations = Operations
Kit.Sequence = Sequence
Kit.Rig = Rig
Kit.Instance = Instance
Kit.CFrame = CFrame
Kit.Enum = Enum
Kit.JOINTS = JOINTS

return Kit
