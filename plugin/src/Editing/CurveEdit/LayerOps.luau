--!strict
-- Adding a turn, a move or a sway on top of a clip's motion.

local Frames = require("./Frames")
local Need = require("./Need")
local Store = require("./Store")
local Write = require("./Write")

local addToChannel = Write.addToChannel
local count = Frames.count
local isFinite = Need.isFinite
local near = Frames.near
local needBlends = Need.needBlends
local needJoint = Need.needJoint
local needJoints = Need.needJoints
local needRange = Need.needRange
local needVector = Need.needVector
local refuse = Need.refuse
local spanOf = Frames.spanOf

type Changed = Frames.Changed
type Context = Frames.Context

local Ops = {}

-- A smooth sway of size about 1, the same for the same seed: three waves, each twice as
-- fast as the one before and half as large, at chance phases. With `period`, every wave
-- fits a whole number of times into it, so the sway comes back round to where it began.
local function sway(seed: number, frequency: number, period: number?): (time: number) -> number
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	local function chance(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
	local waves = {}
	for octave = 0, 2 do
		local speed = frequency * 2 ^ octave * (0.85 + 0.3 * chance())
		if period then
			speed = math.max(1, math.round(speed * period)) / period
		end
		table.insert(waves, { speed = speed, phase = chance() * 2 * math.pi, size = 0.5 ^ octave })
	end
	return function(time: number): number
		local total = 0
		for _, wave in waves do
			total += wave.size * math.sin(2 * math.pi * wave.speed * time + wave.phase)
		end
		return total / 1.75
	end
end

-- A number from a joint's and a channel's names, so each gets its own sway from one seed.
local function nameSeed(text: string): number
	local hash = 5381
	for index = 1, #text do
		hash = (hash * 33 + string.byte(text, index)) % 2147483647
	end
	return hash
end

Ops.add_offset = {
	-- Its range may run across a looping clip's end (see Seam).
	wraps = true,

	check = function(where: string, operation: any, joints: { [string]: any })
		needJoint(where, operation.joint, joints)
		needRange(where, operation, true)
		needVector(where, operation.rotation, "rotation")
		needVector(where, operation.position, "position", Store.MAX_POSITION)
		if operation.rotation == nil and operation.position == nil then
			refuse(where, "give rotation, position or both.")
		end
		needBlends(where, operation)
	end,

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local span = spanOf(where, clip, operation)
		for axis, letter in { "x", "y", "z" } do
			if operation.rotation and operation.rotation[axis] ~= 0 then
				local size = math.rad(operation.rotation[axis])
				addToChannel(clip, operation.joint, `rotation.{letter}`, span, function(time)
					return size * span.weight(time)
				end, changed)
			end
			if operation.position and operation.position[axis] ~= 0 then
				local size = operation.position[axis]
				addToChannel(clip, operation.joint, `position.{letter}`, span, function(time)
					return size * span.weight(time)
				end, changed)
			end
		end
		count(changed, "frames_offset", span.last - span.first + 1)
	end,
}

Ops.add_noise = {
	-- Its range may run across a looping clip's end (see Seam).
	wraps = true,

	check = function(where: string, operation: any, joints: { [string]: any })
		needRange(where, operation, true)
		if type(operation.joints) ~= "table" or #operation.joints == 0 then
			refuse(where, "joints must name at least one joint.")
		end
		needJoints(where, operation.joints, joints)
		local degrees, studs = operation.rotation_degrees or 0, operation.position_studs or 0
		if not isFinite(degrees) or degrees < 0 or degrees > Store.MAX_NOISE_DEGREES then
			refuse(where, `rotation_degrees must be from 0 to {Store.MAX_NOISE_DEGREES}.`)
		end
		if not isFinite(studs) or studs < 0 or studs > Store.MAX_NOISE_STUDS then
			refuse(where, `position_studs must be from 0 to {Store.MAX_NOISE_STUDS}.`)
		end
		if degrees == 0 and studs == 0 then
			refuse(where, "give rotation_degrees, position_studs or both.")
		end
		local frequency = operation.frequency or 1
		if not isFinite(frequency) or frequency < Store.MIN_FREQUENCY or frequency > Store.MAX_FREQUENCY then
			refuse(where, `frequency must be from {Store.MIN_FREQUENCY} to {Store.MAX_FREQUENCY} waves a second.`)
		end
		if operation.seed ~= nil and (not isFinite(operation.seed) or operation.seed ~= math.floor(operation.seed)) then
			refuse(where, "seed must be a whole number.")
		end
		needBlends(where, operation)
	end,

	apply = function(where: string, clip: Instance, operation: any, _context: Context, changed: Changed)
		local span = spanOf(where, clip, operation)
		local duration = Store.duration(clip)
		-- Over a whole looping clip, the sway comes back round to where it began.
		local whole = near(operation.time_from, 0) and near(operation.time_to, duration)
		local period = if (clip :: any).Loop == true and whole then duration else nil
		local seed = operation.seed or 1
		local frequency = operation.frequency or 1
		local degrees = math.rad(operation.rotation_degrees or 0)
		local studs = operation.position_studs or 0
		for _, joint in operation.joints do
			for _, channel in Store.CHANNELS do
				local size = if string.sub(channel, 1, 8) == "rotation" then degrees else studs
				if size > 0 then
					local wave = sway(seed * 7919 + nameSeed(joint .. channel), frequency, period)
					addToChannel(clip, joint, channel, span, function(time)
						return size * wave(time) * span.weight(time)
					end, changed)
				end
			end
		end
		count(changed, "frames_with_noise", span.last - span.first + 1)
	end,
}

return Ops
