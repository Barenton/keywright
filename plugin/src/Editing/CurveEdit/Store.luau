--!strict
-- Curve clips as stored: the limits and names used throughout, and how a clip's
-- curves, keys and markers are found, read, written and played. Keys are read and
-- written through `Store.backend`, Studio's own methods unless a test replaces them.

local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")

local Store = {}

Store.TIME_TOLERANCE = 0.001
-- How many times a second Studio samples a curve clip as it plays.
Store.FRAME_RATE = 30
Store.MAX_TIME = 300
Store.MAX_POSITION = 1000
Store.MAX_KEYS = 2000
Store.MAX_OPERATIONS = 256
Store.MAX_SNAPS = 16
Store.MAX_JOINTS = 32
Store.MAX_NAME = 100
Store.MAX_MARKER_VALUE = 200
-- The longest a pin may take to blend in or out, in seconds.
Store.MAX_BLEND = 2
Store.HOLDS = { "full", "position" }
Store.PIVOTS = { "ankle", "toe", "heel" }
Store.FLOOR_MODES = { "lift", "touch" }
Store.MIRROR_MODES = { "flip", "left_to_right", "right_to_left" }
Store.MIN_SCALE = 0.01
-- How far a reduced curve may stray from the original at any frame, by default.
Store.REDUCE_DEGREES = 0.1
Store.REDUCE_STUDS = 0.002
-- The longest range reduced in one go: the work grows with the square of its frames.
Store.MAX_REDUCE = 60
-- Noise: the slowest and fastest it may sway, in waves a second, and the largest swing.
Store.MIN_FREQUENCY = 0.1
Store.MAX_FREQUENCY = 10
Store.MAX_NOISE_DEGREES = 90
Store.MAX_NOISE_STUDS = 5
-- Overlap: how long a joint may trail, in seconds, and how springy it may be.
Store.MIN_LAG = 0.02
Store.MAX_LAG = 0.5
Store.MAX_BOUNCE = 0.9
Store.MAX_SCALE = 100
Store.MAX_LISTED = 500
Store.DEFAULT_KEYS = 400
Store.MAX_PAGE = 20000
Store.PRIORITIES = { "Idle", "Movement", "Action", "Action2", "Action3", "Action4", "Core" }
Store.INTERPOLATIONS = { "Cubic", "Linear", "Constant" }
Store.CHANNELS = { "position.x", "position.y", "position.z", "rotation.x", "rotation.y", "rotation.z" }

export type Key = {
	time: number,
	value: number,
	interpolation: string,
	left: number?,
	right: number?,
}

export type Marker = { time: number, value: string }

export type Backend = {
	keys: (curve: Instance) -> { Key },
	setKeys: (curve: Instance, keys: { Key }) -> (),
	markers: (curve: Instance) -> { Marker },
	setMarkers: (curve: Instance, markers: { Marker }) -> (),
}

local function studio(): Backend
	return {
		keys = function(curve: Instance): { Key }
			local list = {}
			for _, key: any in (curve :: any):GetKeys() do
				local right = nil
				if key.Interpolation == Enum.KeyInterpolationMode.Cubic then
					right = key.RightTangent
				end
				table.insert(list, {
					time = key.Time,
					value = key.Value,
					interpolation = key.Interpolation.Name,
					left = key.LeftTangent,
					right = right,
				})
			end
			return list
		end,
		setKeys = function(curve: Instance, keys: { Key })
			local float = curve :: any
			local existing = #float:GetKeys()
			if existing > 0 then
				float:RemoveKeyAtIndex(1, existing)
			end
			for _, key in keys do
				local made: any =
					FloatCurveKey.new(key.time, key.value, (Enum.KeyInterpolationMode :: any)[key.interpolation])
				if key.left ~= nil then
					made.LeftTangent = key.left
				end
				if key.right ~= nil and key.interpolation == "Cubic" then
					made.RightTangent = key.right
				end
				float:InsertKey(made)
			end
		end,
		markers = function(curve: Instance): { Marker }
			local list = {}
			for _, marker: any in (curve :: any):GetMarkers() do
				table.insert(list, { time = marker.Time, value = marker.Value })
			end
			return list
		end,
		setMarkers = function(curve: Instance, markers: { Marker })
			local markerCurve = curve :: any
			local existing = #markerCurve:GetMarkers()
			if existing > 0 then
				markerCurve:RemoveMarkerAtIndex(1, existing)
			end
			for _, marker in markers do
				markerCurve:InsertMarkerAtTime(marker.time, marker.value)
			end
		end,
	}
