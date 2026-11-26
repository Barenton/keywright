--!strict
-- Keys themselves: setting, removing and shaping them, clearing a range, copying a pose.

local Frames = require("./Frames")
local Body = require("./Body")
local Need = require("./Need")
local Rig = require("../../Rigs/Rig")
local Store = require("./Store")
local Write = require("./Write")

local asymmetry = Body.asymmetry
local count = Frames.count
local counterpart = Body.counterpart
local hasGeometry = Body.hasGeometry
local isFinite = Need.isFinite
local MIRROR_SIGN = Body.MIRROR_SIGN
local near = Frames.near
local needJoint = Need.needJoint
local needJoints = Need.needJoints
local needOneOf = Need.needOneOf
local needRange = Need.needRange
local needTime = Need.needTime
local needVector = Need.needVector
local outward = Store.outward
local putKey = Write.putKey
local readChannels = Frames.readChannels
local refuse = Need.refuse
local smoothChannel = Write.smoothChannel

type Changed = Frames.Changed
type Context = Frames.Context
type Key = Store.Key

local Ops = {}

Ops.set_key = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needJoint(where, operation.joint, joints)
		needTime(where, operation.time, "time")
		needVector(where, operation.rotation, "rotation")
		needVector(where, operation.position, "position", Store.MAX_POSITION)
		if operation.rotation == nil and operation.position == nil then
			refuse(where, "give rotation, position or both.")
		end
		if operation.interpolation ~= nil then
			needOneOf(where, operation.interpolation, "interpolation", Store.INTERPOLATIONS)
		end
	end,

	apply = function(_where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local mode = operation.interpolation
		for axis, letter in { "x", "y", "z" } do
			if operation.rotation then
				local curve = Store.channel(clip, operation.joint, `rotation.{letter}`, true) :: Instance
				putKey(curve, operation.time, math.rad(operation.rotation[axis]), mode, changed)
			end
			if operation.position then
				local curve = Store.channel(clip, operation.joint, `position.{letter}`, true) :: Instance
				putKey(curve, operation.time, operation.position[axis], mode, changed)
			end
		end
	end,
}

Ops.remove_key = {
	check = function(where: string, operation: any, joints: { [string]: any })
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

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local kinds = operation.channels or { "rotation", "position" }
		local removed = 0
		for _, kind in kinds do
			for _, letter in { "x", "y", "z" } do
				local curve = Store.channel(clip, operation.joint, `{kind}.{letter}`, false)
				if curve then
					local keys = Store.keys(curve)
					local kept = {}
					for _, key in keys do
						if near(key.time, operation.time) then
							removed += 1
						else
							table.insert(kept, key)
						end
					end
					if #kept ~= #keys then
						Store.setKeys(curve, kept)
					end
				end
			end
		end
		if removed == 0 then
			refuse(where, `"{operation.joint}" has no key at {operation.time} seconds.`)
		end
		count(changed, "keys_removed", removed)
	end,
}

Ops.set_tangent = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needJoint(where, operation.joint, joints)
		needTime(where, operation.time, "time")
		needOneOf(where, operation.channel, "channel", Store.CHANNELS)
		if operation["in"] == nil and operation.out == nil then
			refuse(where, "give in, out or both.")
		end
		for _, field in { "in", "out" } do
			if operation[field] ~= nil and not isFinite(operation[field]) then
				refuse(where, `{field} must be a finite number.`)
			end
		end
	end,

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local curve = Store.channel(clip, operation.joint, operation.channel, false)
		local keys: { Key } = if curve then Store.keys(curve) else {}
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
				Store.setKeys(curve :: Instance, keys)
				count(changed, "tangents_set")
				return
			end
		end
		refuse(where, `"{operation.joint}" has no {operation.channel} key at {operation.time} seconds.`)
	end,
}

Ops.auto_tangents = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needRange(where, operation)
		needJoints(where, operation.joints, joints)
		if operation.snap_at ~= nil then
			if type(operation.snap_at) ~= "table" or #operation.snap_at > Store.MAX_SNAPS then
				refuse(where, `snap_at must list at most {Store.MAX_SNAPS} times.`)
			end
			for _, time in operation.snap_at do
				needTime(where, time, "each time in snap_at")
			end
		end
		if operation.loop ~= nil and type(operation.loop) ~= "boolean" then
			refuse(where, "loop must be true or false.")
		end
	end,

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local wanted: { [string]: boolean }? = nil
		if operation.joints then
			wanted = {}
			for _, name in operation.joints do
				(wanted :: { [string]: boolean })[name] = true
			end
		end
		local duration = Store.duration(clip)
		local whole = near(operation.time_from, 0) and near(operation.time_to, duration)
		local loop = if operation.loop ~= nil then operation.loop else ((clip :: any).Loop == true and whole)
		local written = 0
		for _, track in Store.tracks(clip) do
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
}

