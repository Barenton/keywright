--!strict
-- The edits that can be made to a clip, each as an operation applied to a
-- KeyframeSequence.
--
-- Nothing here knows about working copies, revisions or undo; that is Edit's part. This
-- module only changes the instance tree it is handed, so that it can be run first on a
-- scratch copy (to find out whether a whole batch succeeds) and then on the real clip.
--
-- Three rules hold for every operation:
--   * It touches only the keyframes, poses and markers it names. Everything else in the
--     clip keeps its instances and its property values.
--   * Content this module does not understand (a NumberPose, a Folder, anything that is
--     not a Pose or a KeyframeMarker) is never changed or removed, except when the
--     keyframe that holds it is itself removed on request.
--   * Two keyframes closer together than a millisecond count as the same keyframe.

local Errors = require("../Core/Errors")
local Rig = require("../Rigs/Rig")
local Roblox = require("../Core/Roblox")
local Smooth = require("./Smooth")

local Operations = {}

Operations.MAX_OPERATIONS = 256
Operations.MAX_TIME = 300
Operations.MAX_POSITION = 1000
Operations.MAX_KEYFRAMES = 2000
Operations.MAX_NAME = 100
Operations.MAX_MARKER_VALUE = 200
Operations.MAX_HOLDS = 8
-- For smoothing: how many poses a second are written, and how many snaps one call takes.
Operations.MIN_RATE = 10
Operations.MAX_RATE = 60
Operations.DEFAULT_RATE = 30
Operations.MAX_SNAPS = 16
Operations.MAX_JOINTS = 32
Operations.MIN_SCALE = 0.01
Operations.MAX_SCALE = 100
Operations.TIME_TOLERANCE = 0.001

-- Easing styles an edit may write. "Cubic" is deprecated: it is kept where a clip
-- already has it, but never written.
Operations.EASING_STYLES = { "Linear", "Constant", "Elastic", "CubicV2", "Bounce" }
Operations.EASING_DIRECTIONS = { "In", "Out", "InOut" }
Operations.PRIORITIES = { "Idle", "Movement", "Action", "Action2", "Action3", "Action4", "Core" }

export type Context = {
	-- The rig's joints by the name of the driven part.
	joints: { [string]: any },
	-- The clip the working copy was opened from, if any.
	source: Instance?,
	-- For a keyframe that holds the pose the clip already has at its time: the pose of
	-- each animated joint there, by the operation's place in the batch. The engine works
	-- these out, not this module, so whoever runs the batch supplies them.
	held: { [number]: { [string]: CFrame } }?,
	-- Filled in while applying: for each such keyframe, what a caller should know.
	holds: { any }?,
}

export type Changed = { [string]: number }

-- ---------------------------------------------------------------------------------------
-- Reading a clip

function Operations.keyframes(sequence: Instance): { Keyframe }
	local keyframes = {}
	for _, child in sequence:GetChildren() do
		if child:IsA("Keyframe") then
			table.insert(keyframes, child)
		end
	end
	table.sort(keyframes, function(a, b)
		return a.Time < b.Time
	end)
	return keyframes
end

function Operations.findKeyframe(sequence: Instance, time: number): Keyframe?
	for _, child in sequence:GetChildren() do
		if child:IsA("Keyframe") and math.abs(child.Time - time) < Operations.TIME_TOLERANCE then
			return child
		end
	end
	return nil
end

function Operations.findPose(keyframe: Instance, joint: string): Pose?
	local found = keyframe:FindFirstChild(joint, true)
	if found and found:IsA("Pose") then
		return found
	end
	return nil
end

-- The pose for a joint in a keyframe, created along with any ancestors it needs. Poses
-- are nested the way the rig's parts are; an ancestor made only to hold the nesting has
-- no weight, so it does not move its joint.
function Operations.ensurePose(keyframe: Instance, joint: string): (Pose, boolean)
	local existing = Operations.findPose(keyframe, joint)
	if existing then
		return existing, false
	end
	local parent: Instance = keyframe
	local pose: Pose? = nil
	for _, name in Rig.chain(joint) do
		local child = parent:FindFirstChild(name)
		if not child or not child:IsA("Pose") then
			local created = Roblox.Instance.new("Pose")
			created.Name = name
			created.Weight = if name == joint then 1 else 0
			created.Parent = parent
			child = created
		end
		pose = child :: Pose
		parent = child :: Pose
	end
	return pose :: Pose, true
