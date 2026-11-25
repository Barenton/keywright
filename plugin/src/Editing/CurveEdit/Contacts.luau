--!strict
-- Checks of a curve clip: the general ones, and contact with the floor at every frame.

local Body = require("./Body")
local Need = require("./Need")
local Pose = require("../../Rigs/Pose")
local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")
local Store = require("./Store")
local Write = require("./Write")

local floorOf = Body.floorOf
local hasGeometry = Body.hasGeometry
local isFinite = Need.isFinite
local milliseconds = Need.milliseconds
local NOT_FLOORED = Body.NOT_FLOORED
local readChannels = Write.readChannels
local rounded = Need.rounded
local transformsAt = Write.transformsAt

local Contacts = {}

-- The rotation of a joint at a time, from its three rotation channels.
local function rotationAt(clip: Instance, joint: string, time: number): CFrame
	local angles = {}
	for index, letter in { "x", "y", "z" } do
		local curve = Store.channel(clip, joint, `rotation.{letter}`, false)
		angles[index] = if curve then Store.evaluate(Store.keys(curve), time) else 0
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

-- A foot touches the floor when its lowest point is within this share of the floor
-- limit of it; and moving faster than this across the floor while it touches, in studs a
-- second, it scuffs.
local TOUCH = 0.4
local SCUFF_SPEED = 1.5

