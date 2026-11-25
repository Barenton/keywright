--!strict
-- Mirroring motion across the rig's middle, or copying one side onto the other.

local Body = require("./Body")
local Need = require("./Need")
local Rig = require("../../Rigs/Rig")
local Store = require("./Store")
local Write = require("./Write")

local asymmetry = Body.asymmetry
local count = Write.count
local counterpart = Body.counterpart
local hasGeometry = Body.hasGeometry
local isFinite = Need.isFinite
local MIRROR_SIGN = Body.MIRROR_SIGN
local needJoints = Need.needJoints
local needOneOf = Need.needOneOf
local readChannels = Write.readChannels
local refuse = Need.refuse
local wrapped = Write.wrapped

type Changed = Write.Changed
type Context = Write.Context
type Key = Store.Key

local Ops = {}

Ops.mirror = {
	check = function(where: string, operation: any, joints: { [string]: any })
		needOneOf(where, operation.mode, "mode", Store.MIRROR_MODES)
		needJoints(where, operation.joints, joints)
		if operation.offset ~= nil then
			if not isFinite(operation.offset) or math.abs(operation.offset) > Store.MAX_TIME then
				refuse(where, "offset must be a number of seconds.")
			end
			if operation.mode == "flip" and operation.offset ~= 0 then
				refuse(where, "offset is for copying one side onto the other, not for flip.")
			end
		end
	end,

	apply = function(where: string, clip: Instance, operation: any, context: Context, changed: Changed)
		local joints = context.joints
		if not hasGeometry(joints, Rig.R15_ORDER) then
			refuse(where, "this rig's joints could not be measured, so it cannot be mirrored.")
		end
		local problem = asymmetry(joints)
		if problem then
			refuse(where, `this rig's sides are not mirror images, so a mirror would not be exact: {problem}`)
		end
		local offset = operation.offset or 0
		local duration = Store.duration(clip)
		if offset ~= 0 and not (clip :: any).Loop then
			refuse(where, "an offset carries motion round from the end to the start, so it needs a looping clip.")
		end
		local mode = operation.mode
		local only: { [string]: boolean }? = nil
		if operation.joints then
			only = {}
			for _, name in operation.joints do
				(only :: { [string]: boolean })[name] = true
				(only :: { [string]: boolean })[counterpart(name)] = true
			end
		end
		-- Which joint each joint's new curves come from.
		local plan: { { to: string, from: string } } = {}
		for _, name in Rig.R15_ORDER do
			if only and not only[name] then
				continue
			end
			local other = counterpart(name)
			local side = string.sub(name, 1, 4) == "Left"
			if mode == "flip" then
				table.insert(plan, { to = name, from = other })
			elseif mode == "left_to_right" and side then
				table.insert(plan, { to = other, from = name })
			elseif mode == "right_to_left" and other ~= name and not side then
				table.insert(plan, { to = other, from = name })
			end
		end
		-- Everything is read before anything is written: in a flip, each side is read
		-- before it is replaced by the other.
		local channels = readChannels(clip)
		local written = {}
		for _, pair in plan do
			local own = channels[pair.from] or {}
			for _, channel in Store.CHANNELS do
				local source = own[channel]
				local target = Store.channel(clip, pair.to, channel, false)
				if not source or #source == 0 then
					-- The joint copied from does not move here, so neither does its mirror.
					if target and #Store.keys(target) > 0 then
						table.insert(written, { joint = pair.to, channel = channel, keys = {} })
					end
					continue
				end
				local sign = MIRROR_SIGN[channel]
				local keys: { Key } = {}
				for _, key in source do
					table.insert(keys, {
						time = key.time,
						value = key.value * sign,
						interpolation = key.interpolation,
						left = if key.left then key.left * sign else nil,
						right = if key.right then key.right * sign else nil,
					})
				end
				if offset ~= 0 then
					keys = wrapped(keys, offset, duration)
				end
				table.insert(written, { joint = pair.to, channel = channel, keys = keys })
			end
		end
		local total = 0
		for _, entry in written do
			Store.setKeys(Store.channel(clip, entry.joint, entry.channel, true) :: Instance, entry.keys)
			total += #entry.keys
		end
		count(changed, "keys_written", total)
		count(changed, "joints_mirrored", #plan)
	end,
}

return Ops