end

-- Makes one clip hold what another holds: its keyframes and everything in them, and its
-- loop and priority settings. The name is left alone. What `to` held is taken out, not
-- destroyed, so that an undo can put it back.
function Operations.copyContent(from: Instance, to: Instance)
	for _, child in to:GetChildren() do
		child.Parent = nil
	end
	for _, child in from:GetChildren() do
		child:Clone().Parent = to
	end
	(to :: any).Loop = (from :: any).Loop;
	(to :: any).Priority = (from :: any).Priority
end

-- ---------------------------------------------------------------------------------------
-- Checking what was asked for

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function isVector(value: any, limit: number?): boolean
	if type(value) ~= "table" or #value ~= 3 then
		return false
	end
	for index = 1, 3 do
		if not isFinite(value[index]) or (limit and math.abs(value[index]) > limit) then
			return false
		end
	end
	return true
end

local function refuse(where: string, message: string, hint: string?): never
	return Errors.throw("INVALID_ARGUMENT", `{where}: {message}`, hint)
end

local function needTime(where: string, value: any, field: string)
	if not isFinite(value) or value < 0 or value > Operations.MAX_TIME then
		refuse(where, `{field} must be from 0 to {Operations.MAX_TIME} seconds.`)
	end
end

local function needRange(where: string, operation: any)
	needTime(where, operation.time_from, "time_from")
	needTime(where, operation.time_to, "time_to")
	if operation.time_to < operation.time_from then
		refuse(where, "time_to must not be before time_from.")
	end
end

local function needJoint(where: string, operation: any, joints: { [string]: any })
	if type(operation.joint) ~= "string" or not joints[operation.joint] then
		refuse(where, `the rig has no joint "{tostring(operation.joint)}".`, "Call inspect_rig for the joint names.")
	end
end

local function needOffset(where: string, operation: any)
	if operation.position ~= nil and not isVector(operation.position, Operations.MAX_POSITION) then
		refuse(where, `position must be three finite numbers within {Operations.MAX_POSITION} studs.`)
	end
	if operation.rotation ~= nil and not isVector(operation.rotation) then
		refuse(where, "rotation must be three finite numbers in degrees.")
	end
	local quaternion = operation.quaternion
	if quaternion ~= nil then
		if operation.rotation ~= nil then
			refuse(where, "give rotation or quaternion, not both.")
		end
		local squares = 0
		for index = 1, 4 do
			if type(quaternion) ~= "table" or #quaternion ~= 4 or not isFinite(quaternion[index]) then
				refuse(where, "quaternion must be four finite numbers: x, y, z, w.")
			end
			squares += quaternion[index] ^ 2
		end
		if math.abs(math.sqrt(squares) - 1) > 0.01 then
			refuse(where, "quaternion must have a length of 1.")
		end
	end
	if operation.position == nil and operation.rotation == nil and quaternion == nil then
		refuse(where, "give position, a rotation, or both.")
	end
end

local function needText(where: string, value: any, field: string, limit: number, allowEmpty: boolean?)
	if type(value) ~= "string" or #value > limit or (not allowEmpty and #value == 0) then
		refuse(where, `{field} must be text of {if allowEmpty then "at most" else "1 to"} {limit} characters.`)
	end
end

local function needOneOf(where: string, value: any, field: string, allowed: { string }, hint: string?)
	if type(value) ~= "string" or not table.find(allowed, value) then
		refuse(where, `{field} must be one of {table.concat(allowed, ", ")}.`, hint)
	end
end

local function needEasing(where: string, operation: any, style: any, direction: any)
	if style ~= nil then
		needOneOf(
			where,
			style,
			"easing_style",
			Operations.EASING_STYLES,
			if style == "Cubic" then "Cubic is deprecated. Use CubicV2." else nil
		)
	end
	if direction ~= nil then
		needOneOf(where, direction, "easing_direction", Operations.EASING_DIRECTIONS)
	end
end

type Check = (where: string, operation: any, joints: { [string]: any }) -> ()

