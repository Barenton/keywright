--!strict
-- Offline tests for the clip fingerprint. Run with: lune run plugin/test/inspection/digest.test.luau
--
-- Real here: Lune's instances and this project's own SHA-256. Not tested here: that
-- Studio reads every property the same way Lune does.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Digest = require("../../src/Inspection/Digest")

local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Enum = roblox.Enum

local failures = 0
local count = 0

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

-- A clip with two keyframes, a small pose hierarchy in each and one marker.
local function build(): any
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "Wave"
	sequence.Loop = false
	sequence.Priority = Enum.AnimationPriority.Action
	for _, time in { 0, 1 } do
		local keyframe = Instance.new("Keyframe")
		keyframe.Time = time
		keyframe.Parent = sequence
		local root = Instance.new("Pose")
		root.Name = "HumanoidRootPart"
		root.Weight = 0
		root.CFrame = CFrame.new()
		root.EasingStyle = Enum.PoseEasingStyle.Linear
		root.EasingDirection = Enum.PoseEasingDirection.In
		root.Parent = keyframe
		local arm = Instance.new("Pose")
		arm.Name = "RightUpperArm"
		arm.Weight = 1
		arm.CFrame = CFrame.Angles(0, 0, math.rad(90 * time))
		arm.EasingStyle = Enum.PoseEasingStyle.Linear
		arm.EasingDirection = Enum.PoseEasingDirection.In
		arm.Parent = root
	end
	local marker = Instance.new("KeyframeMarker")
	marker.Name = "Clap"
	marker.Value = "loud"
	marker.Parent = sequence:GetChildren()[2]
	return sequence
end

local function arm(sequence: any, index: number): any
	return sequence:GetChildren()[index]:FindFirstChild("RightUpperArm", true)
end

-- The one fingerprint that can be compared with Studio exactly: a clip with no keyframes.
-- Studio gave this value for a blank working copy on 2026-11-24, so the hashing, the
-- line format and the way settings are written out agree between Lune and Studio.
-- Clips with poses cannot be compared this way: the two runtimes differ in the last
-- digits of a rotation (Lune gives 0.866027832 for the cosine of 30 degrees).
local blank = Instance.new("KeyframeSequence")
blank.Loop = false
blank.Priority = Enum.AnimationPriority.Action
check(
	"a blank clip has the fingerprint Studio computed for one",
	Digest.of(blank) == "26b8727a147a5903c0e432ee98d5ee4798b7d2dd5168d6858736831939f108a6",
	Digest.of(blank)
)

local base = Digest.of(build())
check("a fingerprint is 64 hexadecimal characters", #base == 64 and string.match(base, "^%x+$") ~= nil, base)
check("the same clip built twice has the same fingerprint", Digest.of(build()) == base)
check("a copy has the same fingerprint", Digest.of(build():Clone()) == base)

local renamed = build()
renamed.Name = "Something else"
check("the clip's name does not count", Digest.of(renamed) == base)

-- The order instances are stored in does not count.
local reordered = build()
local first = reordered:GetChildren()[1]
first.Parent = nil
first.Parent = reordered
check("the order of keyframes in storage does not count", Digest.of(reordered) == base)

local changes: { [string]: (sequence: any) -> () } = {
	["a pose is turned a little"] = function(sequence)
		arm(sequence, 2).CFrame = CFrame.Angles(0, 0, math.rad(90.01))
	end,
	["a pose is moved a little"] = function(sequence)
		arm(sequence, 2).CFrame = arm(sequence, 2).CFrame + roblox.Vector3.new(0, 0.001, 0)
	end,
	["a keyframe is retimed"] = function(sequence)
		sequence:GetChildren()[2].Time = 1.001
	end,
	["a pose's weight changes"] = function(sequence)
		arm(sequence, 1).Weight = 0
	end,
	["a pose's easing style changes"] = function(sequence)
		arm(sequence, 1).EasingStyle = Enum.PoseEasingStyle.Constant
	end,
	["a pose's easing direction changes"] = function(sequence)
		arm(sequence, 1).EasingDirection = Enum.PoseEasingDirection.Out
	end,
	["a pose is removed"] = function(sequence)
		arm(sequence, 2).Parent = nil
	end,
	["a pose is added"] = function(sequence)
		local head = Instance.new("Pose")
		head.Name = "Head"
		head.Parent = sequence:GetChildren()[1]:FindFirstChild("HumanoidRootPart")
	end,
	["a pose is renamed"] = function(sequence)
		arm(sequence, 1).Name = "LeftUpperArm"
	end,
	["a pose is moved elsewhere in the hierarchy"] = function(sequence)
		arm(sequence, 1).Parent = sequence:GetChildren()[1]
	end,
	["a keyframe is added"] = function(sequence)
		local keyframe = Instance.new("Keyframe")
		keyframe.Time = 2
		keyframe.Parent = sequence
	end,
	["a keyframe is removed"] = function(sequence)
		sequence:GetChildren()[2].Parent = nil
	end,
	["a marker's value changes"] = function(sequence)
		sequence:FindFirstChild("Clap", true).Value = "quiet"
	end,
	["a marker is removed"] = function(sequence)
		sequence:FindFirstChild("Clap", true).Parent = nil
	end,
	["looping is turned on"] = function(sequence)
		sequence.Loop = true
	end,
	["the priority changes"] = function(sequence)
		sequence.Priority = Enum.AnimationPriority.Idle
	end,
}
local seen: { [string]: string } = { [base] = "the unchanged clip" }
for label, change in changes do
	local sequence = build()
	change(sequence)
	local digest = Digest.of(sequence)
	check(`the fingerprint changes when {label}`, digest ~= base)
	check(`and differs from every other change ({label})`, seen[digest] == nil, seen[digest])
	seen[digest] = label
end

-- Undoing a change brings the fingerprint back.
local restored = build()
arm(restored, 2).CFrame = CFrame.Angles(0, 0, math.rad(45))
arm(restored, 2).CFrame = CFrame.Angles(0, 0, math.rad(90))
check("a change that is undone leaves the fingerprint as it was", Digest.of(restored) == base)

local empty = Instance.new("KeyframeSequence")
check("an empty clip has a fingerprint too", #Digest.of(empty) == 64 and Digest.of(empty) ~= base)

-- The source fingerprint also counts keyframe names, which scripts see.
do
	local named = build()
	local before, sourceBefore = Digest.of(named), Digest.ofSource(named)
	for _, child in named:GetChildren() do
		if child:IsA("Keyframe") then
			child.Name = "Contact"
			break
		end
	end
	check("renaming a keyframe leaves the plain fingerprint", Digest.of(named) == before)
	check("but changes the source fingerprint", Digest.ofSource(named) ~= sourceBefore)
	check("which is the same for the same clip", Digest.ofSource(named:Clone()) == Digest.ofSource(named))
	check(
		"and never equals a fingerprint from before names counted",
		Digest.ofSource(named) ~= Digest.of(named) and string.sub(Digest.ofSource(named), 1, 2) == "2:"
	)
end

print(`{count - failures}/{count} digest checks passed`)
if failures > 0 then
	process.exit(1)
end
