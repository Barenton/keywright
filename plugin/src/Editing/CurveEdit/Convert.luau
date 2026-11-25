--!strict
-- A keyframe clip as a curve clip: keys through every pose, with smooth tangents.

local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")
local Store = require("./Store")
local Write = require("./Write")

local currentBackend = Store.currentBackend
local markerCurve = Store.markerCurve
local nearestAngles = Write.nearestAngles
local smoothChannel = Write.smoothChannel

type Key = Store.Key
type Marker = Store.Marker

local Convert = {}

-- A curve clip that passes through every pose of a keyframe clip, with smooth tangents.
-- Between keys the motion follows the curves, not Roblox's per-stretch easing, so it can
-- differ there; at the keys it is the same.
function Convert.fromKeyframes(
	sequence: Instance,
	keyframes: { Keyframe },
	findPose: (Keyframe, string) -> Pose?
): Instance
	local clip = Roblox.Instance.new("CurveAnimation")
	clip.Name = sequence.Name;
	(clip :: any).Loop = (sequence :: any).Loop;
	(clip :: any).Priority = (sequence :: any).Priority
	for _, joint in Rig.R15_ORDER do
		local samples: { { time: number, values: { number } } } = {}
		for _, keyframe in keyframes do
			local pose = findPose(keyframe, joint)
			if pose and pose.Weight > 0 then
				local position = pose.CFrame.Position
				local x, y, z = pose.CFrame:ToEulerAnglesXYZ()
				local values = { position.X, position.Y, position.Z, x, y, z }
				local before = samples[#samples]
				if before then
					-- The angles nearest the key before, so the curve takes the short way.
					local chosen = nearestAngles(x, y, z, { before.values[4], before.values[5], before.values[6] })
					values[4], values[5], values[6] = chosen[1], chosen[2], chosen[3]
				end
				table.insert(samples, { time = keyframe.Time, values = values })
			end
		end
		if #samples == 0 then
			continue
		end
		for index, channel in { "position.x", "position.y", "position.z", "rotation.x", "rotation.y", "rotation.z" } do
			local moves = false
			for _, sample in samples do
				moves = moves or math.abs(sample.values[index]) > 1e-6
			end
			if moves then
				local keys: { Key } = {}
				for _, sample in samples do
					table.insert(keys, {
						time = sample.time,
						value = sample.values[index],
						interpolation = "Cubic",
						left = 0,
						right = 0,
					})
				end
				local curve = Store.channel(clip, joint, channel, true) :: Instance
				Store.setKeys(curve, keys)
				smoothChannel(curve, 0, math.huge, {}, (sequence :: any).Loop == true)
			end
		end
	end
	local markers: { [string]: { Marker } } = {}
	for _, keyframe in keyframes do
		for _, child: any in keyframe:GetChildren() do
			if child:IsA("KeyframeMarker") then
				markers[child.Name] = markers[child.Name] or {}
				table.insert(markers[child.Name], { time = keyframe.Time, value = child.Value })
			end
		end
	end
	for name, list in markers do
		currentBackend().setMarkers(markerCurve(clip, name, true) :: Instance, list)
	end
	return clip
end

-- ---------------------------------------------------------------------------------------
-- Reading

return Convert