local checks: { [string]: Check } = {
	set_pose = function(where, operation, joints)
		needJoint(where, operation, joints)
		needTime(where, operation.time, "time")
		needOffset(where, operation)
		needEasing(where, operation, operation.easing_style, operation.easing_direction)
	end,
	remove_pose = function(where, operation, joints)
		needJoint(where, operation, joints)
		needTime(where, operation.time, "time")
	end,
	offset_pose = function(where, operation, joints)
		needJoint(where, operation, joints)
		needRange(where, operation)
		needOffset(where, operation)
	end,
	set_easing = function(where, operation, joints)
		needJoint(where, operation, joints)
		needRange(where, operation)
		if operation.easing_style == nil and operation.easing_direction == nil then
			refuse(where, "give easing_style, easing_direction or both.")
		end
		needEasing(where, operation, operation.easing_style, operation.easing_direction)
	end,
	add_keyframe = function(where, operation)
		needTime(where, operation.time, "time")
		if operation.hold ~= nil and type(operation.hold) ~= "boolean" then
			refuse(where, "hold must be true or false.")
		end
	end,
	remove_keyframe = function(where, operation)
		needTime(where, operation.time, "time")
	end,
	move_keyframe = function(where, operation)
		needTime(where, operation.time, "time")
		needTime(where, operation.to, "to")
	end,
	duplicate_keyframe = function(where, operation)
		needTime(where, operation.time, "time")
		needTime(where, operation.to, "to")
	end,
	shift_time = function(where, operation)
		needRange(where, operation)
		if not isFinite(operation.offset) or operation.offset == 0 then
			refuse(where, "offset must be a number of seconds other than 0.")
		end
	end,
	scale_time = function(where, operation)
		needRange(where, operation)
		local factor = operation.factor
		if not isFinite(factor) or factor < Operations.MIN_SCALE or factor > Operations.MAX_SCALE or factor == 1 then
			refuse(where, `factor must be from {Operations.MIN_SCALE} to {Operations.MAX_SCALE}, and not 1.`)
		end
		if operation.anchor ~= nil then
			needTime(where, operation.anchor, "anchor")
		end
		if operation.ripple ~= nil and type(operation.ripple) ~= "boolean" then
			refuse(where, "ripple must be true or false.")
		end
	end,
	set_properties = function(where, operation)
		if operation.name == nil and operation.loop == nil and operation.priority == nil then
			refuse(where, "give name, loop or priority.")
		end
		if operation.name ~= nil then
			needText(where, operation.name, "name", Operations.MAX_NAME)
		end
		if operation.loop ~= nil and type(operation.loop) ~= "boolean" then
			refuse(where, "loop must be true or false.")
		end
		if operation.priority ~= nil then
			needOneOf(where, operation.priority, "priority", Operations.PRIORITIES)
		end
	end,
	set_marker = function(where, operation)
		needTime(where, operation.time, "time")
		needText(where, operation.name, "name", Operations.MAX_NAME)
		if operation.value ~= nil then
			needText(where, operation.value, "value", Operations.MAX_MARKER_VALUE, true)
		end
	end,
	remove_marker = function(where, operation)
		needTime(where, operation.time, "time")
		needText(where, operation.name, "name", Operations.MAX_NAME)
	end,
	smooth_motion = function(where, operation, joints)
		needRange(where, operation)
		if operation.time_to - operation.time_from < Operations.TIME_TOLERANCE then
			refuse(where, "the range must have some length.")
		end
		if operation.joints ~= nil then
			if
				type(operation.joints) ~= "table"
				or #operation.joints == 0
				or #operation.joints > Operations.MAX_JOINTS
			then
				refuse(where, `joints must list from 1 to {Operations.MAX_JOINTS} joint names.`)
			end
			for _, name in operation.joints do
				if type(name) ~= "string" or not joints[name] then
					refuse(where, `the rig has no joint "{tostring(name)}".`, "Call inspect_rig for the joint names.")
				end
			end
		end
		local rate = operation.rate
		if rate ~= nil then
			if
				not isFinite(rate)
				or rate ~= math.floor(rate)
				or rate < Operations.MIN_RATE
				or rate > Operations.MAX_RATE
			then
				refuse(where, `rate must be a whole number from {Operations.MIN_RATE} to {Operations.MAX_RATE}.`)
			end
		end
		if operation.snap_at ~= nil then
			if type(operation.snap_at) ~= "table" or #operation.snap_at > Operations.MAX_SNAPS then
				refuse(where, `snap_at must list at most {Operations.MAX_SNAPS} times.`)
			end
			for _, time in operation.snap_at do
				needTime(where, time, "each time in snap_at")
			end
		end
		if operation.loop ~= nil and type(operation.loop) ~= "boolean" then
			refuse(where, "loop must be true or false.")
		end
	end,
	restore_source = function() end,
}

