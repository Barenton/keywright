--!strict
-- Shared by the curve clip suites in this folder: the stand-in for Studio's curve keys,
-- clips and rigs to test on, and measures of where the parts end up. Not a suite.
--
-- Real here: Lune's instances, laid out as the Animation Editor lays out a curve clip,
-- and everything Keywright works out about them. In place of Studio: the keys of each
-- curve, which Lune cannot hold, are kept in an attribute, so that a clone carries them.
-- Not tested here: that Studio plays what is written, which was measured separately.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde")

local Roblox = require("../../../src/Core/Roblox") :: any
Roblox.Instance = roblox.Instance
Roblox.CFrame = roblox.CFrame
Roblox.Vector3 = roblox.Vector3
Roblox.Enum = roblox.Enum

local BlockRig = require("../../rigs/blockrig")
local Curves = require("../../../src/Editing/Curves")
local CurveStore = require("../../../src/Editing/CurveEdit/Store")
local Pose = require("../../../src/Rigs/Pose")
local Digest = require("../../../src/Inspection/Digest")
local Operations = require("../../../src/Editing/Operations")
local Reading = require("../../../src/Inspection/Reading")
local Rig = require("../../../src/Rigs/Rig")
local Validate = require("../../../src/Inspection/Validate")

CurveStore.backend = {
	keys = function(curve)
		local text = curve:GetAttribute("Keys")
		return if text then serde.decode("json", text) else {}
	end,
	setKeys = function(curve, keys)
		curve:SetAttribute("Keys", serde.encode("json", keys))
	end,
	markers = function(curve)
		local text = curve:GetAttribute("Markers")
		return if text then serde.decode("json", text) else {}
	end,
	setMarkers = function(curve, markers)
		curve:SetAttribute("Markers", serde.encode("json", markers))
	end,
}

local Instance = roblox.Instance
local Enum = roblox.Enum

local JOINTS: { [string]: any } = {}
for _, name in Rig.R15_ORDER do
	JOINTS[name] = true
end

local function blank(): any
	local clip = Instance.new("CurveAnimation")
	clip.Name = "Clip"
	clip.Loop = false
	clip.Priority = Enum.AnimationPriority.Action
	return clip
end

local function run(clip: any, operations: { any }, source: any?): { [string]: number }
	Curves.check(operations, JOINTS)
	return Curves.run(clip, operations, { joints = JOINTS, source = source })
end

local function refusal(clip: any, operations: any): any
	local ok, problem = pcall(run, clip, operations)
	return if ok then nil else problem
end

local function near(a: number, b: number, within: number?): boolean
	return math.abs(a - b) <= (within or 1e-6)
end

local function keysOf(clip: any, joint: string, channel: string): { any }
	local curve = Curves.channel(clip, joint, channel, false)
	return if curve then Curves.keys(curve) else {}
end

local Kit = {}

-- A suite's own count of checks: `check` records one, `case` runs a group of them and
-- counts one that raises, `finish` prints the tally and fails the run if any failed.
function Kit.suite(
	label: string
): ((name: string, condition: any, detail: any?) -> (), (name: string, run: () -> ()) -> (), () -> ())
	local failures, count, current = 0, 0, ""
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
	local function finish()
		print(`{count - failures}/{count} {label} checks passed`)
		if failures > 0 then
			process.exit(1)
		end
	end
	return check, case, finish
end

-- A keyframe clip: the head turning through three poses, a marker on the middle one.
local function keyframed(): any
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "Turn"
	sequence.Loop = false
	sequence.Priority = Enum.AnimationPriority.Action
	Operations.run(sequence, {
		{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_pose", joint = "Head", time = 0.5, rotation = { 10, 170, 0 } },
		{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, -170, 0 }, position = { 0, 0.5, 0 } },
		{ type = "set_marker", time = 0.5, name = "Look", value = "left" },
	}, { joints = JOINTS })
	return sequence
end

-- ---------------------------------------------------------------------------------------
-- Pinning and contact, on a rig with real geometry

