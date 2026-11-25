--!strict
-- A curve clip at whole frames, as the operations that work frame by frame read it: the
-- channels read once, the pose at a time, ranges and their blends; and what an operation
-- is given and reports.

local Need = require("./Need")
local Roblox = require("../../Core/Roblox")
local Rig = require("../../Rigs/Rig")
local Store = require("./Store")

local milliseconds = Need.milliseconds
local refuse = Need.refuse

type Key = Store.Key

local Frames = {}

export type Context = { joints: { [string]: any }, source: Instance? }

export type Changed = { [string]: number }

local function count(changed: Changed, what: string, by: number?)
	changed[what] = (changed[what] or 0) + (by or 1)
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) < Store.TIME_TOLERANCE
end

-- The keys of every channel of a clip, read once, by joint and then by channel.
export type Channels = { [string]: { [string]: { Key } } }

local function readChannels(clip: Instance): Channels
	local channels: Channels = {}
	for _, track in Store.tracks(clip) do
		channels[track.joint] = channels[track.joint] or {}
		channels[track.joint][track.channel] = Store.keys(track.curve)
	end
	return channels
end

-- The transform of every joint of the rig at a time, as the channels give it.
local function transformsAt(channels: Channels, time: number): { [string]: CFrame }
	local transforms: { [string]: CFrame } = {}
	for _, joint in Rig.R15_ORDER do
		local values = {}
		local own = channels[joint]
		for index, channel in Store.CHANNELS do
			local keys = own and own[channel]
			values[index] = if keys then Store.evaluate(keys, time) else 0
		end
		transforms[joint] = Roblox.CFrame.new(values[1], values[2], values[3])
			* Roblox.CFrame.fromEulerAnglesXYZ(values[4], values[5], values[6])
	end
	return transforms
end

-- How far from a whole frame, in frames, a time may be and still count as that frame: a
-- millisecond, as for keys. A time written as 1.1333 is frame 34 (1.13333...).
local FRAME_SLACK = Store.TIME_TOLERANCE * Store.FRAME_RATE

-- Rounds a smooth step from 0 to 1 as `t` goes from 0 to 1.
local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- The whole frames an operation with a range and blends covers, and how much of it applies
-- at a time: 1 inside the range, easing from 0 over the blends.
export type Span = { first: number, last: number, weight: (time: number) -> number }

local function spanOf(where: string, clip: Instance, operation: any): Span
	local duration = Store.duration(clip)
	if operation.time_to > duration + Store.TIME_TOLERANCE then
		refuse(
			where,
			`the clip ends at {milliseconds(duration)} seconds, before time_to.`,
			"Key the clip out to its full length first."
		)
	end
	local from, to = operation.time_from, operation.time_to
	local first = math.max(0, from - (operation.blend_in or 0))
	local last = math.min(duration, to + (operation.blend_out or 0))
	local rate = Store.FRAME_RATE
	local firstFrame = math.ceil(first * rate - FRAME_SLACK)
	local lastFrame = math.floor(last * rate + FRAME_SLACK)
	if lastFrame < firstFrame then
		refuse(where, "the range holds no whole frame; Studio shows a curve clip only at whole frames.")
	end
	return {
		first = firstFrame,
		last = lastFrame,
		weight = function(time: number): number
			if time < from - Store.TIME_TOLERANCE then
				return smoothstep((time - first) / math.max(from - first, 1e-6))
			elseif time > to + Store.TIME_TOLERANCE then
				return smoothstep((last - time) / math.max(last - to, 1e-6))
			end
			return 1
		end,
	}
end

Frames.count = count
Frames.near = near
Frames.readChannels = readChannels
Frames.transformsAt = transformsAt
Frames.FRAME_SLACK = FRAME_SLACK
Frames.smoothstep = smoothstep
Frames.spanOf = spanOf

return Frames