local function contacts(
	clip: Instance,
	joints: { [string]: any },
	thresholds: { [string]: number },
	report: (issue: any) -> ()
)
	if not hasGeometry(joints, Rig.R15_ORDER) then
		return
	end
	local duration = Store.duration(clip)
	local rate = Store.FRAME_RATE
	local scan = { joints = joints } :: any
	local identity = Roblox.CFrame.new()
	local floor = floorOf(joints)
	local channels = readChannels(clip)
	local frames = math.floor(duration * rate + 1e-6)
	type Below = { deepest: number, at: number, first: number, last: number }
	local below: { [string]: Below } = {}
	local feet: { [string]: { any } } = { LeftFoot = {}, RightFoot = {} }
	for frame = 0, frames do
		local time = frame / rate
		local transforms = transformsAt(channels, time)
		local tracked = Pose.track(scan, transforms, identity, Rig.R15_ORDER)
		local placed = Pose.place(scan, transforms, identity)
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
			-- Where the toe, the heel and the middle of the sole are across the floor.
			local size = joints[foot].part1.Size
			local sole = {}
			for _, along in { -0.5, 0.5, 0 } do
				local point = placed[foot]:PointToWorldSpace(Roblox.Vector3.new(0, -size.Y / 2, along * size.Z))
				table.insert(sole, { point.X, point.Z })
			end
			list[frame + 1] = { lowest = tracked[foot].lowest, position = tracked[foot].position, sole = sole }
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

	-- A foot touches the floor while its lowest point is within a share of the floor limit
	-- of it (TOUCH): one passing a little above it, as a swing does, is not on it. While
	-- it touches, it should not move across the floor: a foot that moves fast while it
	-- touches is scuffing, as a swinging foot that drags or a planted one that skates; one
	-- that creeps for three frames or more is sliding. In a looping clip a foot that moves
	-- back steadily while it touches is a cycle made on the spot, as a walk or run usually
	-- is, and is neither.
	local touch = TOUCH * thresholds.floor_studs
	for _, foot in { "LeftFoot", "RightFoot" } do
		local list = feet[foot]
		-- How fast the middle of the foot moves across the floor at each frame.
		local speeds: { number } = {}
		for step = 1, #list do
			local before = list[math.max(step - 1, 1)].position
			local after = list[math.min(step + 1, #list)].position
			local apart = math.min(step + 1, #list) - math.max(step - 1, 1)
			speeds[step] = if apart > 0
				then math.sqrt((after[1] - before[1]) ^ 2 + (after[3] - before[3]) ^ 2) * rate / apart
				else 0
		end
		-- Touching: no further above the floor than the touch, and no deeper into it than
		-- the floor limit; deeper is reported as below the floor instead.
		local function touching(step: number): boolean
			local height = list[step].lowest - floor
			return height <= touch and height >= -thresholds.floor_studs
		end
		local index = 1
		while index <= #list do
			if not touching(index) then
				index += 1
				continue
			end
			local finish = index
			while finish + 1 <= #list and touching(finish + 1) do
				finish += 1
			end
			-- Each frame's step across the floor, at each point of the sole.
			local steps: { { number } } = {}
			for step = index + 1, finish do
				local each = {}
				for point = 1, 3 do
					local here, there = list[step].sole[point], list[step - 1].sole[point]
					each[point] = math.sqrt((here[1] - there[1]) ^ 2 + (here[2] - there[2]) ^ 2)
				end
				table.insert(steps, each)
			end
			-- Steady: at every frame some point of the sole moves back by about the same
			-- step, as the heel does while the foot rolls onto it and the toe while it
			-- rolls off.
			local steady = false
			if (clip :: any).Loop == true and #steps > 0 then
				local mean = 0
				for _, each in steps do
					mean += each[3] / #steps
				end
				steady = mean * rate > 0.5
				for _, each in steps do
					local close = false
					for point = 1, 3 do
						close = close or math.abs(each[point] - mean) <= 0.35 * mean
					end
					steady = steady and close
				end
			end
			local speed, nearest = 0, math.huge
			for step = index, finish do
				speed += speeds[step] / (finish - index + 1)
				nearest = math.min(nearest, list[step].lowest - floor)
			end
			local from, to = (index - 1) / rate, (finish - 1) / rate
			if not steady and speed > SCUFF_SPEED then
				report({
					code = "FOOT_SCUFF",
					severity = "warning",
					message = `"{foot}" touches the floor from {milliseconds(from)} to {milliseconds(to)} seconds while moving {rounded(
						speed,
						2
					)} studs a second across it, coming within {rounded(nearest, 3)} studs of it: a swinging foot that drags, or a planted one that skates. Lift a swing with clear_floor; plant a foot with pin.`,
					joints = { foot },
					time_from = milliseconds(from),
					time_to = milliseconds(to),
					measured = rounded(speed, 2),
					threshold = SCUFF_SPEED,
					unit = "studs per second",
				})
			elseif not steady and finish - index >= 2 then
				-- How far it slides: as far as the point of its sole that moves least, so a
				-- foot rolling over its toe or heel, which stays put, is not sliding.
				local drift = math.huge
				for point = 1, 3 do
					local start = list[index].sole[point]
					local furthest = 0
					for step = index, finish do
						local here = list[step].sole[point]
						furthest = math.max(furthest, math.sqrt((here[1] - start[1]) ^ 2 + (here[2] - start[2]) ^ 2))
					end
					drift = math.min(drift, furthest)
				end
				if drift > thresholds.slide_studs then
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
function Contacts.validate(
	clip: Instance,
	joints: { [string]: any },
	nonKinematic: { [string]: boolean }?,
	thresholds: { [string]: number },
	report: (issue: any) -> ()
)
	local duration = Store.duration(clip)
	local byJoint: { [string]: boolean } = {}
	for _, track in Store.tracks(clip) do
		local keys = Store.keys(track.curve)
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
		if #keys > Store.MAX_KEYS then
			report({
				code = "TOO_MANY_KEYS",
				severity = "error",
				message = `{track.path} has {#keys} keys; the most supported is {Store.MAX_KEYS}.`,
				joints = { track.joint },
				measured = #keys,
				threshold = Store.MAX_KEYS,
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
			elseif key.time < 0 or key.time > Store.MAX_TIME then
				report({
					code = "INVALID_KEYFRAME_TIME",
					severity = "error",
					message = `A key of {track.path} is at {key.time} seconds, outside 0 to {Store.MAX_TIME}.`,
					joints = { track.joint },
					measured = key.time,
					threshold = Store.MAX_TIME,
					unit = "seconds",
				})
			elseif track.channel:sub(1, 8) == "position" and math.abs(key.value) > Store.MAX_POSITION then
				report({
					code = "POSITION_OUT_OF_RANGE",
					severity = "error",
					message = `A key of {track.path} is {rounded(key.value, 3)} studs from rest.`,
					joints = { track.joint },
					time = milliseconds(key.time),
					measured = rounded(math.abs(key.value), 3),
					threshold = Store.MAX_POSITION,
					unit = "studs",
				})
			end
		end
	end

	-- Keys between frames are never shown as keyed.
	local offFrame, firstOff = 0, nil :: number?
	for _, track in Store.tracks(clip) do
		for _, key in Store.keys(track.curve) do
			local frames = key.time * Store.FRAME_RATE
			if math.abs(frames - math.round(frames)) * 1000 / Store.FRAME_RATE > Store.TIME_TOLERANCE then
				offFrame += 1
				firstOff = firstOff or key.time
			end
		end
	end
	if offFrame > 0 then
		report({
			code = "KEY_OFF_FRAME",
			severity = "warning",
			message = `{offFrame} keys are between frames, the first at {milliseconds(firstOff :: number)} seconds. Studio plays a curve clip at {Store.FRAME_RATE} frames a second and goes straight from frame to frame, so these keys are never shown as keyed and sharp moves through them are softened. Put keys on whole frames: multiples of 1/{Store.FRAME_RATE} of a second.`,
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

return Contacts
