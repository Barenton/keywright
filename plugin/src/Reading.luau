--!strict
-- What a read of a clip returns: a summary, and on request the poses of chosen joints.
--
-- Everything here only reads the KeyframeSequence it is given. A clip can be large, so
-- nothing is returned without a bound: the lists in the summary stop at a fixed length
-- and say so, and poses come a page at a time.

local Operations = require("./Operations")
local Rig = require("./Rig")

local Reading = {}

-- Most keyframe times, and most markers, listed in one summary.
Reading.MAX_LISTED = 500
-- Poses in one page when the caller does not say, and the most it may ask for.
Reading.DEFAULT_POSES = 400
Reading.MAX_POSES = 20000
Reading.MAX_JOINTS = 32

export type Options = {
	joints: { string }?,
	timeFrom: number?,
	timeTo: number?,
	-- Poses to skip, and how many to return after them.
	offset: number?,
	limit: number?,
	-- Rotations as quaternions (x, y, z, w) instead of Euler angles.
	quaternion: boolean?,
	-- Leave the summary out: for the later pages of a read.
	posesOnly: boolean?,
}

local function milliseconds(time: number): number
	return math.round(time * 1000) / 1000
end

local function within(time: number, from: number?, to: number?): boolean
	return not ((from and time < from - Operations.TIME_TOLERANCE) or (to and time > to + Operations.TIME_TOLERANCE))
end

-- The summary of a clip. A time range, if given, narrows the lists of keyframe times and
-- markers; the counts and the duration are always of the whole clip.
function Reading.summary(sequence: Instance, options: Options): { [string]: any }
	local clip = sequence :: any
	local keyframes = Operations.keyframes(sequence)
	local times: { number } = {}
	local markers: { any } = {}
	local animated: { [string]: boolean } = {}
	local other: { [string]: number } = {}
	local matching, markerCount = 0, 0

	local function note(instance: Instance)
		other[instance.ClassName] = (other[instance.ClassName] or 0) + 1
	end
	for _, child in sequence:GetChildren() do
		if not child:IsA("Keyframe") then
			note(child)
			for _, descendant in child:GetDescendants() do
				note(descendant)
			end
		end
	end
	for _, keyframe in keyframes do
		local listed = within(keyframe.Time, options.timeFrom, options.timeTo)
		if listed then
			matching += 1
			if #times < Reading.MAX_LISTED then
				table.insert(times, milliseconds(keyframe.Time))
			end
		end
		for _, descendant: any in keyframe:GetDescendants() do
			if descendant:IsA("Pose") then
				if descendant.Weight > 0 then
					animated[descendant.Name] = true
				end
			elseif descendant:IsA("KeyframeMarker") then
				if listed then
					markerCount += 1
					if #markers < Reading.MAX_LISTED then
						table.insert(
							markers,
							{ name = descendant.Name, value = descendant.Value, time = milliseconds(keyframe.Time) }
						)
					end
				end
			else
				note(descendant)
			end
		end
	end

	local animatedList = {}
	for name in animated do
		table.insert(animatedList, name)
	end
	table.sort(animatedList)

	local summary: { [string]: any } = {
		name = clip.Name,
		loop = clip.Loop,
		priority = clip.Priority.Name,
		duration = if #keyframes > 0 then milliseconds(keyframes[#keyframes].Time) else 0,
		keyframe_count = #keyframes,
		keyframe_times = times,
		animated_joints = animatedList,
		markers = markers,
	}
	if matching > #times then
		summary.keyframe_times_truncated = true
	end
	if markerCount > #markers then
		summary.markers_truncated = true
	end
	if next(other) ~= nil then
		-- Content no edit touches: kept as it is, and reported so that it is not a surprise.
		local list = {}
		for class, found in other do
			table.insert(list, { class = class, count = found })
		end
		table.sort(list, function(a, b)
			return a.class < b.class
		end)
		summary.other_content = list
	end
	return summary
end

-- One page of the poses of the joints asked for, in keyframe order and then in the order
-- the joints were given. Returns the page and how many poses there are in all.
function Reading.poses(sequence: Instance, options: Options): ({ any }, number)
	local joints: { string } = options.joints or {}
	local offset = math.max(0, math.floor(options.offset or 0))
	local limit = math.clamp(math.floor(options.limit or Reading.DEFAULT_POSES), 1, Reading.MAX_POSES)
	local page: { any } = {}
	local total = 0
	for _, keyframe in Operations.keyframes(sequence) do
		if not within(keyframe.Time, options.timeFrom, options.timeTo) then
			continue
		end
		for _, joint in joints do
			local pose = Operations.findPose(keyframe, joint)
			if not pose or pose.Weight <= 0 then
				continue
			end
			total += 1
			if total <= offset or #page >= limit then
				continue
			end
			local encoded = Rig.encode(pose.CFrame)
			local entry: { [string]: any } = {
				joint = joint,
				time = milliseconds(keyframe.Time),
				position = encoded.position,
				easing_style = pose.EasingStyle.Name,
				easing_direction = pose.EasingDirection.Name,
			}
			if options.quaternion then
				entry.quaternion = Rig.quaternion(pose.CFrame)
			else
				entry.rotation = encoded.rotation
			end
			table.insert(page, entry)
		end
	end
	return page, total
end

-- A whole read: the summary unless it was left out, and a page of poses if any joints
-- were asked for. `next_offset` is present when there are more poses to fetch.
function Reading.read(sequence: Instance, options: Options): { [string]: any }
	local result: { [string]: any } = if options.posesOnly then {} else Reading.summary(sequence, options)
	if options.joints and #options.joints > 0 then
		local page, total = Reading.poses(sequence, options)
		local offset = math.max(0, math.floor(options.offset or 0))
		result.poses = page
		result.poses_total = total
		if offset + #page < total then
			result.next_offset = offset + #page
		end
	end
	return result
end

return Reading