local REAL = Rig.scan(BlockRig.build()).joints

local function realRun(clip: any, operations: { any }): { [string]: number }
	Curves.check(operations, REAL)
	return Curves.run(clip, operations, { joints = REAL })
end

-- Where every part is at a time, as the clip's curves give it.
local function placedAt(clip: any, time: number): { [string]: any }
	local transforms = {}
	for _, joint in Rig.R15_ORDER do
		local values = {}
		for index, channel in Curves.CHANNELS do
			local curve = Curves.channel(clip, joint, channel, false)
			values[index] = if curve then Curves.evaluate(Curves.keys(curve), time) else 0
		end
		transforms[joint] = roblox.CFrame.new(values[1], values[2], values[3])
			* roblox.CFrame.fromEulerAnglesXYZ(values[4], values[5], values[6])
	end
	return Pose.place({ joints = REAL } :: any, transforms, roblox.CFrame.new())
end

local function turnBetween(a: any, b: any): number
	local squares = (a.RightVector - b.RightVector).Magnitude ^ 2
		+ (a.UpVector - b.UpVector).Magnitude ^ 2
		+ (a.LookVector - b.LookVector).Magnitude ^ 2
	return math.deg(2 * math.asin(math.min(1, math.sqrt(squares / 8))))
end

-- Which way a part faces across the floor, in degrees.
local function yaw(part: any): number
	return math.deg(math.atan2(-part.LookVector.X, -part.LookVector.Z))
end