Ops.clear_keys = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needRange(where, operation)
		needJoints(where, operation.joints, joints)
		if operation.channels ~= nil then
			if type(operation.channels) ~= "table" or #operation.channels == 0 then
				refuse(where, "channels must list at least one of rotation, position.")
			end
			for _, name in operation.channels do
				needOneOf(where, name, "each of channels", { "rotation", "position" })
			end
		end
	end,

	apply = function(_where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local wanted: { [string]: boolean }? = nil
		if operation.joints then
			wanted = {}
			for _, name in operation.joints do
				(wanted :: { [string]: boolean })[name] = true
			end
		end
		local kinds = {}
		for _, kind in operation.channels or { "rotation", "position" } do
			kinds[kind] = true
		end
		local from, to = operation.time_from, operation.time_to
		local removed = 0
		for _, track in Store.tracks(clip) do
			local kind = string.match(track.channel, "^(%a+)%.")
			if (wanted and not wanted[track.joint]) or not kinds[kind] then
				continue
			end
			local keys = Store.keys(track.curve)
			local kept = {}
			for _, key in keys do
				if key.time >= from - Store.TIME_TOLERANCE and key.time <= to + Store.TIME_TOLERANCE then
					removed += 1
				else
					table.insert(kept, key)
				end
			end
			if #kept ~= #keys then
				Store.setKeys(track.curve, kept)
			end
		end
		count(changed, "keys_removed", removed)
	end,
}

Ops.copy_pose = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needTime(where, operation.from, "from")
		needTime(where, operation.to, "to")
		needJoints(where, operation.joints, joints)
		if
			operation.from_clip ~= nil
			and (type(operation.from_clip) ~= "string" or #operation.from_clip == 0 or #operation.from_clip > 120)
		then
			refuse(where, "from_clip must name a clip.")
		end
		if operation.mirror ~= nil and type(operation.mirror) ~= "boolean" then
			refuse(where, "mirror must be true or false.")
		end
		if operation.channels ~= nil then
			if type(operation.channels) ~= "table" or #operation.channels == 0 then
				refuse(where, "channels must list at least one of rotation, position.")
			end
			for _, name in operation.channels do
				needOneOf(where, name, "each of channels", { "rotation", "position" })
			end
		end
	end,

	apply = function(where: string, clip: Instance, operation: any, context: Context, changed: Changed)
		local joints = context.joints
		local mirrored = operation.mirror == true
		if mirrored then
			if not hasGeometry(joints, Rig.R15_ORDER) then
				refuse(where, "this rig's joints could not be measured, so a pose cannot be mirrored on it.")
			end
			local problem = asymmetry(joints)
			if problem then
				refuse(
					where,
					`this rig's sides are not mirror images, so a mirrored pose would not be exact: {problem}`
				)
			end
		end
		local kinds = {}
		for _, kind in operation.channels or { "rotation", "position" } do
			kinds[kind] = true
		end
		local names: { string } = operation.joints or Rig.R15_ORDER
		-- The pose comes from this clip, or from another of the same rig: the guard of a
		-- ready pose carried into an attack, say. The other clip is only read.
		local origin = clip
		if operation.from_clip ~= nil then
			local found = context.clips and context.clips[operation.from_clip]
			if not found then
				refuse(where, `the clip "{operation.from_clip}" to copy the pose from was not found.`)
			end
			origin = found :: Instance
			-- A keyframe clip comes as its pose sampled at `from`, its length checked already.
			local length = Store.duration(origin)
			if origin:GetAttribute(Store.SAMPLED) ~= true and operation.from > length + Store.TIME_TOLERANCE then
				refuse(where, `the clip to copy from ends at {Need.milliseconds(length)} seconds, before from.`)
			end
		end
		-- Everything is read before anything is written, so a mirrored pose copied onto
		-- the time it came from swaps the sides instead of copying one onto itself.
		local channels = readChannels(origin)
		-- Which channels this clip animates: a channel it animates that the other clip
		-- leaves at rest is keyed to rest, so no part of the old pose is left behind.
		local own = if origin == clip then channels else readChannels(clip)
		local plan: { { joint: string, channel: string, value: number } } = {}
		for _, joint in names do
			local source = if mirrored then counterpart(joint) else joint
			for _, channel in Store.CHANNELS do
				if not kinds[string.match(channel, "^(%a+)%.") :: string] then
					continue
				end
				local from = channels[source] and channels[source][channel]
				local to = own[joint] and own[joint][channel]
				if (from == nil or #from == 0) and (to == nil or #to == 0) then
					-- Neither moves on this channel: it is at rest at both times already.
					continue
				end
				local value = if from then Store.evaluate(from, operation.from) else 0
				if mirrored then
					value *= MIRROR_SIGN[channel]
				end
				table.insert(plan, { joint = joint, channel = channel, value = value })
			end
		end
		if #plan == 0 then
			refuse(where, "none of these joints is keyed, so there is no pose to copy.")
		end
		for _, entry in plan do
			putKey(
				Store.channel(clip, entry.joint, entry.channel, true) :: Instance,
				operation.to,
				entry.value,
				nil,
				changed
			)
		end
		count(changed, "poses_copied")
	end,
}

return Ops