-- The names of every operation, sorted.
function Operations.types(): { string }
	local names = {}
	for name in checks do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- Checks everything about a batch that does not depend on what the clip holds. Raises on
-- the first problem, naming the operation by its place in the list.
function Operations.check(operations: any, joints: { [string]: any })
	if type(operations) ~= "table" or #operations == 0 then
		Errors.throw("INVALID_ARGUMENT", "operations must be a non-empty list.")
	end
	if #operations > Operations.MAX_OPERATIONS then
		Errors.throw("LIMIT_EXCEEDED", `A batch holds at most {Operations.MAX_OPERATIONS} operations.`)
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
				`unknown operation type "{tostring(operation.type)}".`,
				`The types are: {table.concat(Operations.types(), ", ")}.`
			)
		end
		(check :: Check)(where, operation, joints)
	end
	if #Operations.holds(operations) > Operations.MAX_HOLDS then
		Errors.throw(
			"LIMIT_EXCEEDED",
			`A batch adds at most {Operations.MAX_HOLDS} keyframes that hold the current pose.`
		)
	end
end

-- The places in a batch of the keyframes that are to hold the clip's current pose.
function Operations.holds(operations: { any }): { number }
	local places = {}
	for index, operation in operations do
		if type(operation) == "table" and operation.type == "add_keyframe" and operation.hold == true then
			table.insert(places, index)
		end
	end
	return places
end

-- The joints a clip moves: those with a pose that has weight, in any keyframe.
function Operations.animated(sequence: Instance): { string }
	local seen: { [string]: boolean } = {}
	for _, keyframe in Operations.keyframes(sequence) do
		for _, descendant: any in keyframe:GetDescendants() do
			if descendant:IsA("Pose") and descendant.Weight > 0 then
				seen[descendant.Name] = true
			end
		end
	end
	local names = {}
	for name in seen do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- ---------------------------------------------------------------------------------------
-- Applying

local function count(changed: Changed, what: string, by: number?)
	changed[what] = (changed[what] or 0) + (by or 1)
end

local function inRange(time: number, from: number, to: number): boolean
	return time >= from - Operations.TIME_TOLERANCE and time <= to + Operations.TIME_TOLERANCE
end

local function newKeyframe(sequence: Instance, time: number, changed: Changed): Keyframe
	if #Operations.keyframes(sequence) >= Operations.MAX_KEYFRAMES then
		Errors.throw("LIMIT_EXCEEDED", `A clip holds at most {Operations.MAX_KEYFRAMES} keyframes.`)
	end
	local created = Roblox.Instance.new("Keyframe")
	created.Time = time
	created.Parent = sequence
	count(changed, "keyframes_created")
	return created
end

-- Takes a pose out of its keyframe. If other poses hang from it, it stays to hold them
-- and stops moving its joint; otherwise it goes, along with any ancestors that were only
-- there to hold it.
local function dropPose(pose: Pose)
	if #pose:GetChildren() > 0 then
		pose.Weight = 0
		pose.CFrame = Roblox.CFrame.new()
		return
	end
	local above = pose.Parent
	pose.Parent = nil
	while above and above:IsA("Pose") and above.Weight == 0 and #above:GetChildren() == 0 do
		local next = above.Parent
		above.Parent = nil
		above = next
	end
end

local function needKeyframe(where: string, sequence: Instance, time: number): Keyframe
	local keyframe = Operations.findKeyframe(sequence, time)
	if not keyframe then
		refuse(where, `there is no keyframe at {time} seconds.`, "read_animation lists the keyframe times.")
	end
	return keyframe :: Keyframe
end

local function needFree(where: string, sequence: Instance, time: number, except: Keyframe?)
	local occupant = Operations.findKeyframe(sequence, time)
	if occupant and occupant ~= except then
		refuse(where, `there is already a keyframe at {time} seconds.`)
	end
end

-- The joint's pose in a keyframe, only if it is one that moves the joint.
local function weighted(keyframe: Instance, joint: string): Pose?
	local pose = Operations.findPose(keyframe, joint)
	return if pose and pose.Weight > 0 then pose else nil
