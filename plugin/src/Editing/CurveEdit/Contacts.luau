--!strict
-- Checks of a curve clip: the general ones, and contact with the floor at every frame.

local Frames = require("./Frames")
local Body = require("./Body")
local Need = require("./Need")
local Pose = require("../../Rigs/Pose")
local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")
local Store = require("./Store")

local floorOf = Body.floorOf
local hasGeometry = Body.hasGeometry
local isFinite = Need.isFinite
local milliseconds = Need.milliseconds
local NOT_FLOORED = Body.NOT_FLOORED
local readChannels = Frames.readChannels
local rounded = Need.rounded
local transformsAt = Frames.transformsAt

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

-- The position of a joint at a time, from its three position channels.
local function positionAt(clip: Instance, joint: string, time: number): Vector3
	local values = {}
	for index, letter in { "x", "y", "z" } do
		local curve = Store.channel(clip, joint, `position.{letter}`, false)
		values[index] = if curve then Store.evaluate(Store.keys(curve), time) else 0
	end
	return Roblox.Vector3.new(values[1], values[2], values[3])
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
-- second both coming into a frame and going out of it, it scuffs. A swing that skims the
-- floor moves at 5 to 10; a planted foot that creeps with the hips, under this, slides.
local TOUCH = 0.4
local SCUFF_SPEED = 3
-- In a looping clip, a floor whose soles step back slower than this, in studs a second,
-- is taken to stand still.
local MOVING_FLOOR = 0.5

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
	-- that creeps for three frames or more is sliding.
	--
	-- In a looping clip the floor itself may move: a walk or run is usually made on the
	-- spot, its planted feet moving back steadily under the body. How fast is measured from
	-- the clip, as the most common step of a sole on the floor, and a foot's motion is then
	-- judged against the floor's. Each frame is judged by itself, so a swing that skims the
	-- floor fast just before a plant is told from the plant.
	local touch = TOUCH * thresholds.floor_studs
	local looping = (clip :: any).Loop == true
	local count = frames + 1
	local function touching(list: { any }, step: number): boolean
		-- No further above the floor than the touch, and no deeper into it than the floor
		-- limit; deeper is reported as below the floor instead.
		local height = list[step].lowest - floor
		return height <= touch and height >= -thresholds.floor_studs
	end
	-- The step a point of the sole takes from one frame to another, across the floor.
	local function stepOf(list: { any }, from: number, to: number, point: number): (number, number)
		local here, there = list[to].sole[point], list[from].sole[point]
		return here[1] - there[1], here[2] - there[2]
	end

	-- The floor's step each frame: in a looping clip, the middle of every step the soles
	-- take while they touch, across and along; still when that is slower than a creep.
	local floorX, floorZ = 0, 0
	if looping then
		local xs, zs = {}, {}
		for _, list in feet do
			for step = 2, count do
				if touching(list, step) and touching(list, step - 1) then
					for point = 1, 3 do
						local x, z = stepOf(list, step - 1, step, point)
						table.insert(xs, x)
						table.insert(zs, z)
					end
				end
			end
		end
		if #xs > 0 then
			table.sort(xs)
			table.sort(zs)
			local middle = (#xs + 1) // 2
			floorX, floorZ = xs[middle], zs[middle]
			if math.sqrt(floorX ^ 2 + floorZ ^ 2) * rate < MOVING_FLOOR then
				floorX, floorZ = 0, 0
			end
		end
	end
	local moving = floorX ~= 0 or floorZ ~= 0

	for _, foot in { "LeftFoot", "RightFoot" } do
		local list = feet[foot]
		-- How fast a foot moves across the floor between two frames, against the floor: as
		-- slow as the point of its sole that moves least, so a foot rolling over its toe or
		-- heel, which stays put, is not moving.
		local function slip(from: number, to: number): number
			local least = math.huge
			for point = 1, 3 do
				local x, z = stepOf(list, from, to, point)
				least = math.min(least, math.sqrt((x - floorX) ^ 2 + (z - floorZ) ^ 2))
			end
			return least * rate
		end
		-- The frames on either side of one; in a looping clip the last frame and the first
		-- are the same moment, so the clip carries on round.
		local function before(step: number): number?
			if step > 1 then
				return step - 1
			end
			return if looping and count > 2 then count - 1 else nil
		end
		local function after(step: number): number?
			if step < count then
				return step + 1
			end
			return if looping and count > 2 then 2 else nil
		end
		-- A frame scuffs when the foot touches and moves fast both coming into it and going
		-- out of it: a foot that lands, or lifts off, moves fast on one side only.
		local function scuffing(step: number): number?
			local speed = math.huge
			local into, out = before(step), after(step)
			if into then
				speed = math.min(speed, slip(into, step))
			end
			if out then
				speed = math.min(speed, slip(step, out))
			end
			return if speed ~= math.huge and speed > SCUFF_SPEED then speed else nil
		end
		local function times(index: number, finish: number): (number, number)
			return (index - 1) / rate, (finish - 1) / rate
		end

		local index = 1
		while index <= count do
			if not touching(list, index) then
				index += 1
				continue
			end
			local finish = index
			while finish + 1 <= count and touching(list, finish + 1) do
				finish += 1
			end
			-- Each run of scuffing frames in the stretch is reported on its own.
			local scuffed = false
			local step = index
			while step <= finish do
				local speed = scuffing(step)
				if not speed then
					step += 1
					continue
				end
				local first, fastest, nearest = step, speed, list[step].lowest - floor
				while step + 1 <= finish do
					local next = scuffing(step + 1)
					if not next then
						break
					end
					step += 1
					fastest = math.max(fastest, next)
					nearest = math.min(nearest, list[step].lowest - floor)
				end
				scuffed = true
				local from, to = times(first, step)
				local against = if moving
					then ` against the floor, which moves {rounded(math.sqrt(floorX ^ 2 + floorZ ^ 2) * rate, 2)} studs a second in this cycle made on the spot`
					else ""
				report({
					code = "FOOT_SCUFF",
					severity = "warning",
					message = `"{foot}" touches the floor from {milliseconds(from)} to {milliseconds(to)} seconds while moving up to {rounded(
						fastest,
						2
					)} studs a second across it{against}, coming within {rounded(nearest, 3)} studs of it: a swinging foot that drags, or a planted one that skates. Lift a swing with clear_floor; plant a foot with pin.`,
					joints = { foot },
					time_from = milliseconds(from),
					time_to = milliseconds(to),
					measured = rounded(fastest, 2),
					threshold = SCUFF_SPEED,
					unit = "studs per second",
				})
				step += 1
			end
			if not scuffed and finish - index >= 2 then
				-- How far it slides against the floor: as far as the point of its sole that
				-- moves least, so a foot rolling over its toe or heel is not sliding.
				local drift = math.huge
				for point = 1, 3 do
					local start = list[index].sole[point]
					local furthest = 0
					for frame = index, finish do
						local here = list[frame].sole[point]
						local carried = frame - index
						local x = here[1] - start[1] - floorX * carried
						local z = here[2] - start[2] - floorZ * carried
						furthest = math.max(furthest, math.sqrt(x ^ 2 + z ^ 2))
					end
					drift = math.min(drift, furthest)
				end
				if drift > thresholds.slide_studs then
					local from, to = times(index, finish)
					report({
						code = "FOOT_SLIDE",
						severity = "warning",
						message = `"{foot}" is on the floor from {milliseconds(from)} to {milliseconds(to)} seconds but slides {rounded(
							drift,
							3
						)} studs along it{if moving
							then " against the floor of this cycle made on the spot"
							else ""}. Pin it with the pin operation to keep it in place.`,
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
		local quickest, movedAt = 0, 0
		local previous = rotationAt(clip, joint, 0)
		local was = positionAt(clip, joint, 0)
		for step = 1, steps do
			local time = duration * step / steps
			local now = rotationAt(clip, joint, time)
			local speed = turn(previous, now) / (duration / steps)
			if speed > fastest then
				fastest, at = speed, time
			end
			previous = now
			local here = positionAt(clip, joint, time)
			local moving = (here - was).Magnitude / (duration / steps)
			if moving > quickest then
				quickest, movedAt = moving, time
			end
			was = here
		end
		if quickest > thresholds.speed_studs_per_second then
			report({
				code = "ABRUPT_MOVE",
				severity = "warning",
				message = `"{joint}" moves at {rounded(quickest, 2)} studs per second around {milliseconds(movedAt)} seconds.`,
				joints = { joint },
				time = milliseconds(movedAt),
				measured = rounded(quickest, 2),
				threshold = thresholds.speed_studs_per_second,
				unit = "studs per second",
			})
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
			local shift = (positionAt(clip, joint, 0) - positionAt(clip, joint, duration)).Magnitude
			if shift > thresholds.loop_position_studs then
				report({
					code = "LOOP_POSITION_MISMATCH",
					severity = "warning",
					message = `"{joint}" ends {rounded(shift, 3)} studs from where it starts, so the loop will jump.`,
					joints = { joint },
					time_from = 0,
					time_to = milliseconds(duration),
					measured = rounded(shift, 3),
					threshold = thresholds.loop_position_studs,
					unit = "studs",
				})
			end
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
