--!strict
-- Clips made of curves (CurveAnimation): their layout, the edits that can be made to
-- them, and reading, checking and fingerprinting them.
--
-- The layout is the one Roblox's Animation Editor writes, as measured in Studio. The clip
-- holds a Folder for each part of the rig, nested as the parts are, starting from the
-- root part. A joint's Folder holds a Vector3Curve named Position and an
-- EulerRotationCurve named Rotation, and each of those holds three FloatCurves named X,
-- Y and Z. Rotation is in radians, applied in X, Y, Z order. A channel that never moves
-- has no keys. Each marker name is a MarkerCurve at the top of the clip.
--
-- A key has a time, a value and an interpolation: Constant holds its value until the
-- next key, Linear goes straight to it, Cubic follows a curve set by this key's outgoing
-- tangent and the next key's incoming one. Tangents are in value per second; Studio
-- plays a cubic stretch as the standard Hermite curve (measured to 0.08 degrees).
--
-- Studio does not play the curves exactly. It samples them 30 times a second on the
-- clip's own clock (0, 1/30, 2/30 seconds and so on) and goes in straight lines between
-- those samples (measured). A key between two of those frames is never shown exactly,
-- so keys belong on whole frames, and checking a clip says when one is not.
--
-- To the outside, rotations are in degrees and rotation tangents in degrees per second,
-- as everywhere else in Keywright.
--
-- Keys are read and written through `Curves.backend`, which is Studio's own methods in
-- the plugin and a stand-in in the offline tests.

local Errors = require("../Core/Errors")
local Limb = require("../Rigs/Limb")
local Operations = require("./Operations")
local Pose = require("../Rigs/Pose")
local Rig = require("../Rigs/Rig")
local Roblox = require("../Core/Roblox")
local Smooth = require("./Smooth")

local Curves = {}

Curves.TIME_TOLERANCE = 0.001
-- How many times a second Studio samples a curve clip as it plays.
Curves.FRAME_RATE = 30
Curves.MAX_TIME = 300
Curves.MAX_POSITION = 1000
Curves.MAX_KEYS = 2000
Curves.MAX_OPERATIONS = 256
Curves.MAX_SNAPS = 16
Curves.MAX_JOINTS = 32
Curves.MAX_NAME = 100
Curves.MAX_MARKER_VALUE = 200
-- The longest a pin may take to blend in or out, in seconds.
Curves.MAX_BLEND = 2
Curves.HOLDS = { "full", "position" }
Curves.FLOOR_MODES = { "lift", "touch" }
Curves.MAX_LISTED = 500
Curves.DEFAULT_KEYS = 400
Curves.MAX_PAGE = 20000
Curves.PRIORITIES = { "Idle", "Movement", "Action", "Action2", "Action3", "Action4", "Core" }
Curves.INTERPOLATIONS = { "Cubic", "Linear", "Constant" }
Curves.CHANNELS = { "position.x", "position.y", "position.z", "rotation.x", "rotation.y", "rotation.z" }

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

Curves.backend = nil :: Backend?

local function backend(): Backend
	local current = Curves.backend
	if not current then
		current = studio()
		Curves.backend = current
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

function Curves.isCurves(clip: Instance): boolean
	return clip:IsA("CurveAnimation")
end

-- The Folder of a joint, made along with any of its ancestors if `create` is true.
function Curves.folder(clip: Instance, joint: string, create: boolean): Instance?
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
function Curves.channel(clip: Instance, joint: string, channel: string, create: boolean): Instance?
	local folder = Curves.folder(clip, joint, create)
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
function Curves.tracks(clip: Instance): { Track }
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

function Curves.markerCurves(clip: Instance): { Instance }
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

function Curves.keys(curve: Instance): { Key }
	local keys = backend().keys(curve)
	sortKeys(keys)
	return keys
end

function Curves.setKeys(curve: Instance, keys: { Key })
	sortKeys(keys)
	backend().setKeys(curve, keys)
end

