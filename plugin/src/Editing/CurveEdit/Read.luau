--!strict
-- Reading a curve clip for the tools, and the lines its fingerprint is made from.

local Need = require("./Need")
local Store = require("./Store")

local currentBackend = Store.currentBackend
local milliseconds = Need.milliseconds
local outward = Store.outward
local rounded = Need.rounded

local Read = {}

export type ReadOptions = {
	joints: { string }?,
	timeFrom: number?,
	timeTo: number?,
	offset: number?,
	limit: number?,
	posesOnly: boolean?,
}

function Read.read(clip: Instance, options: ReadOptions): { [string]: any }
	local result: { [string]: any } = {}
	local tracks = Store.tracks(clip)
	local function within(time: number): boolean
		return not (
			(options.timeFrom and time < options.timeFrom - Store.TIME_TOLERANCE)
			or (options.timeTo and time > options.timeTo + Store.TIME_TOLERANCE)
		)
	end
	if not options.posesOnly then
		local animated: { [string]: boolean } = {}
		local keyCount = 0
		for _, track in tracks do
			local keys = Store.keys(track.curve)
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
		local allTimes = Store.keyTimes(clip)
		local matching = 0
		for _, time in allTimes do
			if within(time) then
				matching += 1
				if #times < Store.MAX_LISTED then
					table.insert(times, milliseconds(time))
				end
			end
		end
		local markers = {}
		for _, curve in Store.markerCurves(clip) do
			for _, marker in currentBackend().markers(curve) do
				if within(marker.time) and #markers < Store.MAX_LISTED then
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
		result.duration = milliseconds(Store.duration(clip))
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
		local limit = math.clamp(math.floor(options.limit or Store.DEFAULT_KEYS), 1, Store.MAX_PAGE)
		local page, total = {}, 0
		for _, joint: string in wanted :: { string } do
			for _, channel in Store.CHANNELS do
				local curve = Store.channel(clip, joint, channel, false)
				if curve then
					local scale = outward(channel)
					for _, key in Store.keys(curve) do
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
function Read.digestLines(clip: Instance): { string }
	local lines = { `loop|{tostring((clip :: any).Loop)}`, `priority|{tostring((clip :: any).Priority)}` }
	for _, track in Store.tracks(clip) do
		for _, key in Store.keys(track.curve) do
			table.insert(
				lines,
				`key|{track.path}|{nine(key.time)}|{nine(key.value)}|{key.interpolation}|{nine(key.left)}|{nine(
					key.right
				)}`
			)
		end
	end
	for _, curve in Store.markerCurves(clip) do
		for _, marker in currentBackend().markers(curve) do
			table.insert(lines, `marker|{curve.Name}|{nine(marker.time)}|{marker.value}`)
		end
	end
	table.sort(lines)
	return lines
end

return Read
