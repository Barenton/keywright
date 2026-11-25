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

return Digest