end

Store.backend = nil :: Backend?

local function currentBackend(): Backend
	local current = Store.backend
	if not current then
		current = studio()
		Store.backend = current
	end
	return current :: Backend
end

-- ---------------------------------------------------------------------------------------
-- Layout

local function sortKeys(keys: { Key })
	table.sort(keys, function(a, b)
		return a.time < b.time
	end)
end

function Store.isCurves(clip: Instance): boolean
	return clip:IsA("CurveAnimation")
end

-- The Folder of a joint, made along with any of its ancestors if `create` is true.
function Store.folder(clip: Instance, joint: string, create: boolean): Instance?
	local parent: Instance = clip
	for _, name in Rig.chain(joint) do
		local child = parent:FindFirstChild(name)
		if not child or not child:IsA("Folder") then
			if not create then
				return nil
			end
			local made = Roblox.Instance.new("Folder")
			made.Name = name
			made.Parent = parent
			child = made
		end
		parent = child :: Instance
	end
	return parent
end

-- The FloatCurve of one channel of a joint ("rotation.x" and so on), made if `create`.
function Store.channel(clip: Instance, joint: string, channel: string, create: boolean): Instance?
	local folder = Store.folder(clip, joint, create)
	if not folder then
		return nil
	end
	local kind, axis = string.match(channel, "^(%a+)%.(%a)$")
	local groupName = if kind == "position" then "Position" else "Rotation"
	local groupClass = if kind == "position" then "Vector3Curve" else "EulerRotationCurve"
	local group = folder:FindFirstChild(groupName)
	if not group or not group:IsA(groupClass) then
		if not create then
			return nil
		end
		local made = Roblox.Instance.new(groupClass)
		made.Name = groupName
		if groupClass == "EulerRotationCurve" then
			(made :: any).RotationOrder = Roblox.Enum.RotationOrder.XYZ
		end
		made.Parent = folder
		group = made
	end
	local name = string.upper(axis :: string)
	local curve = (group :: Instance):FindFirstChild(name)
	if not curve or not curve:IsA("FloatCurve") then
		if not create then
			return nil
		end
		local made = Roblox.Instance.new("FloatCurve")
		made.Name = name
		made.Parent = group
		curve = made
	end
	return curve
end

export type Track = { joint: string, channel: string, curve: Instance, path: string }

-- Every channel curve in the clip, wherever it is, with the joint it belongs to.
function Store.tracks(clip: Instance): { Track }
	local tracks: { Track } = {}
	local function walk(instance: Instance, path: string)
		for _, child in instance:GetChildren() do
			if child:IsA("Folder") then
				local here = if path == "" then child.Name else `{path}/{child.Name}`
				for _, group in child:GetChildren() do
					local kind = if group:IsA("Vector3Curve")
						then "position"
						elseif group:IsA("EulerRotationCurve") then "rotation"
						else nil
					if kind then
						for _, curve in group:GetChildren() do
							if curve:IsA("FloatCurve") and #curve.Name == 1 then
								table.insert(tracks, {
									joint = child.Name,
									channel = `{kind}.{string.lower(curve.Name)}`,
									curve = curve :: Instance,
									path = `{here}/{group.Name}/{curve.Name}`,
								})
							end
						end
					end
				end
				walk(child, here)
			end
		end
	end
	walk(clip, "")
	table.sort(tracks, function(a, b)
		return a.path < b.path
	end)
	return tracks
