--!strict
-- A fingerprint of what a clip contains, for telling whether two clips are the same.
--
-- Two clips have the same fingerprint when they would play the same: the same keyframe
-- times, the same poses with the same transforms, weights and easing in the same
-- hierarchy, the same markers, and the same loop and priority settings. The clip's name
-- and the order in which its instances happen to be stored do not count.
--
-- This is how a round trip through saving and opening is shown to change nothing.

local Codec = require("../Core/Codec")
local Curves = require("../Editing/Curves")
local Sha256 = require("../Core/Sha256")

local Digest = {}

local function number(value: number): string
	return string.format("%.9g", value)
end

-- A property as text; "?" where it cannot be read.
local function text(instance: any, property: string): string
	local ok, value = pcall(function()
		return instance[property]
	end)
	if not ok then
		return "?"
	end
	return if type(value) == "number" then number(value) else tostring(value)
end

local function transform(pose: any): string
	local ok, components = pcall(function()
		return { pose.CFrame:GetComponents() }
	end)
	if not ok then
		return "?"
	end
	for index, value in components do
		components[index] = number(value)
	end
	return table.concat(components, ",")
end

-- One line for everything in the clip, in a fixed order. Content this project does not
-- understand (a NumberPose, a Folder, anything that is not a pose or a marker) gets a
-- line too, with its class, name and value, so that losing or changing it shows.
function Digest.lines(sequence: Instance): { string }
	if sequence:IsA("CurveAnimation") then
		return Curves.digestLines(sequence)
	end
	local lines = { `loop|{text(sequence, "Loop")}`, `priority|{text(sequence, "Priority")}` }
	local function walk(instance: any, time: string, path: string)
		for _, child in instance:GetChildren() do
			local here = `{path}/{child.Name}`
			if child:IsA("Pose") then
				table.insert(
					lines,
					`{time}|pose|{here}|{transform(child)}|{text(child, "Weight")}|{text(child, "EasingStyle")}|{text(
						child,
						"EasingDirection"
					)}`
				)
			elseif child:IsA("KeyframeMarker") then
				table.insert(lines, `{time}|marker|{here}|{text(child, "Value")}`)
			else
				table.insert(lines, `{time}|other|{here}|{child.ClassName}|{text(child, "Value")}`)
			end
			walk(child, time, here)
		end
	end
	for _, child: any in sequence:GetChildren() do
		if child:IsA("Keyframe") then
			local time = number(child.Time)
			table.insert(lines, `{time}|keyframe`)
			walk(child, time, "")
		else
			-- Not a keyframe: kept by every edit, and so part of what the clip is.
			table.insert(lines, `clip|other|/{child.Name}|{child.ClassName}|{text(child, "Value")}`)
			walk(child, "clip", `/{child.Name}`)
		end
	end
	table.sort(lines)
	return lines
end

-- The fingerprint, as 64 hexadecimal characters.
function Digest.of(sequence: Instance): string
	return Codec.toHex(Sha256.digest(buffer.fromstring(table.concat(Digest.lines(sequence), "\n"))))
end

-- A stricter fingerprint, for telling whether a clip has changed since a working copy was
-- opened from it: everything Digest.of covers, and also each keyframe's name, which game
-- scripts see through AnimationTrack.KeyframeReached and which a replacement would write
-- over. Kept apart from Digest.of, which read_animation reports as content_hash and whose
-- values recorded from Studio are compared. Marked "2:", so that a fingerprint written
-- before keyframe names counted never matches, and the clip is taken as changed.
-- A line for each attribute on the clip and everything in it: data a game's scripts can
-- read, which replacing the clip would overwrite.
local function attributeLines(sequence: Instance): { string }
	local lines = {}
	local function add(instance: Instance, path: string)
		for name, value in instance:GetAttributes() do
			table.insert(lines, `attribute|{path}|{name}|{typeof(value)}|{tostring(value)}`)
		end
	end
	local function walk(instance: Instance, path: string)
		for _, child in instance:GetChildren() do
			local here = `{path}/{child.Name}`
			add(child, here)
			walk(child, here)
		end
	end
	add(sequence, "")
	walk(sequence, "")
	return lines
end

-- The newest way the source fingerprint is worked out. 2 counted keyframe names; 3 counts
-- attributes too.
Digest.SOURCE_VERSION = 3

-- The fingerprint of a clip a working copy was opened from: what it plays, and also what
-- scripts can see in it, keyframe names and attributes. `version` works out an older kind,
-- to compare with a fingerprint written down before.
function Digest.ofSource(sequence: Instance, version: number?): string
	local kind = version or Digest.SOURCE_VERSION
	local lines = Digest.lines(sequence)
	for _, child: any in sequence:GetChildren() do
		if child:IsA("Keyframe") then
			table.insert(lines, `{number(child.Time)}|name|{child.Name}`)
		end
	end
	if kind >= 3 then
		for _, line in attributeLines(sequence) do
			table.insert(lines, line)
		end
	end
	table.sort(lines)
	return `{kind}:` .. Codec.toHex(Sha256.digest(buffer.fromstring(table.concat(lines, "\n"))))
end

-- Whether a clip is still what a fingerprint written down earlier says, worked out the way
-- that fingerprint was, so that one from an older plugin is not taken for a change.
function Digest.sameSource(sequence: Instance, fingerprint: string): boolean
	local kind = tonumber(string.match(fingerprint, "^(%d+):"))
	if kind == nil or kind < 2 or kind > Digest.SOURCE_VERSION then
		return false
	end
	return Digest.ofSource(sequence, kind) == fingerprint
end

return Digest