-- The value of a channel at a time, as Studio plays it: the first key's value before it,
-- the last key's after it, and between two keys by the first one's interpolation.
function Curves.evaluate(keys: { Key }, time: number): number
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
function Curves.duration(clip: Instance): number
	local last = 0
	for _, track in Curves.tracks(clip) do
		local keys = Curves.keys(track.curve)
		if #keys > 0 then
			last = math.max(last, keys[#keys].time)
		end
	end
	for _, curve in Curves.markerCurves(clip) do
		for _, marker in backend().markers(curve) do
			last = math.max(last, marker.time)
		end
	end
	return last
end

-- Every time at which any channel has a key, in order, a millisecond apart at least.
function Curves.keyTimes(clip: Instance): { number }
	local seen: { [number]: boolean } = {}
	for _, track in Curves.tracks(clip) do
		for _, key in Curves.keys(track.curve) do
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

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function milliseconds(time: number): number
	return math.round(time * 1000) / 1000
end

local function rounded(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

local function refuse(where: string, message: string, hint: string?): never
	return Errors.throw("INVALID_ARGUMENT", `{where}: {message}`, hint)
end

local function needTime(where: string, value: any, field: string)
	if not isFinite(value) or value < 0 or value > Curves.MAX_TIME then
		refuse(where, `{field} must be from 0 to {Curves.MAX_TIME} seconds.`)
	end
end

local function needJoint(where: string, name: any, joints: { [string]: any })
	if type(name) ~= "string" or not joints[name] then
		refuse(where, `the rig has no joint "{tostring(name)}".`, "Call inspect_rig for the joint names.")
	end
end

local function needVector(where: string, value: any, field: string, limit: number?)
	if value == nil then
		return
	end
	if type(value) ~= "table" or #value ~= 3 then
		refuse(where, `{field} must be three numbers.`)
	end
	for index = 1, 3 do
		if not isFinite(value[index]) or (limit and math.abs(value[index]) > limit) then
			refuse(where, `{field} must be three finite numbers{if limit then ` within {limit}` else ""}.`)
		end
	end
end

local function needRange(where: string, operation: any)
	needTime(where, operation.time_from, "time_from")
	needTime(where, operation.time_to, "time_to")
	if operation.time_to < operation.time_from then
		refuse(where, "time_to must not be before time_from.")
	end
end

local function needJoints(where: string, list: any, joints: { [string]: any })
	if list == nil then
		return
	end
	if type(list) ~= "table" or #list == 0 or #list > Curves.MAX_JOINTS then
		refuse(where, `joints must list from 1 to {Curves.MAX_JOINTS} joint names.`)
	end
	for _, name in list do
		needJoint(where, name, joints)
	end
end

local function needOneOf(where: string, value: any, field: string, allowed: { string })
	if type(value) ~= "string" or not table.find(allowed, value) then
		refuse(where, `{field} must be one of {table.concat(allowed, ", ")}.`)
	end
end

local function needText(where: string, value: any, field: string, limit: number, allowEmpty: boolean?)
	if type(value) ~= "string" or #value > limit or (not allowEmpty and #value == 0) then
		refuse(where, `{field} must be text of {if allowEmpty then "at most" else "1 to"} {limit} characters.`)
	end
end

type Check = (where: string, operation: any, joints: { [string]: any }) -> ()

local checks: { [string]: Check } = {
	set_key = function(where, operation, joints)
		needJoint(where, operation.joint, joints)
		needTime(where, operation.time, "time")
		needVector(where, operation.rotation, "rotation")
		needVector(where, operation.position, "position", Curves.MAX_POSITION)
		if operation.rotation == nil and operation.position == nil then
			refuse(where, "give rotation, position or both.")
		end
		if operation.interpolation ~= nil then
			needOneOf(where, operation.interpolation, "interpolation", Curves.INTERPOLATIONS)
		end
	end,
	remove_key = function(where, operation, joints)
		needJoint(where, operation.joint, joints)
		needTime(where, operation.time, "time")
		if operation.channels ~= nil then
			if type(operation.channels) ~= "table" or #operation.channels == 0 then
				refuse(where, "channels must list at least one of rotation, position.")
			end
			for _, name in operation.channels do
				needOneOf(where, name, "each of channels", { "rotation", "position" })
			end
		end
	end,
	set_tangent = function(where, operation, joints)
		needJoint(where, operation.joint, joints)
		needTime(where, operation.time, "time")
		needOneOf(where, operation.channel, "channel", Curves.CHANNELS)
		if operation["in"] == nil and operation.out == nil then
			refuse(where, "give in, out or both.")
		end
		for _, field in { "in", "out" } do
			if operation[field] ~= nil and not isFinite(operation[field]) then
				refuse(where, `{field} must be a finite number.`)
			end
		end
	end,
	auto_tangents = function(where, operation, joints)
		needRange(where, operation)
		needJoints(where, operation.joints, joints)
		if operation.snap_at ~= nil then
			if type(operation.snap_at) ~= "table" or #operation.snap_at > Curves.MAX_SNAPS then
				refuse(where, `snap_at must list at most {Curves.MAX_SNAPS} times.`)
			end
			for _, time in operation.snap_at do
				needTime(where, time, "each time in snap_at")
			end
		end
		if operation.loop ~= nil and type(operation.loop) ~= "boolean" then
			refuse(where, "loop must be true or false.")
		end
	end,
	set_properties = function(where, operation)
		if operation.name == nil and operation.loop == nil and operation.priority == nil then
			refuse(where, "give name, loop or priority.")
		end
		if operation.name ~= nil then
			needText(where, operation.name, "name", Curves.MAX_NAME)
		end
		if operation.loop ~= nil and type(operation.loop) ~= "boolean" then
			refuse(where, "loop must be true or false.")
		end
		if operation.priority ~= nil then
			needOneOf(where, operation.priority, "priority", Curves.PRIORITIES)
		end
	end,
	set_marker = function(where, operation)
		needTime(where, operation.time, "time")
		needText(where, operation.name, "name", Curves.MAX_NAME)
		if operation.value ~= nil then
			needText(where, operation.value, "value", Curves.MAX_MARKER_VALUE, true)
		end
	end,
	remove_marker = function(where, operation)
		needTime(where, operation.time, "time")
		needText(where, operation.name, "name", Curves.MAX_NAME)
	end,
	restore_source = function() end,
	place_on_floor = function(where, operation, joints)
		needRange(where, operation)
		if operation.mode ~= nil then
			needOneOf(where, operation.mode, "mode", Curves.FLOOR_MODES)
		end
		needJoints(where, operation.parts, joints)
		for _, field in { "blend_in", "blend_out" } do
			local value = operation[field]
			if value ~= nil and (not isFinite(value) or value < 0 or value > Curves.MAX_BLEND) then
				refuse(where, `{field} must be from 0 to {Curves.MAX_BLEND} seconds.`)
			end
		end
	end,
	pin = function(where, operation, joints)
		local chain = if type(operation.part) == "string" then Limb.CHAINS[operation.part] else nil
		if not chain then
			refuse(where, "part must be LeftFoot, RightFoot, LeftHand or RightHand.")
		end
		for _, name in chain :: { string } do
			needJoint(where, name, joints)
		end
		needRange(where, operation)
		if operation.at ~= nil then
			needTime(where, operation.at, "at")
		end
		needVector(where, operation.position, "position", Curves.MAX_POSITION)
		needVector(where, operation.pole, "pole", Curves.MAX_POSITION)
		if operation.relative_to ~= nil then
			needJoint(where, operation.relative_to, joints)
			if table.find(chain :: { string }, operation.relative_to) then
				refuse(where, `relative_to cannot be a part of the limb being pinned.`)
			end
		end
		if operation.hold ~= nil then
			needOneOf(where, operation.hold, "hold", Curves.HOLDS)
		end
		for _, field in { "blend_in", "blend_out" } do
			local value = operation[field]
			if value ~= nil and (not isFinite(value) or value < 0 or value > Curves.MAX_BLEND) then
				refuse(where, `{field} must be from 0 to {Curves.MAX_BLEND} seconds.`)
			end
		end
	end,
}

function Curves.types(): { string }
	local names = {}
	for name in checks do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function Curves.check(operations: any, joints: { [string]: any })
	if type(operations) ~= "table" or #operations == 0 then
		Errors.throw("INVALID_ARGUMENT", "operations must be a non-empty list.")
	end
	if #operations > Curves.MAX_OPERATIONS then
		Errors.throw("LIMIT_EXCEEDED", `A batch holds at most {Curves.MAX_OPERATIONS} operations.`)
	end
	for index, operation in operations do
		local where = `operations[{index}]`
		if type(operation) ~= "table" then
			refuse(where, "is not an object.")
		end
		local check = if type(operation.type) == "string" then checks[operation.type] else nil
		if not check then
			refuse(
				where,
				`"{tostring(operation.type)}" cannot be used on a clip made of curves.`,
				`The types for curve clips are: {table.concat(Curves.types(), ", ")}.`
			)
		end
		(check :: Check)(where, operation, joints)
	end
end

-- ---------------------------------------------------------------------------------------
-- Applying

export type Context = { joints: { [string]: any }, source: Instance? }
export type Changed = { [string]: number }

local function count(changed: Changed, what: string, by: number?)
	changed[what] = (changed[what] or 0) + (by or 1)
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) < Curves.TIME_TOLERANCE
end

-- Puts a value into a channel at a time: the key there is changed, or one is made.
local function putKey(curve: Instance, time: number, value: number, interpolation: string?, changed: Changed)
	local keys = Curves.keys(curve)
	for _, key in keys do
		if near(key.time, time) then
			key.value = value
			if interpolation then
				key.interpolation = interpolation
				if interpolation ~= "Cubic" then
					key.right = nil
				end
			end
			Curves.setKeys(curve, keys)
			count(changed, "keys_changed")
			return
		end
	end
	if #keys >= Curves.MAX_KEYS then
		Errors.throw("LIMIT_EXCEEDED", `A curve holds at most {Curves.MAX_KEYS} keys.`)
	end
	local mode = interpolation or "Cubic"
	if #keys == 0 and time > Curves.TIME_TOLERANCE then
		-- A channel with no keys is at rest the whole clip. A curve holds its first key's
		-- value back to the start, so a first key later on would change everything before
		-- it too. A key at rest at the start keeps the time before as it was.
		table.insert(
			keys,
			{ time = 0, value = 0, interpolation = mode, left = 0, right = if mode == "Cubic" then 0 else nil }
		)
		count(changed, "keys_created")
	end
	table.insert(keys, {
		time = time,
		value = value,
		interpolation = mode,
		left = 0,
		right = if mode == "Cubic" then 0 else nil,
	})
	Curves.setKeys(curve, keys)
	count(changed, "keys_created")
end

-- Writes tangents for every key of a channel that lies in a range: those a smooth curve
-- through the keys would have, as in smooth_motion. Keys in the range become Cubic.
local function smoothChannel(curve: Instance, from: number, to: number, snapTimes: { number }, loop: boolean): number
	local keys = Curves.keys(curve)
	if #keys < 2 then
		return 0
	end
	local smoothKeys: { Smooth.Key } = {}
	local snap: { [number]: boolean } = {}
	for index, key in keys do
		smoothKeys[index] = { time = key.time, values = { key.value } }
		for _, at in snapTimes do
			if near(key.time, at) then
				snap[index] = true
			end
		end
	end
	local arriving, leaving = Smooth.tangents(smoothKeys, 1, { snap = snap, loop = loop })
	local written = 0
	for index, key in keys do
		if key.time >= from - Curves.TIME_TOLERANCE and key.time <= to + Curves.TIME_TOLERANCE then
			key.left = arriving[index]
			if index < #keys then
				key.interpolation = "Cubic"
				key.right = leaving[index]
			end
			written += 1
		end
	end
	Curves.setKeys(curve, keys)
	return written
end

-- Every rotation has two sets of Euler angles that give it, and each angle can be taken a
-- whole turn either way. The set nearest the angles a curve is at already is the one it
-- should run to, or it would swing the long way round.
local function nearestAngles(x: number, y: number, z: number, previous: { number }): { number }
	local function placed(angles: { number }): ({ number }, number)
		local out, distance = {}, 0
		for index = 1, 3 do
			local angle, before = angles[index], previous[index]
			angle = before + ((angle - before + math.pi) % (2 * math.pi)) - math.pi
			out[index] = angle
			distance += math.abs(angle - before)
		end
		return out, distance
	end
	local first, firstDistance = placed({ x, y, z })
	local second, secondDistance = placed({ x + math.pi, math.pi - y, z + math.pi })
	return if secondDistance < firstDistance then second else first
end

-- The keys of every channel of a clip, read once, by joint and then by channel.
type Channels = { [string]: { [string]: { Key } } }

local function readChannels(clip: Instance): Channels
	local channels: Channels = {}
	for _, track in Curves.tracks(clip) do
		channels[track.joint] = channels[track.joint] or {}
		channels[track.joint][track.channel] = Curves.keys(track.curve)
	end
	return channels
end

-- The transform of every joint of the rig at a time, as the channels give it.
local function transformsAt(channels: Channels, time: number): { [string]: CFrame }
	local transforms: { [string]: CFrame } = {}
	for _, joint in Rig.R15_ORDER do
		local values = {}
		local own = channels[joint]
		for index, channel in Curves.CHANNELS do
			local keys = own and own[channel]
			values[index] = if keys then Curves.evaluate(keys, time) else 0
		end
		transforms[joint] = Roblox.CFrame.new(values[1], values[2], values[3])
			* Roblox.CFrame.fromEulerAnglesXYZ(values[4], values[5], values[6])
	end
	return transforms
end

-- Whether the joints given are the rig's own, with its parts, and not only their names.
local function hasGeometry(joints: { [string]: any }, names: { string }): boolean
	for _, name in names do
		local joint = joints[name]
		if type(joint) ~= "table" or joint.part1 == nil or joint.instance == nil then
			return false
		end
	end
	return true
end

-- Parts are measured against the floor as boxes of their size. A lower leg's box reaches
-- down beside the ankle, so in a deep crouch, with the shin tilted forward, the box's back
-- corner dips below the floor while the shin itself, which is slimmer there, stays above
-- it (seen in Studio, 2026-11-25). The lower legs are left out of every floor measure.
local NOT_FLOORED = { LeftLowerLeg = true, RightLowerLeg = true }

-- The parts measured against the floor.
local FLOORED: { string } = {}
for _, name in Rig.R15_ORDER do
	if not NOT_FLOORED[name] then
		table.insert(FLOORED, name)
	end
end

-- The floor: how high the rig's lowest point is in its rest pose, relative to the root
-- part. For a character, that is the soles of its feet.
local function floorOf(joints: { [string]: any }): number
	local identity = Roblox.CFrame.new()
	local rest: { [string]: CFrame } = {}
	for _, name in Rig.R15_ORDER do
		rest[name] = identity
	end
	local floor = math.huge
	for _, part in Pose.track({ joints = joints } :: any, rest, identity, Rig.R15_ORDER) do
		floor = math.min(floor, part.lowest)
	end
	return floor
end

-- Rounds a smooth step from 0 to 1 as `t` goes from 0 to 1.
local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Whole frames from `first` to `last`, with a value for each, in order.
type Frames = { first: number, last: number, values: { number }, duration: number }

-- Replaces a channel's keys from one whole frame to another with one key a frame, with
-- smooth tangents, and leaves the rest of the channel as it was. Where the channel had no
-- key on one side of the range, the motion there is held with a key a frame away, so that
-- it stays as it was. `original` is the channel's keys before the change.
local function writeFrames(
	clip: Instance,
	joint: string,
	channel: string,
	original: { Key },
	frames: Frames,
	changed: Changed
)
	local rate = Curves.FRAME_RATE
	local startTime, endTime = frames.first / rate, frames.last / rate
	local kept: { Key } = {}
	local earlier, later = false, false
	for _, key in original do
		if key.time < startTime - Curves.TIME_TOLERANCE then
			earlier = true
			table.insert(kept, table.clone(key))
		elseif key.time > endTime + Curves.TIME_TOLERANCE then
			later = true
			table.insert(kept, table.clone(key))
		end
	end
	local guards: { number } = {}
	if not earlier and frames.first > 0 then
		table.insert(guards, (frames.first - 1) / rate)
	end
	if not later and endTime < frames.duration - Curves.TIME_TOLERANCE then
		table.insert(guards, (frames.last + 1) / rate)
	end
	for _, time in guards do
		table.insert(kept, {
			time = time,
			value = Curves.evaluate(original, time),
			interpolation = "Cubic",
			left = 0,
			right = 0,
		})
	end
	for index, value in frames.values do
		table.insert(kept, {
			time = (frames.first + index - 1) / rate,
			value = value,
			interpolation = "Cubic",
			left = 0,
			right = 0,
		})
	end
	if #kept > Curves.MAX_KEYS then
		Errors.throw("LIMIT_EXCEEDED", `A curve holds at most {Curves.MAX_KEYS} keys.`)
	end
	local curve = Curves.channel(clip, joint, channel, true) :: Instance
	Curves.setKeys(curve, kept)
	local spanFrom = if #guards > 0 then math.min(startTime, guards[1]) else startTime
	smoothChannel(curve, spanFrom, math.max(endTime, guards[#guards] or endTime), {}, false)
	count(changed, "keys_written", #frames.values + #guards)
end

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

type Apply = (where: string, clip: Instance, operation: any, context: Context, changed: Changed) -> ()

local appliers: { [string]: Apply } = {
	set_key = function(_where, clip, operation, _context, changed)
		local mode = operation.interpolation
		for axis, letter in { "x", "y", "z" } do
			if operation.rotation then
				local curve = Curves.channel(clip, operation.joint, `rotation.{letter}`, true) :: Instance
				putKey(curve, operation.time, math.rad(operation.rotation[axis]), mode, changed)
			end
			if operation.position then
				local curve = Curves.channel(clip, operation.joint, `position.{letter}`, true) :: Instance
				putKey(curve, operation.time, operation.position[axis], mode, changed)
			end
		end
	end,

	remove_key = function(where, clip, operation, _context, changed)
		local kinds = operation.channels or { "rotation", "position" }
		local removed = 0
		for _, kind in kinds do
			for _, letter in { "x", "y", "z" } do
				local curve = Curves.channel(clip, operation.joint, `{kind}.{letter}`, false)
				if curve then
					local keys = Curves.keys(curve)
					local kept = {}
					for _, key in keys do
						if near(key.time, operation.time) then
							removed += 1
						else
							table.insert(kept, key)
						end
					end
					if #kept ~= #keys then
						Curves.setKeys(curve, kept)
					end
				end
			end
		end
		if removed == 0 then
			refuse(where, `"{operation.joint}" has no key at {operation.time} seconds.`)
		end
		count(changed, "keys_removed", removed)
	end,

	set_tangent = function(where, clip, operation, _context, changed)
		local curve = Curves.channel(clip, operation.joint, operation.channel, false)
		local keys: { Key } = if curve then Curves.keys(curve) else {}
		local scale = outward(operation.channel)
		for index, key in keys do
			if near(key.time, operation.time) then
				if operation["in"] ~= nil then
					key.left = operation["in"] / scale
				end
				if operation.out ~= nil then
					if index == #keys then
						refuse(where, "the last key of a curve has no stretch after it, so no outgoing tangent.")
					end
					key.interpolation = "Cubic"
					key.right = operation.out / scale
				end
				Curves.setKeys(curve :: Instance, keys)
				count(changed, "tangents_set")
				return
			end
		end
		refuse(where, `"{operation.joint}" has no {operation.channel} key at {operation.time} seconds.`)
	end,

	auto_tangents = function(where, clip, operation, _context, changed)
		local wanted: { [string]: boolean }? = nil
		if operation.joints then
			wanted = {}
			for _, name in operation.joints do
				(wanted :: { [string]: boolean })[name] = true
			end
		end
		local duration = Curves.duration(clip)
		local whole = near(operation.time_from, 0) and near(operation.time_to, duration)
		local loop = if operation.loop ~= nil then operation.loop else ((clip :: any).Loop == true and whole)
		local written = 0
		for _, track in Curves.tracks(clip) do
			if not wanted or wanted[track.joint] then
				written += smoothChannel(
					track.curve,
					operation.time_from,
					operation.time_to,
					operation.snap_at or {},
					loop
				)
			end
		end
		if written == 0 then
			refuse(
				where,
				`no channel has two or more keys with one from {operation.time_from} to {operation.time_to} seconds.`
			)
		end
		count(changed, "keys_changed", written)
	end,

	set_properties = function(_where, clip, operation, _context, changed)
		local target = clip :: any
		if operation.name ~= nil then
			target.Name = operation.name
		end
		if operation.loop ~= nil then
			target.Loop = operation.loop
		end
		if operation.priority ~= nil then
			target.Priority = (Roblox.Enum.AnimationPriority :: any)[operation.priority]
		end
		count(changed, "properties_changed")
	end,

	set_marker = function(_where, clip, operation, _context, changed)
		local curve = markerCurve(clip, operation.name, true) :: Instance
		local markers = backend().markers(curve)
		local found = false
		for _, marker in markers do
			if near(marker.time, operation.time) then
				marker.value = operation.value or ""
				found = true
			end
		end
		if not found then
			table.insert(markers, { time = operation.time, value = operation.value or "" })
		end
		table.sort(markers, function(a, b)
			return a.time < b.time
		end)
		backend().setMarkers(curve, markers)
		count(changed, "markers_set")
	end,

	remove_marker = function(where, clip, operation, _context, changed)
		local curve = markerCurve(clip, operation.name, false)
		local markers: { Marker } = if curve then backend().markers(curve) else {}
		local kept = {}
		for _, marker in markers do
			if not near(marker.time, operation.time) then
				table.insert(kept, marker)
			end
		end
		if #kept == #markers then
			refuse(where, `there is no marker "{operation.name}" at {operation.time} seconds.`)
		end
		if #kept == 0 then
			(curve :: Instance).Parent = nil
		else
			backend().setMarkers(curve :: Instance, kept)
		end
		count(changed, "markers_removed", #markers - #kept)
	end,

	pin = function(where, clip, operation, context, changed)
		local chain = Limb.CHAINS[operation.part]
		local joints = context.joints
		if not hasGeometry(joints, chain) then
			refuse(where, "this rig's limb could not be measured, so nothing can be pinned on it.")
		end
		local duration = Curves.duration(clip)
		if operation.time_to > duration + Curves.TIME_TOLERANCE then
			refuse(
				where,
				`the clip ends at {milliseconds(duration)} seconds, before time_to.`,
				"Key the clip out to its full length first."
			)
		end
		local from, to = operation.time_from, operation.time_to
		local first = math.max(0, from - (operation.blend_in or 0))
		local last = math.min(duration, to + (operation.blend_out or 0))
		local rate = Curves.FRAME_RATE
		local firstFrame = math.ceil(first * rate - 1e-6)
		local lastFrame = math.floor(last * rate + 1e-6)
		if lastFrame < firstFrame then
			refuse(where, "the range holds no whole frame; Studio shows a curve clip only at whole frames.")
		end

		-- Everything is worked out from the clip as it is, before anything is written.
		local channels = readChannels(clip)
		local scan = { joints = joints } :: any
		local identity = Roblox.CFrame.new()
		local limb = { joints[chain[1]], joints[chain[2]], joints[chain[3]] }
		-- The part the target moves with, if any: the target is kept in its frame, so a
		-- hand held to the chest stays on the chest as the body bends.
		local anchorName = operation.relative_to
		local function anchorOf(placed: { [string]: CFrame }): CFrame
			return if anchorName then placed[anchorName] else identity
		end
		local reference = Pose.place(scan, transformsAt(channels, operation.at or from), identity)
		-- The target, in the anchor's frame.
		local tipLocal = anchorOf(reference):Inverse() * reference[chain[3]]
		if operation.position then
			local p = operation.position
			tipLocal = Roblox.CFrame.new(p[1], p[2], p[3]) * (tipLocal - tipLocal.Position)
		end
		local full = (operation.hold or "full") == "full"
		local poleLocal = if operation.pole
			then Roblox.Vector3.new(operation.pole[1], operation.pole[2], operation.pole[3])
			else nil

		local frames: { { time: number, transforms: { CFrame } } } = {}
		local missed, worst = 0, 0
		for frame = firstFrame, lastFrame do
			local time = frame / rate
			local transforms = transformsAt(channels, time)
			local placed = Pose.place(scan, transforms, identity)
			local current = { transforms[chain[1]], transforms[chain[2]], transforms[chain[3]] }
			local anchor = anchorOf(placed)
			local tip = anchor * tipLocal
			local weight = 1
			if time < from - Curves.TIME_TOLERANCE then
				weight = smoothstep((time - first) / math.max(from - first, 1e-6))
			elseif time > to + Curves.TIME_TOLERANCE then
				weight = smoothstep((last - time) / math.max(last - to, 1e-6))
			end
			-- Easing in or out, the target itself moves from where the animation has the part
			-- to where it is held, and the limb reaches for it. The part then travels straight
			-- between the two, instead of wherever angles part way between would put it.
			local free = placed[chain[3]]
			if weight < 1 then
				tip = free:Lerp(tip, weight)
			end
			local solution = if weight <= 0
				then { transforms = current, miss = 0 }
				else Limb.solve({
					parent = placed[Rig.R15_PARENTS[chain[1]]],
					joints = limb,
					current = current,
					pivot = Limb.pivotOf(limb[3], tip),
					tip = if full then tip else nil,
					bend = Limb.BEND[operation.part],
					pole = if poleLocal then anchor * poleLocal else nil,
					poleWeight = weight,
				})
			local result = solution.transforms
			if weight >= 1 and solution.miss > 0.001 then
				missed += 1
				worst = math.max(worst, solution.miss)
			end
			table.insert(frames, { time = time, transforms = result })
		end

		-- The three joints' rotation keys in the range are replaced by one key a frame.
		local startTime = firstFrame / rate
		for index, joint in chain do
			local own = channels[joint] or {}
			local before: { number } = {}
			for axis, letter in { "x", "y", "z" } do
				local keys = own[`rotation.{letter}`]
				before[axis] = if keys then Curves.evaluate(keys, startTime) else 0
			end
			local angles: { { number } } = {}
			local previous = before
			for _, entry in frames do
				local x, y, z = entry.transforms[index]:ToEulerAnglesXYZ()
				previous = nearestAngles(x, y, z, previous)
				table.insert(angles, previous)
			end
			for axis, letter in { "x", "y", "z" } do
				local values = {}
				for frame in frames do
					values[frame] = angles[frame][axis]
				end
				writeFrames(clip, joint, `rotation.{letter}`, own[`rotation.{letter}`] or {}, {
					first = firstFrame,
					last = lastFrame,
					values = values,
					duration = duration,
				}, changed)
			end
		end
		count(changed, "frames_pinned", #frames)
		if missed > 0 then
			count(changed, "frames_out_of_reach", missed)
			changed.largest_miss_studs = math.max(changed.largest_miss_studs or 0, rounded(worst, 3))
		end
	end,

	place_on_floor = function(where, clip, operation, context, changed)
		local joints = context.joints
		if not hasGeometry(joints, Rig.R15_ORDER) then
			refuse(where, "this rig's parts could not be measured, so the floor cannot be found.")
		end
		local duration = Curves.duration(clip)
		if operation.time_to > duration + Curves.TIME_TOLERANCE then
			refuse(
				where,
				`the clip ends at {milliseconds(duration)} seconds, before time_to.`,
				"Key the clip out to its full length first."
			)
		end
		local from, to = operation.time_from, operation.time_to
		local first = math.max(0, from - (operation.blend_in or 0))
		local last = math.min(duration, to + (operation.blend_out or 0))
		local rate = Curves.FRAME_RATE
		local firstFrame = math.ceil(first * rate - 1e-6)
		local lastFrame = math.floor(last * rate + 1e-6)
		if lastFrame < firstFrame then
			refuse(where, "the range holds no whole frame; Studio shows a curve clip only at whole frames.")
		end
		local touch = operation.mode == "touch"
		local parts = operation.parts or FLOORED
		local floor = floorOf(joints)
		local channels = readChannels(clip)
		local scan = { joints = joints } :: any
		local identity = Roblox.CFrame.new()
		-- The hips' position is measured in the root joint's own frame; straight up in the
		-- rig is this direction there.
		local c0 = Rig.rest(joints.LowerTorso)
		local up = c0:VectorToObjectSpace(Roblox.Vector3.new(0, 1, 0))

		local moves: { number } = {}
		local raised, lowered, moved = 0, 0, 0
		for frame = firstFrame, lastFrame do
			local time = frame / rate
			local lowest = math.huge
			for _, part in Pose.track(scan, transformsAt(channels, time), identity, parts) do
				lowest = math.min(lowest, part.lowest)
			end
			local move = floor - lowest
			if not touch then
				move = math.max(0, move)
			end
			if time < from - Curves.TIME_TOLERANCE then
				move *= smoothstep((time - first) / math.max(from - first, 1e-6))
			elseif time > to + Curves.TIME_TOLERANCE then
				move *= smoothstep((last - time) / math.max(last - to, 1e-6))
			end
			if math.abs(move) > 0.001 then
				moved += 1
			end
			raised = math.max(raised, move)
			lowered = math.max(lowered, -move)
			table.insert(moves, move)
		end
		count(changed, "frames_moved", moved)
		if moved == 0 then
			return
		end
		changed.largest_raise_studs = math.max(changed.largest_raise_studs or 0, rounded(raised, 3))
		if lowered > 0 then
			changed.largest_drop_studs = math.max(changed.largest_drop_studs or 0, rounded(lowered, 3))
		end
		local own = channels.LowerTorso or {}
		for axis, letter in { "x", "y", "z" } do
			local share = ({ up.X, up.Y, up.Z })[axis]
			if math.abs(share) < 1e-9 then
				continue
			end
			local channel = `position.{letter}`
			local original = own[channel] or {}
			local values = {}
			for index, move in moves do
				values[index] = Curves.evaluate(original, (firstFrame + index - 1) / rate) + move * share
			end
			writeFrames(clip, "LowerTorso", channel, original, {
				first = firstFrame,
				last = lastFrame,
				values = values,
				duration = duration,
			}, changed)
		end
	end,

	restore_source = function(_where, clip, _operation, context, changed)
		for _, child in clip:GetChildren() do
			child.Parent = nil
		end
		local source = context.source :: any
		if source then
			-- A working copy converted from a keyframe clip is converted again.
			local from = if source:IsA("KeyframeSequence")
				then Curves.fromKeyframes(source, Operations.keyframes(source), Operations.findPose)
				else source
			for _, child in from:GetChildren() do
				child:Clone().Parent = clip
			end
			(clip :: any).Loop = source.Loop;
			(clip :: any).Priority = source.Priority
		end
		count(changed, "restored")
	end,
}

function Curves.run(clip: Instance, operations: { any }, context: Context, before: ((index: number) -> ())?): Changed
	local changed: Changed = {}
	for index, operation in operations do
		if before then
			before(index)
		end
		appliers[operation.type](`operations[{index}]`, clip, operation, context, changed)
	end
	return changed
end

-- ---------------------------------------------------------------------------------------
-- Making a curve clip from a keyframe clip

-- A curve clip that passes through every pose of a keyframe clip, with smooth tangents.
-- Between keys the motion follows the curves, not Roblox's per-stretch easing, so it can
-- differ there; at the keys it is the same.
function Curves.fromKeyframes(
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
				local curve = Curves.channel(clip, joint, channel, true) :: Instance
				Curves.setKeys(curve, keys)
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
		backend().setMarkers(markerCurve(clip, name, true) :: Instance, list)
	end
	return clip
end

-- ---------------------------------------------------------------------------------------
-- Reading

export type ReadOptions = {
	joints: { string }?,
	timeFrom: number?,
	timeTo: number?,
	offset: number?,
	limit: number?,
	posesOnly: boolean?,
}

function Curves.read(clip: Instance, options: ReadOptions): { [string]: any }
	local result: { [string]: any } = {}
	local tracks = Curves.tracks(clip)
	local function within(time: number): boolean
		return not (
			(options.timeFrom and time < options.timeFrom - Curves.TIME_TOLERANCE)
			or (options.timeTo and time > options.timeTo + Curves.TIME_TOLERANCE)
		)
	end
	if not options.posesOnly then
		local animated: { [string]: boolean } = {}
		local keyCount = 0
		for _, track in tracks do
			local keys = Curves.keys(track.curve)
			keyCount += #keys
			if #keys > 0 then
				animated[track.joint] = true
			end
		end
		local joints = {}
		for name in animated do
			table.insert(joints, name)
		end
		table.sort(joints)
		local times = {}
		local allTimes = Curves.keyTimes(clip)
		local matching = 0
		for _, time in allTimes do
			if within(time) then
				matching += 1
				if #times < Curves.MAX_LISTED then
					table.insert(times, milliseconds(time))
				end
			end
		end
		local markers = {}
		for _, curve in Curves.markerCurves(clip) do
			for _, marker in backend().markers(curve) do
				if within(marker.time) and #markers < Curves.MAX_LISTED then
					table.insert(markers, { name = curve.Name, value = marker.value, time = milliseconds(marker.time) })
				end
			end
		end
		table.sort(markers, function(a, b)
			return a.time < b.time
		end)
		result.format = "curves"
		result.name = clip.Name
		result.loop = (clip :: any).Loop
		result.priority = (clip :: any).Priority.Name
		result.duration = milliseconds(Curves.duration(clip))
		result.keyframe_count = #allTimes
		result.keyframe_times = times
		result.keyframe_times_truncated = if matching > #times then true else nil
		result.key_count = keyCount
		result.animated_joints = joints
		result.markers = markers
	end
	local wanted: { string } = options.joints or {}
	if #wanted > 0 then
		local offset = math.max(0, math.floor(options.offset or 0))
		local limit = math.clamp(math.floor(options.limit or Curves.DEFAULT_KEYS), 1, Curves.MAX_PAGE)
		local page, total = {}, 0
		for _, joint: string in wanted :: { string } do
			for _, channel in Curves.CHANNELS do
				local curve = Curves.channel(clip, joint, channel, false)
				if curve then
					local scale = outward(channel)
					for _, key in Curves.keys(curve) do
						if within(key.time) then
							total += 1
							if total > offset and #page < limit then
								table.insert(page, {
									joint = joint,
									channel = channel,
									time = milliseconds(key.time),
									value = rounded(key.value * scale, 4),
									interpolation = key.interpolation,
									["in"] = if key.left ~= nil then rounded(key.left * scale, 3) else nil,
									out = if key.right ~= nil then rounded(key.right * scale, 3) else nil,
								})
							end
						end
					end
				end
			end
		end
		result.keys = page
		result.keys_total = total
		if offset + #page < total then
			result.next_offset = offset + #page
		end
	end
	return result
end

-- ---------------------------------------------------------------------------------------
-- Fingerprint lines and checks

local function nine(value: number?): string
	return if value == nil then "-" else string.format("%.9g", value)
end

-- One line for everything in the clip that affects how it plays, in a fixed order.
function Curves.digestLines(clip: Instance): { string }
	local lines = { `loop|{tostring((clip :: any).Loop)}`, `priority|{tostring((clip :: any).Priority)}` }
	for _, track in Curves.tracks(clip) do
		for _, key in Curves.keys(track.curve) do
			table.insert(
				lines,
				`key|{track.path}|{nine(key.time)}|{nine(key.value)}|{key.interpolation}|{nine(key.left)}|{nine(
					key.right
				)}`
			)
		end
	end
	for _, curve in Curves.markerCurves(clip) do
		for _, marker in backend().markers(curve) do
			table.insert(lines, `marker|{curve.Name}|{nine(marker.time)}|{marker.value}`)
		end
	end
	table.sort(lines)
	return lines
end

-- The rotation of a joint at a time, from its three rotation channels.
local function rotationAt(clip: Instance, joint: string, time: number): CFrame
	local angles = {}
	for index, letter in { "x", "y", "z" } do
		local curve = Curves.channel(clip, joint, `rotation.{letter}`, false)
		angles[index] = if curve then Curves.evaluate(Curves.keys(curve), time) else 0
	end
	return Roblox.CFrame.fromEulerAnglesXYZ(angles[1], angles[2], angles[3])
end

local function turn(a: CFrame, b: CFrame): number
	local squares = (a.RightVector - b.RightVector).Magnitude ^ 2
		+ (a.UpVector - b.UpVector).Magnitude ^ 2
		+ (a.LookVector - b.LookVector).Magnitude ^ 2
	return math.deg(2 * math.asin(math.min(1, math.sqrt(squares / 8))))
end

-- Contact with the ground, measured as Studio shows the clip: at every whole frame. The
-- floor is where the rig's lowest point is in its rest pose (see floorOf). A part that
-- goes below it is in the ground. A foot that rests on it for a few frames is planted,
-- and should not slide while it is.

local function contacts(
	clip: Instance,
	joints: { [string]: any },
	thresholds: { [string]: number },
	report: (issue: any) -> ()
)
	if not hasGeometry(joints, Rig.R15_ORDER) then
		return
	end
	local duration = Curves.duration(clip)
	local rate = Curves.FRAME_RATE
	local scan = { joints = joints } :: any
	local identity = Roblox.CFrame.new()
	local floor = floorOf(joints)
	local channels = readChannels(clip)
	local frames = math.floor(duration * rate + 1e-6)
	type Below = { deepest: number, at: number, first: number, last: number }
	local below: { [string]: Below } = {}
	local feet: { [string]: { Pose.Tracked } } = { LeftFoot = {}, RightFoot = {} }
	for frame = 0, frames do
		local time = frame / rate
		local tracked = Pose.track(scan, transformsAt(channels, time), identity, Rig.R15_ORDER)
		for name, part in tracked do
			local depth = floor - part.lowest
			if depth > thresholds.floor_studs and not NOT_FLOORED[name] then
				local entry = below[name]
				if not entry then
					below[name] = { deepest = depth, at = time, first = time, last = time }
				else
					entry.last = time
					if depth > entry.deepest then
						entry.deepest, entry.at = depth, time
					end
				end
			end
		end
		for foot, list in feet do
			list[frame + 1] = tracked[foot]
		end
	end
	for _, name in Rig.R15_ORDER do
		local entry = below[name]
		if entry then
			report({
				code = "BELOW_FLOOR",
				severity = "warning",
				message = `"{name}" goes {rounded(entry.deepest, 3)} studs into the floor around {milliseconds(
					entry.at
				)} seconds, between {milliseconds(entry.first)} and {milliseconds(entry.last)} seconds. The floor is the rig's lowest point at rest, {rounded(
					-floor,
					3
				)} studs below the root part.`,
				joints = { name },
				time = milliseconds(entry.at),
				time_from = milliseconds(entry.first),
				time_to = milliseconds(entry.last),
				measured = rounded(entry.deepest, 3),
				threshold = thresholds.floor_studs,
				unit = "studs",
			})
		end
	end

	-- A foot is planted while its lowest point is within the floor limit of the floor, for
	-- three frames or more. In a looping clip a foot that moves back steadily while
	-- planted is a cycle made on the spot, as a walk or run usually is, and is left alone.
	for _, foot in { "LeftFoot", "RightFoot" } do
		local list = feet[foot]
		local index = 1
		while index <= #list do
			if math.abs(list[index].lowest - floor) > thresholds.floor_studs then
				index += 1
				continue
			end
			local finish = index
			while finish + 1 <= #list and math.abs(list[finish + 1].lowest - floor) <= thresholds.floor_studs do
				finish += 1
			end
			if finish - index >= 2 then
				local start = list[index].position
				local drift = 0
				local steps: { number } = {}
				for step = index, finish do
					local here = list[step].position
					drift = math.max(drift, math.sqrt((here[1] - start[1]) ^ 2 + (here[3] - start[3]) ^ 2))
					if step > index then
						local there = list[step - 1].position
						table.insert(steps, math.sqrt((here[1] - there[1]) ^ 2 + (here[3] - there[3]) ^ 2))
					end
				end
				local steady = false
				if (clip :: any).Loop == true and #steps > 0 then
					local mean = 0
					for _, length in steps do
						mean += length / #steps
					end
					steady = mean * rate > 0.5
					for _, length in steps do
						steady = steady and math.abs(length - mean) <= 0.35 * mean
					end
				end
				if drift > thresholds.slide_studs and not steady then
					local from, to = (index - 1) / rate, (finish - 1) / rate
					report({
						code = "FOOT_SLIDE",
						severity = "warning",
						message = `"{foot}" is on the floor from {milliseconds(from)} to {milliseconds(to)} seconds but slides {rounded(
							drift,
							3
						)} studs along it. Pin it with the pin operation to keep it in place.`,
						joints = { foot },
						time_from = milliseconds(from),
						time_to = milliseconds(to),
						measured = rounded(drift, 3),
						threshold = thresholds.slide_studs,
						unit = "studs",
					})
				end
			end
			index = finish + 1
		end
	end
end

-- Findings for a curve clip, in the same form as Validate's. `report` takes each one.
function Curves.validate(
	clip: Instance,
	joints: { [string]: any },
	nonKinematic: { [string]: boolean }?,
	thresholds: { [string]: number },
	report: (issue: any) -> ()
)
	local duration = Curves.duration(clip)
	local byJoint: { [string]: boolean } = {}
	for _, track in Curves.tracks(clip) do
		local keys = Curves.keys(track.curve)
		if #keys == 0 then
			continue
		end
		byJoint[track.joint] = true
		if not joints[track.joint] and track.joint ~= Rig.ROOT then
			report({
				code = "UNKNOWN_JOINT",
				severity = "error",
				message = `There are keys for "{track.joint}", but the rig has no such joint.`,
				joints = { track.joint },
			})
		end
		if #keys > Curves.MAX_KEYS then
			report({
				code = "TOO_MANY_KEYS",
				severity = "error",
				message = `{track.path} has {#keys} keys; the most supported is {Curves.MAX_KEYS}.`,
				joints = { track.joint },
				measured = #keys,
				threshold = Curves.MAX_KEYS,
				unit = "keys",
			})
		end
		for _, key in keys do
			local sound = isFinite(key.value)
				and isFinite(key.time)
				and (key.left == nil or isFinite(key.left))
				and (key.right == nil or isFinite(key.right))
			if not sound then
				report({
					code = "NON_FINITE_TRANSFORM",
					severity = "error",
					message = `A key of {track.path} holds a number that is not finite.`,
					joints = { track.joint },
					time = if isFinite(key.time) then milliseconds(key.time) else nil,
				})
			elseif key.time < 0 or key.time > Curves.MAX_TIME then
				report({
					code = "INVALID_KEYFRAME_TIME",
					severity = "error",
					message = `A key of {track.path} is at {key.time} seconds, outside 0 to {Curves.MAX_TIME}.`,
					joints = { track.joint },
					measured = key.time,
					threshold = Curves.MAX_TIME,
					unit = "seconds",
				})
			elseif track.channel:sub(1, 8) == "position" and math.abs(key.value) > Curves.MAX_POSITION then
				report({
					code = "POSITION_OUT_OF_RANGE",
					severity = "error",
					message = `A key of {track.path} is {rounded(key.value, 3)} studs from rest.`,
					joints = { track.joint },
					time = milliseconds(key.time),
					measured = rounded(math.abs(key.value), 3),
					threshold = Curves.MAX_POSITION,
					unit = "studs",
				})
			end
		end
	end

	-- Keys between frames are never shown as keyed.
	local offFrame, firstOff = 0, nil :: number?
	for _, track in Curves.tracks(clip) do
		for _, key in Curves.keys(track.curve) do
			local frames = key.time * Curves.FRAME_RATE
			if math.abs(frames - math.round(frames)) * 1000 / Curves.FRAME_RATE > Curves.TIME_TOLERANCE then
				offFrame += 1
				firstOff = firstOff or key.time
			end
		end
	end
	if offFrame > 0 then
		report({
			code = "KEY_OFF_FRAME",
			severity = "warning",
			message = `{offFrame} keys are between frames, the first at {milliseconds(firstOff :: number)} seconds. Studio plays a curve clip at {Curves.FRAME_RATE} frames a second and goes straight from frame to frame, so these keys are never shown as keyed and sharp moves through them are softened. Put keys on whole frames: multiples of 1/{Curves.FRAME_RATE} of a second.`,
			measured = offFrame,
			unit = "keys",
		})
	end

	-- Speed and the loop are measured on the motion itself, at 60 moments a second.
	local steps = math.max(1, math.ceil(duration * 60))
	for joint in byJoint do
		if nonKinematic and nonKinematic[joint] then
			report({
				code = "NON_KINEMATIC_JOINT",
				severity = "warning",
				message = `"{joint}" is driven through forces (IsKinematic is off), so what is rendered can differ from the clip.`,
				joints = { joint },
			})
		end
		if duration <= 0 then
			continue
		end
		local fastest, at = 0, 0
		local previous = rotationAt(clip, joint, 0)
		for step = 1, steps do
			local time = duration * step / steps
			local now = rotationAt(clip, joint, time)
			local speed = turn(previous, now) / (duration / steps)
			if speed > fastest then
				fastest, at = speed, time
			end
			previous = now
		end
		if fastest > thresholds.speed_degrees_per_second then
			report({
				code = "ABRUPT_ROTATION",
				severity = "warning",
				message = `"{joint}" turns at {rounded(fastest, 1)} degrees per second around {milliseconds(at)} seconds.`,
				joints = { joint },
				time = milliseconds(at),
				measured = rounded(fastest, 1),
				threshold = thresholds.speed_degrees_per_second,
				unit = "degrees per second",
			})
		end
		if (clip :: any).Loop == true then
			local gap = turn(rotationAt(clip, joint, 0), rotationAt(clip, joint, duration))
			if gap > thresholds.loop_rotation_degrees then
				report({
					code = "LOOP_ROTATION_MISMATCH",
					severity = "warning",
					message = `"{joint}" ends {rounded(gap, 3)} degrees from where it starts, so the loop will jump.`,
					joints = { joint },
					time_from = 0,
					time_to = milliseconds(duration),
					measured = rounded(gap, 3),
					threshold = thresholds.loop_rotation_degrees,
					unit = "degrees",
				})
			end
		end
	end

	contacts(clip, joints, thresholds, report)
end

return Curves
