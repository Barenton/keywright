--!strict
-- A smooth curve through a handful of keys.
--
-- Roblox eases each stretch of a clip by itself: from one pose to the next, by one of a
-- few fixed shapes. Every one of those shapes except the straight line comes to rest at
-- one end or both, so a move built from several eased stretches stops at each key and
-- starts again, and a move built from straight stretches turns a corner at each key.
-- Neither carries speed through a key.
--
-- This module does what animation packages do instead: it runs one curve through all of
-- a joint's keys, whose speed is continuous from one stretch to the next. A key the
-- motion passes on its way somewhere is passed at speed. A key where the motion turns
-- round is come to rest at, since it must be. The curve never goes beyond the keys on
-- either side of it, so nothing overshoots that was not keyed to.
--
-- The curve is worked out one number at a time: each coordinate of a position and each
-- of the four numbers of a quaternion is its own curve through its own keys. Nothing
-- here knows what the numbers mean. This is a cubic Hermite spline with tangents chosen
-- per key, the same idea as "auto clamped" handles in other tools.

local Smooth = {}

-- How much faster than its average a stretch is moving when it arrives at a key that is
-- to be struck, not eased into. Three is the most that never overshoots.
Smooth.SNAP = 2.5

export type Key = {
	time: number,
	values: { number },
}

export type Options = {
	-- Keys, by their place in the list, that the motion arrives at fast and stops dead
	-- on, as a fist does on what it hits.
	snap: { [number]: boolean }?,
	-- The last key leads straight back into the first, as in a clip that loops, so the
	-- speed there is carried across the join.
	loop: boolean?,
}

-- The speed, in one of the numbers, at which the curve arrives at and leaves each key.
function Smooth.tangents(keys: { Key }, channel: number, options: Options?): ({ number }, { number })
	local n = #keys
	local arriving, leaving = table.create(n, 0), table.create(n, 0)
	local function slope(index: number): number
		local a, b = keys[index], keys[index + 1]
		return (b.values[channel] - a.values[channel]) / (b.time - a.time)
	end
	-- Within twice the gentler of the two slopes beside it, a tangent cannot carry the
	-- curve past either neighbouring key.
	local function through(before: number, after: number, whole: number): number
		if before * after <= 0 then
			-- The motion turns round here, or rests: it comes to a stop.
			return 0
		end
		local limit = 2 * math.min(math.abs(before), math.abs(after))
		return math.clamp(whole, -limit, limit)
	end
	for index = 2, n - 1 do
		local whole = (keys[index + 1].values[channel] - keys[index - 1].values[channel])
			/ (keys[index + 1].time - keys[index - 1].time)
		local tangent = through(slope(index - 1), slope(index), whole)
		arriving[index], leaving[index] = tangent, tangent
	end
	if options and options.loop and n >= 3 then
		local whole = (keys[2].values[channel] - keys[n - 1].values[channel])
			/ ((keys[2].time - keys[1].time) + (keys[n].time - keys[n - 1].time))
		local tangent = through(slope(n - 1), slope(1), whole)
		leaving[1], arriving[n] = tangent, tangent
	end
	if options and options.snap then
		for index in options.snap do
			if index >= 2 and index <= n then
				local into = slope(index - 1)
				arriving[index] = Smooth.SNAP * into
				leaving[index] = 0
				-- The stretch that ends in a snap must not start so fast that it overshoots.
				local limit = 1.5 * math.abs(into)
				leaving[index - 1] = math.clamp(leaving[index - 1], -limit, limit)
			end
		end
	end
	return arriving, leaving
end

-- The curve's values at each of the times given, which must be in order and lie from
-- the first key's time to the last's.
function Smooth.sample(keys: { Key }, times: { number }, options: Options?): { { number } }
	local channels = #keys[1].values
	local arriving: { { number } }, leaving: { { number } } = {}, {}
	for channel = 1, channels do
		arriving[channel], leaving[channel] = Smooth.tangents(keys, channel, options)
	end
	local samples: { { number } } = table.create(#times)
	local segment = 1
	for index, time in times do
		while segment < #keys - 1 and time > keys[segment + 1].time do
			segment += 1
		end
		local a, b = keys[segment], keys[segment + 1]
		local length = b.time - a.time
		local u = math.clamp((time - a.time) / length, 0, 1)
		local u2, u3 = u * u, u * u * u
		local fromA, speedA = 2 * u3 - 3 * u2 + 1, (u3 - 2 * u2 + u) * length
		local fromB, speedB = -2 * u3 + 3 * u2, (u3 - u2) * length
		local values = table.create(channels)
		for channel = 1, channels do
			values[channel] = fromA * a.values[channel]
				+ speedA * leaving[channel][segment]
				+ fromB * b.values[channel]
				+ speedB * arriving[channel][segment + 1]
		end
		samples[index] = values
	end
	return samples
end

return Smooth
