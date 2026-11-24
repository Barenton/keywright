--!strict
-- A fingerprint of what a clip contains, for telling whether two clips are the same.
--
-- Two clips have the same fingerprint when they would play the same: the same keyframe
-- times, the same poses with the same transforms, weights and easing in the same
-- hierarchy, the same markers, and the same loop and priority settings. The clip's name
-- and the order in which its instances happen to be stored do not count.
--
-- This is how a round trip through saving and opening is shown to change nothing.

local Codec = require("./Codec")
local Sha256 = require("./Sha256")

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

-- One line for everything in the clip that affects how it plays, in a fixed order.
function Digest.lines(sequence: Instance): { string }
	local lines = { `loop|{text(sequence, "Loop")}`, `priority|{text(sequence, "Priority")}` }
	for _, keyframe: any in sequence:GetChildren() do
		if not keyframe:IsA("Keyframe") then
			continue
		end
		local time = number(keyframe.Time)
		table.insert(lines, `{time}|keyframe`)
		local function walk(instance: any, path: string)
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
					walk(child, here)
				elseif child:IsA("KeyframeMarker") then
					table.insert(lines, `{time}|marker|{here}|{text(child, "Value")}`)
				end
			end
		end
		walk(keyframe, "")
	end
	table.sort(lines)
	return lines
end

-- The fingerprint, as 64 hexadecimal characters.
function Digest.of(sequence: Instance): string
	return Codec.toHex(Sha256.digest(buffer.fromstring(table.concat(Digest.lines(sequence), "\n"))))
end

return Digest