end

function Store.markerCurves(clip: Instance): { Instance }
	local list = {}
	for _, child in clip:GetChildren() do
		if child:IsA("MarkerCurve") then
			table.insert(list, child :: Instance)
		end
	end
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	return list
end

function Store.keys(curve: Instance): { Key }
	local keys = currentBackend().keys(curve)
	sortKeys(keys)
	return keys
end

function Store.setKeys(curve: Instance, keys: { Key })
	sortKeys(keys)
	currentBackend().setKeys(curve, keys)
end

-- The value of a channel at a time, as Studio plays it: the first key's value before it,
-- the last key's after it, and between two keys by the first one's interpolation.
function Store.evaluate(keys: { Key }, time: number): number
	local count = #keys
	if count == 0 then
		return 0
	elseif time <= keys[1].time then
		return keys[1].value
	elseif time >= keys[count].time then
		return keys[count].value
	end
	for index = 1, count - 1 do
		local a, b = keys[index], keys[index + 1]
		if time <= b.time then
			local length = b.time - a.time
			if length <= 0 or a.interpolation == "Constant" then
				return a.value
			end
			local u = (time - a.time) / length
			if a.interpolation == "Linear" then
				return a.value + (b.value - a.value) * u
			end
			local m0, m1 = a.right or 0, b.left or 0
			local u2, u3 = u * u, u * u * u
			return (2 * u3 - 3 * u2 + 1) * a.value
				+ (u3 - 2 * u2 + u) * length * m0
				+ (-2 * u3 + 3 * u2) * b.value
				+ (u3 - u2) * length * m1
		end
	end
	return keys[count].value
end

-- The time of the clip's last key or marker.
function Store.duration(clip: Instance): number
	local last = 0
	for _, track in Store.tracks(clip) do
		local keys = Store.keys(track.curve)
		if #keys > 0 then
			last = math.max(last, keys[#keys].time)
		end
	end
	for _, curve in Store.markerCurves(clip) do
		for _, marker in currentBackend().markers(curve) do
			last = math.max(last, marker.time)
		end
	end
	return last
end

-- Every time at which any channel has a key, in order, a millisecond apart at least.
function Store.keyTimes(clip: Instance): { number }
	local seen: { [number]: boolean } = {}
	for _, track in Store.tracks(clip) do
		for _, key in Store.keys(track.curve) do
			seen[math.round(key.time * 1000)] = true
		end
	end
	local list = {}
	for slot in seen do
		table.insert(list, slot / 1000)
	end
	table.sort(list)
	return list
end

-- What a channel's numbers mean to the outside: degrees for rotation, studs for position.
local function outward(channel: string): number
	return if string.sub(channel, 1, 8) == "rotation" then 180 / math.pi else 1
end

-- ---------------------------------------------------------------------------------------
-- Checking what was asked for

local function markerCurve(clip: Instance, name: string, create: boolean): Instance?
	local found = clip:FindFirstChild(name)
	if found and found:IsA("MarkerCurve") then
		return found
	end
	if not create then
		return nil
	end
	local made = Roblox.Instance.new("MarkerCurve")
	made.Name = name
	made.Parent = clip
	return made
end

-- ---------------------------------------------------------------------------------------
-- Mirroring, across the rig's own plane between its left and right sides
--
-- Seen in a mirror, a turn about the rig's X axis (across it) is the same turn, and turns
-- about Y and Z go the other way; a move along X goes the other way. When each joint's rest
-- offsets on one side are the mirror image of the other side's, as on an R15 rig, this
-- holds joint by joint for the angles a curve clip keys: rotation (x, y, z) mirrors to
-- (x, -y, -z) and position (x, y, z) to (-x, y, z). So a mirrored clip is made by
-- mirroring its keys, tangents included, and is exact, with the keys a person can still
-- edit, rather than a pose baked at every frame.

Store.currentBackend = currentBackend
Store.sortKeys = sortKeys
Store.outward = outward
Store.markerCurve = markerCurve

return Store