-- Hips that drop and come back up over a second, with nothing else keyed.
local function squat(depth: number, sideways: number?): any
	local clip = blank()
	realRun(clip, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 0.5, position = { sideways or 0, -depth, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	return clip
end

-- Hips that drop while the chest bends forward and turns, over a second.
local function hunch(): any
	local clip = squat(0.4)
	realRun(clip, {
		{ type = "set_key", joint = "UpperTorso", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 0.5, rotation = { -35, 20, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 1, rotation = { 0, 0, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	return clip
end

-- A clip where each side moves its own way, and the middle turns and moves sideways.
local function lopsided(): any
	local clip = blank()
	local function keys(joint: string, a: { number }, b: { number }, c: { number })
		return {
			{ type = "set_key", joint = joint, time = 0, rotation = a },
			{ type = "set_key", joint = joint, time = 0.5, rotation = b },
			{ type = "set_key", joint = joint, time = 1, rotation = c },
		}
	end
	local operations = {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 0.5, position = { 0.3, -0.2, 0.1 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0, 0 } },
	}
	for _, list in
		{
			keys("LowerTorso", { 0, 0, 0 }, { 10, 25, -15 }, { 0, 0, 0 }),
			keys("UpperTorso", { 0, 0, 0 }, { -20, 30, 10 }, { 0, 0, 0 }),
			keys("LeftUpperArm", { 0, 0, 0 }, { 70, 20, -40 }, { 10, 0, 0 }),
			keys("LeftLowerArm", { 0, 0, 0 }, { 60, 0, 0 }, { 0, 0, 0 }),
			keys("RightUpperLeg", { 0, 0, 0 }, { -30, 10, 15 }, { 0, 0, 0 }),
		}
	do
		for _, operation in list do
			table.insert(operations, operation)
		end
	end
	table.insert(operations, { type = "auto_tangents", time_from = 0, time_to = 1 })
	realRun(clip, operations)
	return clip
end

local function mirrorName(name: string): string
	if string.sub(name, 1, 4) == "Left" then
		return "Right" .. string.sub(name, 5)
	elseif string.sub(name, 1, 5) == "Right" then
		return "Left" .. string.sub(name, 6)
	end
	return name
end

-- A frame seen in a mirror across the rig's middle, worked out by reflecting its axes.
local function inMirror(cframe: any): any
	local flip = roblox.Vector3.new(-1, 1, 1)
	local position = cframe.Position * flip
	-- A reflected frame is left-handed; reflecting the whole frame and then turning its X
	-- axis round gives the right-handed frame a mirrored part has.
	local right = -(cframe.RightVector * flip)
	local up = cframe.UpVector * flip
	local back = -(cframe.LookVector * flip)
	return roblox.CFrame.fromMatrix(position, right, up, back)
end

-- Every channel of a clip at a time, as one list.
local function sampleAll(clip: any, time: number): { number }
	local values = {}
	for _, joint in Rig.R15_ORDER do
		for _, channel in Curves.CHANNELS do
			local curve = Curves.channel(clip, joint, channel, false)
			table.insert(values, if curve then Curves.evaluate(Curves.keys(curve), time) else 0)
		end
	end
	return values
end
local function difference(a: { number }, b: { number }): number
	local worst = 0
	for index, value in a do
		worst = math.max(worst, math.abs(value - b[index]))
	end
	return worst
end

-- The angle in degrees between where a part faces and the way to a point.
local function offAim(part: any, target: any): number
	local toward = (target - part.Position).Unit
	return math.deg(math.acos(math.clamp(part.LookVector:Dot(toward), -1, 1)))
end

-- The chest turns 60 degrees in 0.3 seconds and stops; the arm is not animated.
local function turnAndStop(): any
	local clip = blank()
	realRun(clip, {
		{ type = "set_key", joint = "UpperTorso", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 0.3, rotation = { 0, 60, 0 } },
		{ type = "set_key", joint = "UpperTorso", time = 1.2, rotation = { 0, 60, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1.2 },
	})
	return clip
end

-- The lowest point of the parts the floor is measured by, at a time.
local MEASURED = {}
for _, name in Rig.R15_ORDER do
	if name ~= "LeftLowerLeg" and name ~= "RightLowerLeg" then
		table.insert(MEASURED, name)
	end
end
local function lowestAt(clip: any, time: number, parts: { string }?): number
	local placed = placedAt(clip, time)
	local lowest = math.huge
	for _, name in parts or MEASURED do
		-- The lowest point of a box whose corners are rounded by 0.4 of its smallest side:
		-- the lowest of the rounding's centres, less the rounding.
		local cframe, size = placed[name], REAL[name].part1.Size
		local round = 0.4 * math.min(size.X, size.Y, size.Z)
		local inner = size / 2 - roblox.Vector3.new(round, round, round)
		local deepest = math.huge
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local corner =
						cframe:PointToWorldSpace(roblox.Vector3.new(sx * inner.X, sy * inner.Y, sz * inner.Z))
					deepest = math.min(deepest, corner.Y - round)
				end
			end
		end
		lowest = math.min(lowest, deepest)
	end
	return lowest
end
local FLOOR = lowestAt(blank(), 0, Rig.R15_ORDER)

Kit.blank = blank
Kit.run = run
Kit.refusal = refusal
Kit.near = near
Kit.keysOf = keysOf
Kit.keyframed = keyframed
Kit.realRun = realRun
Kit.placedAt = placedAt
Kit.turnBetween = turnBetween
Kit.yaw = yaw
Kit.squat = squat
Kit.hunch = hunch
Kit.lopsided = lopsided
Kit.mirrorName = mirrorName
Kit.inMirror = inMirror
Kit.sampleAll = sampleAll
Kit.difference = difference
Kit.offAim = offAim
Kit.turnAndStop = turnAndStop
Kit.lowestAt = lowestAt
Kit.process = process
Kit.roblox = roblox
Kit.serde = serde
Kit.Roblox = Roblox
Kit.BlockRig = BlockRig
Kit.Curves = Curves
Kit.CurveStore = CurveStore
Kit.Pose = Pose
Kit.Digest = Digest
Kit.Operations = Operations
Kit.Reading = Reading
Kit.Rig = Rig
Kit.Validate = Validate
Kit.Instance = Instance
Kit.Enum = Enum
Kit.JOINTS = JOINTS
Kit.REAL = REAL
Kit.MEASURED = MEASURED
Kit.FLOOR = FLOOR

return Kit