end

local function setEasing(pose: Pose, style: string?, direction: string?)
	if style then
		pose.EasingStyle = (Roblox.Enum.PoseEasingStyle :: any)[style]
	end
	if direction then
		pose.EasingDirection = (Roblox.Enum.PoseEasingDirection :: any)[direction]
	end
end

-- Moves the keyframes in a range to new times. Refused if a moved keyframe would land on
-- another, leave the allowed times, or pass a keyframe that is not being moved: any of
-- those would change the motion in a way the request did not spell out.
local function retime(
	where: string,
	sequence: Instance,
	operation: any,
	place: (time: number) -> number,
	changed: Changed
)
	local moved: { { keyframe: Keyframe, from: number, to: number } } = {}
	local still: { number } = {}
	for _, keyframe in Operations.keyframes(sequence) do
		if inRange(keyframe.Time, operation.time_from, operation.time_to) then
			table.insert(moved, { keyframe = keyframe, from = keyframe.Time, to = place(keyframe.Time) })
		else
			table.insert(still, keyframe.Time)
		end
	end
	if #moved == 0 then
		refuse(where, `there are no keyframes from {operation.time_from} to {operation.time_to} seconds.`)
	end
	for index, entry in moved do
		if entry.to < -Operations.TIME_TOLERANCE or entry.to > Operations.MAX_TIME then
			refuse(
				where,
				`the keyframe at {entry.from} seconds would move to {entry.to}, outside 0 to {Operations.MAX_TIME}.`
			)
		end
		local earlier = moved[index - 1]
		if earlier and entry.to - earlier.to < Operations.TIME_TOLERANCE then
			refuse(where, `the keyframes at {earlier.from} and {entry.from} seconds would land on each other.`)
		end
		for _, other in still do
			if math.abs(entry.to - other) < Operations.TIME_TOLERANCE then
				refuse(where, `the keyframe at {entry.from} seconds would land on the one at {other}.`)
			elseif (entry.from < other) ~= (entry.to < other) then
				refuse(
					where,
					`the keyframe at {entry.from} seconds would pass the one at {other}.`,
					"Widen the range to take that keyframe along, or move it first."
				)
			end
		end
	end
	for _, entry in moved do
		entry.keyframe.Time = math.max(0, entry.to)
	end
	count(changed, "keyframes_moved", #moved)
end

type Apply = (where: string, sequence: Instance, operation: any, context: Context, changed: Changed) -> ()

local appliers: { [string]: Apply } = {
	set_pose = function(_where, sequence, operation, _context, changed)
		local keyframe = Operations.findKeyframe(sequence, operation.time)
			or newKeyframe(sequence, operation.time, changed)
		local pose, created = Operations.ensurePose(keyframe, operation.joint)
		-- A pose that was only holding the nesting for its children starts to count now.
		count(changed, if created or pose.Weight == 0 then "poses_created" else "poses_changed")
		local target = Rig.decode(operation.position, operation.rotation, operation.quaternion)
		if operation.relative then
			pose.CFrame = pose.CFrame * target
		else
			local current = pose.CFrame
			if operation.position == nil then
				target = target.Rotation + current.Position
			elseif operation.rotation == nil and operation.quaternion == nil then
				target = current.Rotation + target.Position
			end
			pose.CFrame = target
		end
		pose.Weight = 1
		setEasing(pose, operation.easing_style, operation.easing_direction)
	end,

	remove_pose = function(where, sequence, operation, _context, changed)
		local keyframe = needKeyframe(where, sequence, operation.time)
		local pose = weighted(keyframe, operation.joint)
		if not pose then
			refuse(where, `"{operation.joint}" has no pose at {operation.time} seconds.`)
		end
		dropPose(pose :: Pose)
		count(changed, "poses_removed")
	end,

	-- Replaces each chosen joint's keys in a range by one smooth curve through them,
	-- written out as a pose at every step. See Smooth for what the curve is.
	smooth_motion = function(where, sequence, operation, _context, changed)
		local from, to = operation.time_from, operation.time_to
		local rate = operation.rate or Operations.DEFAULT_RATE
		local existing = Operations.keyframes(sequence)
		local names: { string } = operation.joints or Operations.animated(sequence)

		-- A clip that loops, smoothed from its first keyframe to its last, carries its
		-- speed across the join unless told otherwise.
		local first, last = existing[1], existing[#existing]
		local whole = #existing > 0
			and math.abs(first.Time - from) < Operations.TIME_TOLERANCE
			and math.abs(last.Time - to) < Operations.TIME_TOLERANCE
		local loop = if operation.loop ~= nil then operation.loop else ((sequence :: any).Loop == true and whole)

		-- Everything is worked out before anything is changed.
		type Plan = { name: string, poses: { Pose }, times: { number }, samples: { { number } } }
		local plans: { Plan } = {}
		for _, name in names do
			local keys: { Smooth.Key } = {}
			local poses: { Pose } = {}
			for _, keyframe in existing do
				local pose = if inRange(keyframe.Time, from, to) then weighted(keyframe, name) else nil
				if pose and (#keys == 0 or keyframe.Time - keys[#keys].time > 1e-6) then
					local position = pose.CFrame.Position
					local x, y, z, w = Rig.quaternionOf(pose.CFrame)
					local before = keys[#keys]
					-- A rotation has two quaternions, one the negative of the other. The one
					-- nearer the key before is the one the curve should run to.
					if
						before
						and before.values[4] * x
								+ before.values[5] * y
								+ before.values[6] * z
								+ before.values[7] * w
							< 0
					then
						x, y, z, w = -x, -y, -z, -w
					end
					table.insert(
						keys,
						{ time = keyframe.Time, values = { position.X, position.Y, position.Z, x, y, z, w } }
					)
					table.insert(poses, pose)
				end
			end
			if #keys < 2 then
				continue
			end
			local start, finish = keys[1].time, keys[#keys].time
			local snap: { [number]: boolean } = {}
			for _, at in operation.snap_at or {} do
				for index, key in keys do
					if math.abs(key.time - at) < Operations.TIME_TOLERANCE then
						snap[index] = true
					end
				end
			end
			-- A pose at the joint's first key and its last, and at every step between.
			local times = { start }
			local step = math.ceil((start - from) * rate - 1e-6)
			while true do
				local time = from + step / rate
				if time > finish - Operations.TIME_TOLERANCE then
					break
				end
				if time > start + Operations.TIME_TOLERANCE then
					table.insert(times, time)
				end
				step += 1
			end
			table.insert(times, finish)
			table.insert(plans, {
				name = name,
				poses = poses,
				times = times,
				samples = Smooth.sample(keys, times, {
					snap = snap,
					loop = loop
						and math.abs(start - from) < Operations.TIME_TOLERANCE
						and math.abs(finish - to) < Operations.TIME_TOLERANCE,
				}),
			})
		end
		if #plans == 0 then
			refuse(where, `no joint has two or more poses from {from} to {to} seconds to smooth between.`)
		end

		-- Out go the keys the curve was drawn through, and any keyframe they leave empty.
		local emptied: { [Instance]: boolean } = {}
		for _, plan in plans do
			for _, pose in plan.poses do
				local keyframe: Instance = pose
				while keyframe.Parent and not keyframe:IsA("Keyframe") do
					keyframe = keyframe.Parent :: Instance
				end
				emptied[keyframe] = true
				dropPose(pose)
				count(changed, "poses_removed")
			end
		end

		-- In go the poses of the curve. Keyframes are found by their time in thousandths
		-- of a second, which is how close two must be to count as one.
		local byTime: { [number]: Keyframe } = {}
		local total = 0
		for _, keyframe in Operations.keyframes(sequence) do
			byTime[math.round(keyframe.Time * 1000)] = keyframe
			total += 1
		end
		for _, plan in plans do
			for index, time in plan.times do
				local slot = math.round(time * 1000)
				local keyframe = byTime[slot]
				if not keyframe then
					if total >= Operations.MAX_KEYFRAMES then
						Errors.throw("LIMIT_EXCEEDED", `A clip holds at most {Operations.MAX_KEYFRAMES} keyframes.`)
					end
					local created = Roblox.Instance.new("Keyframe")
					created.Time = time
					created.Parent = sequence
					keyframe = created
					byTime[slot] = created
					total += 1
					count(changed, "keyframes_created")
				end
				local values = plan.samples[index]
				local pose = Operations.ensurePose(keyframe :: Keyframe, plan.name)
				pose.CFrame = Rig.decode(
					{ values[1], values[2], values[3] },
					nil,
					{ values[4], values[5], values[6], values[7] }
				)
				pose.Weight = 1
				-- The curve is in the poses now. Between two of them a straight line will do.
				pose.EasingStyle = Roblox.Enum.PoseEasingStyle.Linear
				pose.EasingDirection = Roblox.Enum.PoseEasingDirection.In
				emptied[keyframe :: Keyframe] = nil
				count(changed, "poses_created")
			end
		end
		for keyframe in emptied do
			if keyframe.Parent and #keyframe:GetChildren() == 0 then
				keyframe.Parent = nil
				count(changed, "keyframes_removed")
			end
		end
	end,

	offset_pose = function(where, sequence, operation, _context, changed)
		local offset = Rig.decode(operation.position, operation.rotation, operation.quaternion)
		local found = 0
		for _, keyframe in Operations.keyframes(sequence) do
			if inRange(keyframe.Time, operation.time_from, operation.time_to) then
				local pose = weighted(keyframe, operation.joint)
				if pose then
					pose.CFrame = pose.CFrame * offset
					found += 1
				end
			end
		end
		if found == 0 then
			refuse(where, `"{operation.joint}" has no pose from {operation.time_from} to {operation.time_to} seconds.`)
		end
		count(changed, "poses_changed", found)
	end,

	set_easing = function(where, sequence, operation, _context, changed)
		local found = 0
		for _, keyframe in Operations.keyframes(sequence) do
			if inRange(keyframe.Time, operation.time_from, operation.time_to) then
				local pose = weighted(keyframe, operation.joint)
				if pose then
					setEasing(pose, operation.easing_style, operation.easing_direction)
					found += 1
				end
			end
		end
		if found == 0 then
			refuse(where, `"{operation.joint}" has no pose from {operation.time_from} to {operation.time_to} seconds.`)
		end
		count(changed, "poses_changed", found)
	end,

	add_keyframe = function(where, sequence, operation, context, changed)
		needFree(where, sequence, operation.time)
		if operation.hold ~= true then
			newKeyframe(sequence, operation.time, changed)
			return
		end
		local index = tonumber(string.match(where, "%d+")) :: number
		local poses = context.held and context.held[index]
		if not poses then
			Errors.throw(
				"PREVIEW_UNAVAILABLE",
				`{where}: the clip's pose at {operation.time} seconds could not be worked out.`
			)
		end
		-- Easing belongs to the pose a stretch of motion starts from. The new keyframe
		-- starts the second half of a stretch, so it takes the easing of the pose before
		-- it. Found before the keyframe exists, so that it is not found itself.
		local easing: { [string]: Pose } = {}
		local later: { [string]: boolean } = {}
		for _, keyframe in Operations.keyframes(sequence) do
			for name in poses :: { [string]: CFrame } do
				local found = weighted(keyframe, name)
				if found and keyframe.Time < operation.time then
					easing[name] = found
				elseif found then
					later[name] = true
				end
			end
		end
		local created = newKeyframe(sequence, operation.time, changed)
		local reshaped: { string } = {}
		local names: { string } = {}
		for name in poses :: { [string]: CFrame } do
			-- Only a joint that is between two of its own poses here is keyed. Before its
			-- first pose or after its last, a new pose would start or end a stretch of
			-- motion that was not there.
			if easing[name] and later[name] then
				table.insert(names, name)
			end
		end
		table.sort(names)
		for _, name in names do
			local pose = Operations.ensurePose(created, name)
			pose.CFrame = (poses :: { [string]: CFrame })[name]
			pose.Weight = 1
			local before = easing[name]
			if before then
				pose.EasingStyle = before.EasingStyle
				pose.EasingDirection = before.EasingDirection
				-- Only a straight or a stepped stretch is the same motion once split in two.
				local style = before.EasingStyle.Name
				if style ~= "Linear" and style ~= "Constant" then
					table.insert(reshaped, name)
				end
			end
			count(changed, "poses_created")
		end
		if context.holds then
			table.insert(context.holds, {
				time = operation.time,
				joints = #names,
				-- Joints whose motion around the new keyframe is no longer what it was.
				motion_changed = if #reshaped > 0 then reshaped else nil,
			})
		end
	end,

	remove_keyframe = function(where, sequence, operation, _context, changed)
		needKeyframe(where, sequence, operation.time).Parent = nil
		count(changed, "keyframes_removed")
	end,

	move_keyframe = function(where, sequence, operation, _context, changed)
		local keyframe = needKeyframe(where, sequence, operation.time)
		needFree(where, sequence, operation.to, keyframe)
		keyframe.Time = operation.to
		count(changed, "keyframes_moved")
	end,

	duplicate_keyframe = function(where, sequence, operation, _context, changed)
		local keyframe = needKeyframe(where, sequence, operation.time)
		needFree(where, sequence, operation.to)
		if #Operations.keyframes(sequence) >= Operations.MAX_KEYFRAMES then
			Errors.throw("LIMIT_EXCEEDED", `A clip holds at most {Operations.MAX_KEYFRAMES} keyframes.`)
		end
		local copy = keyframe:Clone()
		copy.Time = operation.to
		copy.Parent = sequence
		count(changed, "keyframes_created")
	end,

	shift_time = function(where, sequence, operation, _context, changed)
		retime(where, sequence, operation, function(time)
			return time + operation.offset
		end, changed)
	end,

	scale_time = function(where, sequence, operation, _context, changed)
		local anchor = if operation.anchor ~= nil then operation.anchor else operation.time_from
		local function scaled(time: number): number
			return anchor + (time - anchor) * operation.factor
		end
		if not operation.ripple then
			retime(where, sequence, operation, scaled, changed)
			return
		end
		-- Everything after the range moves by as much as the range's end does, so the rest
		-- of the clip keeps its timing.
		local stretch = scaled(operation.time_to) - operation.time_to
		local range = table.clone(operation)
		range.time_to = Operations.MAX_TIME
		retime(where, sequence, range, function(time)
			return if time <= operation.time_to + Operations.TIME_TOLERANCE then scaled(time) else time + stretch
		end, changed)
	end,

	set_properties = function(_where, sequence, operation, _context, changed)
		local clip = sequence :: any
		if operation.name ~= nil then
			clip.Name = operation.name
		end
		if operation.loop ~= nil then
			clip.Loop = operation.loop
		end
		if operation.priority ~= nil then
			clip.Priority = (Roblox.Enum.AnimationPriority :: any)[operation.priority]
		end
		count(changed, "properties_changed")
	end,

	set_marker = function(_where, sequence, operation, _context, changed)
		local keyframe = Operations.findKeyframe(sequence, operation.time)
			or newKeyframe(sequence, operation.time, changed)
		local marker: any = nil
		for _, child in keyframe:GetChildren() do
			if child:IsA("KeyframeMarker") and child.Name == operation.name then
				marker = child
			end
		end
		if not marker then
			marker = Roblox.Instance.new("KeyframeMarker")
			marker.Name = operation.name
			marker.Parent = keyframe
		end
		marker.Value = operation.value or ""
		count(changed, "markers_set")
	end,

	remove_marker = function(where, sequence, operation, _context, changed)
		local keyframe = needKeyframe(where, sequence, operation.time)
		local removed = 0
		for _, child in keyframe:GetChildren() do
			if child:IsA("KeyframeMarker") and child.Name == operation.name then
				child.Parent = nil
				removed += 1
			end
		end
		if removed == 0 then
			refuse(where, `there is no marker "{operation.name}" at {operation.time} seconds.`)
		end
		count(changed, "markers_removed", removed)
	end,

	restore_source = function(_where, sequence, _operation, context, changed)
		if context.source then
			Operations.copyContent(context.source, sequence)
		else
			-- Opened blank: back to holding nothing.
			for _, child in sequence:GetChildren() do
				child.Parent = nil
			end
		end
		count(changed, "restored")
	end,
}

-- Applies a checked batch to a clip, one operation after another, and returns counts of
-- what changed. Raises at the first operation that cannot be done, leaving the earlier
-- ones applied: run it on a scratch copy first if that matters.
function Operations.run(
	sequence: Instance,
	operations: { any },
	context: Context,
	before: ((index: number) -> ())?
): Changed
	local changed: Changed = {}
	for index, operation in operations do
		if before then
			before(index)
		end
		appliers[operation.type](`operations[{index}]`, sequence, operation, context, changed)
	end
	return changed
end

return Operations
