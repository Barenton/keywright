--!strict
-- pin: holding a hand or foot, eased in and out, against a part, on a moving floor, rolling, softened, with the hips fitted; and the motion either side of a range written frame by frame.
-- Run with: lune run plugin/test/editing/curves/pin.test.luau

local Kit = require("./kit")

local blank = Kit.blank
local Curves = Kit.Curves
local difference = Kit.difference
local FLOOR = Kit.FLOOR
local hunch = Kit.hunch
local keysOf = Kit.keysOf
local lopsided = Kit.lopsided
local lowestAt = Kit.lowestAt
local placedAt = Kit.placedAt
local REAL = Kit.REAL
local realRun = Kit.realRun
local refusal = Kit.refusal
local roblox = Kit.roblox
local sampleAll = Kit.sampleAll
local squat = Kit.squat
local turnBetween = Kit.turnBetween
local Validate = Kit.Validate
local yaw = Kit.yaw

local check, case, finish = Kit.suite("pin")
case("a pinned foot stays where it was while the hips drop", function()
	local clip = squat(0.8)
	local start = placedAt(clip, 0).LeftFoot
	check(
		"before pinning, the foot drops with the hips",
		placedAt(clip, 0.5).LeftFoot.Position.Y < start.Position.Y - 0.7
	)
	local changed = realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1 } })
	check("every frame is pinned", changed.frames_pinned == 31, changed.frames_pinned)
	check("nothing was out of reach", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local studs, degrees = 0, 0
	for frame = 0, 30 do
		local foot = placedAt(clip, frame / 30).LeftFoot
		studs = math.max(studs, (foot.Position - start.Position).Magnitude)
		degrees = math.max(degrees, turnBetween(foot, start))
	end
	check("the foot stays within a thousandth of a stud", studs < 0.001, studs)
	check("and does not turn", degrees < 0.05, degrees)
	local knee = Curves.keys(assert(Curves.channel(clip, "LeftLowerLeg", "rotation.x", false)))
	check("the knee is keyed on every frame", #knee == 31, #knee)
	local onFrames = true
	for _, key in knee do
		onFrames = onFrames and math.abs(key.time * 30 - math.round(key.time * 30)) < 1e-6
	end
	check("on whole frames", onFrames)
	check("the knee bends forward at the bottom", knee[16].value < -0.3, knee[16].value)
	check("the other foot is not touched", Curves.folder(clip, "RightUpperLeg", false) == nil)
	check("and still drops", placedAt(clip, 0.5).RightFoot.Position.Y < start.Position.Y - 0.7)
end)

case("a foot that cannot stay is reached for, and the result says by how much it fell short", function()
	local clip = squat(-1)
	local changed = realRun(clip, { { type = "pin", part = "RightFoot", time_from = 0, time_to = 1 } })
	check("some frames were out of reach", (changed.frames_out_of_reach or 0) > 0, changed.frames_out_of_reach)
	check("with the worst shortfall", (changed.largest_miss_studs or 0) > 0.5, changed.largest_miss_studs)
	-- The hips rise highest at the middle of the clip, so that is where the leg falls short.
	check(
		"and when",
		(changed.out_of_reach_from or 0) > 0
			and (changed.out_of_reach_from or 0) < 0.5
			and (changed.out_of_reach_to or 1) > 0.5
			and (changed.out_of_reach_to or 1) < 1,
		`{changed.out_of_reach_from} to {changed.out_of_reach_to}`
	)
end)

case("a pin over part of a clip leaves the rest of it as it was", function()
	local clip = squat(0.8)
	local outside = { 0.1, 0.2, 0.8, 0.9 }
	local before = {}
	for _, time in outside do
		before[time] = placedAt(clip, time).LeftFoot
	end
	local pinnedAt = placedAt(clip, 0.4).LeftFoot
	realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0.4, time_to = 0.6 } })
	for _, time in outside do
		local moved = (placedAt(clip, time).LeftFoot.Position - before[time].Position).Magnitude
		check(`the foot at {time} seconds is where it was`, moved < 1e-4, moved)
	end
	local held = 0
	for frame = 12, 18 do
		held = math.max(held, (placedAt(clip, frame / 30).LeftFoot.Position - pinnedAt.Position).Magnitude)
	end
	check("and held inside the range", held < 0.001, held)
end)

case("a pin blends in and out over the time asked", function()
	local clip = squat(0.8)
	local free = {}
	for frame = 0, 30 do
		free[frame] = placedAt(clip, frame / 30).LeftFoot
	end
	realRun(clip, {
		-- Held where it stands at the start, which the bent leg can reach.
		{ type = "pin", part = "LeftFoot", time_from = 0.4, time_to = 0.6, at = 0, blend_in = 0.2, blend_out = 0.2 },
	})
	local pinned = free[0]
	local function along(frame: number): number
		-- How far from its free path toward the pinned point the foot is, from 0 to 1.
		local gap = (free[frame].Position - pinned.Position).Magnitude
		if gap < 1e-6 then
			return 1
		end
		return 1 - (placedAt(clip, frame / 30).LeftFoot.Position - pinned.Position).Magnitude / gap
	end
	check("at the start of the blend the foot is free", along(6) < 0.01, along(6))
	check("halfway in, it is partway", along(9) > 0.2 and along(9) < 0.8, along(9))
	check("in the range, it is pinned", along(15) > 0.999, along(15))
	check("halfway out, it is partway", along(21) > 0.2 and along(21) < 0.8, along(21))
	check("at the end of the blend it is free again", along(24) < 0.01, along(24))
end)

case("easing in and out, the foot travels straight between its own path and the hold", function()
	-- The hips drop while the leg swings forward and back: on its own, the foot sweeps an
	-- arc. Easing joint angles would carry it along a curve of its own; easing the target
	-- keeps it on the line between where the animation has it and where it is held.
	local clip = squat(0.6)
	realRun(clip, {
		{ type = "set_key", joint = "LeftUpperLeg", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LeftUpperLeg", time = 0.5, rotation = { 50, 0, 0 } },
		{ type = "set_key", joint = "LeftUpperLeg", time = 1, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LeftLowerLeg", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LeftLowerLeg", time = 0.5, rotation = { -70, 0, 0 } },
		{ type = "set_key", joint = "LeftLowerLeg", time = 1, rotation = { 0, 0, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	local free = {}
	for frame = 0, 30 do
		free[frame] = placedAt(clip, frame / 30).LeftFoot
	end
	local held = free[0]
	realRun(clip, {
		{ type = "pin", part = "LeftFoot", time_from = 0.4, time_to = 0.6, at = 0, blend_in = 0.3, blend_out = 0.3 },
	})
	local function smoothstep(t: number): number
		t = math.clamp(t, 0, 1)
		return t * t * (3 - 2 * t)
	end
	local worst, turned = 0, 0
	for frame = 3, 27 do
		local time = frame / 30
		local weight = if time < 0.4
			then smoothstep((time - 0.1) / 0.3)
			elseif time > 0.6 then smoothstep((0.9 - time) / 0.3)
			else 1
		local wanted = free[frame]:Lerp(held, weight)
		local foot = placedAt(clip, time).LeftFoot
		worst = math.max(worst, (foot.Position - wanted.Position).Magnitude)
		turned = math.max(turned, turnBetween(foot, wanted))
	end
	check("the foot is on the line at every frame", worst < 0.001, worst)
	check("turning evenly from its own turn to the held one", turned < 0.05, turned)
end)

case("a pin can put a hand somewhere new", function()
	local clip = squat(0.4)
	local target = { 0.6, 0.4, -1.4 }
	realRun(clip, {
		{ type = "pin", part = "RightHand", time_from = 0, time_to = 1, position = target },
	})
	local worst = 0
	for frame = 0, 30 do
		local hand = placedAt(clip, frame / 30).RightHand.Position
		worst = math.max(worst, (hand - roblox.Vector3.new(target[1], target[2], target[3])).Magnitude)
	end
	check("the hand is held there through the squat", worst < 0.001, worst)
end)

case("a pin relative to another part moves with that part", function()
	local clip = hunch()
	local offset = roblox.Vector3.new(0.3, 0.2, -1)
	local changed = realRun(clip, {
		{
			type = "pin",
			part = "RightHand",
			time_from = 0,
			time_to = 1,
			relative_to = "UpperTorso",
			position = { offset.X, offset.Y, offset.Z },
		},
	})
	check("nothing was out of reach", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local worst, travelled = 0, 0
	local start = placedAt(clip, 0).RightHand.Position
	for frame = 0, 30 do
		local placed = placedAt(clip, frame / 30)
		local wanted = placed.UpperTorso:PointToWorldSpace(offset)
		worst = math.max(worst, (placed.RightHand.Position - wanted).Magnitude)
		travelled = math.max(travelled, (placed.RightHand.Position - start).Magnitude)
	end
	check("the hand stays on the chest", worst < 0.001, worst)
	check("and so moves through the room with it", travelled > 0.5, travelled)

	-- Without a position, the hand keeps where it was against the part at `at`.
	local kept = hunch()
	local before = placedAt(kept, 0)
	local relation = before.UpperTorso:Inverse() * before.LeftHand
	realRun(kept, { { type = "pin", part = "LeftHand", time_from = 0, time_to = 1, relative_to = "UpperTorso" } })
	local drift, turned = 0, 0
	for frame = 0, 30 do
		local placed = placedAt(kept, frame / 30)
		local wanted = placed.UpperTorso * relation
		drift = math.max(drift, (placed.LeftHand.Position - wanted.Position).Magnitude)
		turned = math.max(turned, turnBetween(placed.LeftHand, wanted))
	end
	check("a hand held to the chest as it was stays so", drift < 0.001, drift)
	check("turning with it", turned < 0.05, turned)
end)

case("a range written to four decimals covers the frames it names", function()
	local clip = squat(0.5)
	-- 0.3667 is a little after frame 11 (0.36666...) and 0.6333 a little before frame 19
	-- (0.63333...): each is still that frame.
	local changed = realRun(clip, {
		{ type = "place_on_floor", time_from = 0.3667, time_to = 0.3667, mode = "touch" },
		{ type = "pin", part = "LeftFoot", time_from = 0.6333, time_to = 0.6333 },
	})
	check("a one-frame place_on_floor", changed.frames_moved == 1, changed.frames_moved)
	check("a one-frame pin", changed.frames_pinned == 1, changed.frames_pinned)
end)

case("a soft pin does not lock the knee straight, and says how short it fell", function()
	-- The hips drop from standing, where the leg is at full reach.
	local function kneeSpeed(soft: number?): (number, any)
		local clip = squat(0.4)
		local changed = realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, soft = soft } })
		local knee = keysOf(clip, "LeftLowerLeg", "rotation.x")
		local fastest = 0
		for frame = 1, 8 do
			local a = Curves.evaluate(knee, (frame - 1) / 30)
			local b = Curves.evaluate(knee, frame / 30)
			fastest = math.max(fastest, math.abs(math.deg(b - a)))
		end
		return fastest, changed
	end
	local hard = kneeSpeed()
	local soft, changed = kneeSpeed(0.1)
	check("the knee moves less suddenly as the hips first drop", soft < hard * 0.8, `{soft} against {hard}`)
	check("softened frames are not out of reach", changed.frames_out_of_reach == nil, changed.frames_out_of_reach)
	check("the result says how short it fell", (changed.largest_soft_studs or 0) > 0, changed.largest_soft_studs)
end)

case("a pin with travel holds the foot on a floor that moves steadily", function()
	local clip = squat(0.3)
	local start = placedAt(clip, 0.2).LeftFoot
	-- While the hips are low, so the leg can follow the foot back.
	local changed = realRun(clip, {
		{ type = "pin", part = "LeftFoot", time_from = 0.2, time_to = 0.6, travel = { 0, 0, 0.6 } },
	})
	check("reached at every frame", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local worst, turned = 0, 0
	for frame = 6, 18 do
		local time = frame / 30
		local foot = placedAt(clip, time).LeftFoot
		local wanted = start.Position + roblox.Vector3.new(0, 0, 0.6 * (time - 0.2))
		worst = math.max(worst, (foot.Position - wanted).Magnitude)
		turned = math.max(turned, turnBetween(foot, start))
	end
	check("the foot moves back at the speed asked, every frame", worst < 0.001, worst)
	check("without turning", turned < 0.05, turned)

	-- With "match", the speed is the foot's own from the start of the range to its end.
	local drifting = squat(0.3)
	realRun(drifting, {
		{ type = "set_key", joint = "LowerTorso", time = 0.2, position = { 0, -0.25, -0.15 } },
		{ type = "set_key", joint = "LowerTorso", time = 0.6, position = { 0, -0.25, -0.45 } },
	})
	local from, to = placedAt(drifting, 0.2).LeftFoot.Position, placedAt(drifting, 0.6).LeftFoot.Position
	local matched =
		realRun(drifting, { { type = "pin", part = "LeftFoot", time_from = 0.2, time_to = 0.6, travel = "match" } })
	local expected = (to - from) / 0.4
	check(
		"match takes the foot's own speed",
		math.abs(matched.travel_z - expected.Z) < 0.002 and math.abs(matched.travel_x - expected.X) < 0.002,
		`{matched.travel_z} against {expected.Z}`
	)
	local even = 0
	for frame = 6, 18 do
		local time = frame / 30
		local wanted = from + expected * (time - 0.2)
		even = math.max(even, (placedAt(drifting, time).LeftFoot.Position - wanted).Magnitude)
	end
	check("and moves it at that speed, evenly", even < 0.001, even)

	-- Eased in, the point it eases toward is already moving, so it lands moving with it.
	local landing = squat(0.3)
	realRun(landing, {
		{ type = "pin", part = "LeftFoot", time_from = 0.3, time_to = 0.6, travel = { 0, 0, 0.6 }, blend_in = 0.2 },
	})
	local function speedZ(time: number): number
		return (placedAt(landing, time + 1 / 30).LeftFoot.Position.Z - placedAt(landing, time).LeftFoot.Position.Z) * 30
	end
	check(
		"eased in, it already moves with the floor as it lands",
		math.abs(speedZ(0.2667) - 0.6) < 0.15,
		speedZ(0.2667)
	)
end)

case("a pin with fit_hips lowers the hips just enough to reach, keeping other limbs still", function()
	-- A foot put far forward on the floor: a lunge, out of reach with the hips where they are.
	local function lunge(): any
		local clip = blank()
		realRun(clip, {
			{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0, 0 } },
			{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0, 0 } },
		})
		return clip
	end
	local far = { -0.5, -2.85, -1.3 }
	local stiff = realRun(lunge(), { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, position = far } })
	check("without it, the foot cannot reach", (stiff.frames_out_of_reach or 0) > 0, stiff.frames_out_of_reach)

	local clip = lunge()
	local rightBefore = placedAt(clip, 0.5).RightFoot
	local changed = realRun(clip, {
		{
			type = "pin",
			part = "LeftFoot",
			time_from = 0,
			time_to = 1,
			position = far,
			fit_hips = true,
			keep = { "RightFoot" },
		},
	})
	check("with it, every frame is reached", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	check("the hips were lowered", (changed.largest_hip_drop_studs or 0) > 0.1, changed.largest_hip_drop_studs)
	local placed = placedAt(clip, 0.5)
	local miss = (placed.LeftFoot.Position - roblox.Vector3.new(far[1], far[2], far[3])).Magnitude
	check("the foot is where it was put", miss < 0.001, miss)
	check(
		"the hips went straight down",
		math.abs(placed.LowerTorso.Position.X) < 1e-6 and math.abs(placed.LowerTorso.Position.Z) < 1e-6
	)
	local kept = (placed.RightFoot.Position - rightBefore.Position).Magnitude
	check("the other foot kept where it was", kept < 0.001, kept)
	check("and its turn", turnBetween(placed.RightFoot, rightBefore) < 0.05)

	-- Only as far as needed: the leg is then exactly at full reach.
	local upper = placed.LowerTorso:PointToWorldSpace(roblox.Vector3.new(-0.5, -0.2, 0))
	local ankle = placed.LeftFoot:PointToWorldSpace(roblox.Vector3.new(0, 0.15, 0.25))
	local stretched = placedAt(lunge(), 0)
	local fullest = (
		stretched.LowerTorso:PointToWorldSpace(roblox.Vector3.new(-0.5, -0.2, 0))
		- stretched.LeftFoot:PointToWorldSpace(roblox.Vector3.new(0, 0.15, 0.25))
	).Magnitude
	check(
		"no lower than needed",
		(upper - ankle).Magnitude > fullest - 0.06,
		`{(upper - ankle).Magnitude} against {fullest}`
	)
	check(
		"keep is for fit_hips",
		refusal(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, keep = { "RightFoot" } } })
			~= nil
	)
end)

case("pins that cannot be done are refused", function()
	local clip = squat(0.5)
	local function refusedReal(operation: any): any
		local ok, problem = pcall(realRun, clip, { operation })
		return if ok then nil else problem
	end
	check("an unknown limb", refusedReal({ type = "pin", part = "Head", time_from = 0, time_to = 1 }) ~= nil)
	local late = refusedReal({ type = "pin", part = "LeftFoot", time_from = 0, time_to = 2 })
	check("past the end of the clip", late and string.find(late.message, "ends at", 1, true), late and late.message)
	check(
		"an unknown hold",
		refusedReal({ type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, hold = "loose" }) ~= nil
	)
	check(
		"too long a blend",
		refusedReal({ type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, blend_in = 5 }) ~= nil
	)
	check(
		"relative to a part of the limb itself",
		refusedReal({ type = "pin", part = "RightHand", time_from = 0, time_to = 1, relative_to = "RightLowerArm" })
			~= nil
	)
	check(
		"relative to a part the rig lacks",
		refusedReal({ type = "pin", part = "RightHand", time_from = 0, time_to = 1, relative_to = "Tail" }) ~= nil
	)
	local blind = refusal(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1 } })
	check(
		"a rig known only by its joint names",
		blind and string.find(blind.message, "could not be measured", 1, true),
		blind and blind.message
	)
end)

case("a range rewritten frame by frame leaves the motion either side exactly as it was", function()
	local original = lopsided()
	local clip = lopsided()
	-- The left arm has keys before, inside and after the range.
	realRun(clip, { { type = "pin", part = "LeftHand", time_from = 0.3, time_to = 0.6 } })
	local worst = 0
	for frame = 0, 30 do
		local time = frame / 30
		if time < 0.3 - 1e-6 or time > 0.6 + 1e-6 then
			worst = math.max(worst, difference(sampleAll(clip, time), sampleAll(original, time)))
		end
	end
	check("every frame outside the range is unchanged", worst < 1e-6, worst)
end)

case("a pin on_floor stands the foot flat on the floor where it is", function()
	local clip = squat(0.4)
	-- At 0.5 seconds the straight legs have pushed the feet into the floor.
	local sunk = placedAt(clip, 0.5).LeftFoot
	check("before, the foot is in the floor", lowestAt(clip, 0.5, { "LeftFoot" }) < FLOOR - 0.3)
	realRun(clip, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, at = 0.5, on_floor = true } })
	local height, drift = 0, 0
	for frame = 0, 30 do
		height = math.max(height, math.abs(lowestAt(clip, frame / 30, { "LeftFoot" }) - FLOOR))
		local foot = placedAt(clip, frame / 30).LeftFoot.Position
		drift = math.max(drift, math.abs(foot.X - sunk.Position.X) + math.abs(foot.Z - sunk.Position.Z))
	end
	check("after, it stands on the floor at every frame", height < 0.002, height)
	check("where it was, across the floor", drift < 0.002, drift)
	check("not with relative_to", refusal(clip, {
		{ type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, on_floor = true, relative_to = "UpperTorso" },
	}) ~= nil)
end)

case("a pin with a toe or heel pivot rolls the foot over that point", function()
	-- The hips drop and turn, which a planted foot is not to follow.
	local function turning(): any
		local clip = squat(0.3)
		realRun(clip, {
			{ type = "set_key", joint = "LowerTorso", time = 0, rotation = { 0, 0, 0 } },
			{ type = "set_key", joint = "LowerTorso", time = 0.5, rotation = { 0, 20, 0 } },
			{ type = "set_key", joint = "LowerTorso", time = 1, rotation = { 0, 0, 0 } },
			{ type = "auto_tangents", time_from = 0, time_to = 1 },
		})
		return clip
	end
	local size = REAL.LeftFoot.part1.Size
	local function pitch(foot: any): number
		return math.deg(math.asin(math.clamp(foot.LookVector.Y, -1, 1)))
	end

	-- Flat, then up onto the toe and back down, then flat again: as in a step's push-off,
	-- and next to other pins, which rewrite the foot's own keys.
	local clip = turning()
	local toe = roblox.Vector3.new(0, -size.Y / 2, -size.Z / 2)
	local changed = realRun(clip, {
		{ type = "pin", part = "LeftFoot", time_from = 0, time_to = 0.4, on_floor = true },
		{ type = "pin", part = "LeftFoot", time_from = 0.4, time_to = 0.6, pivot = "toe", roll = { 0, 30 } },
		{ type = "pin", part = "LeftFoot", time_from = 0.6, time_to = 0.8, pivot = "toe", roll = { 30, 0 } },
		{ type = "pin", part = "LeftFoot", time_from = 0.8, time_to = 1, on_floor = true },
	})
	check("reached at every frame", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local start = placedAt(clip, 0).LeftFoot:PointToWorldSpace(toe)
	local heading = yaw(placedAt(clip, 0).LeftFoot)
	local drift, twisted = 0, 0
	for frame = 0, 30 do
		local foot = placedAt(clip, frame / 30).LeftFoot
		drift = math.max(drift, (foot:PointToWorldSpace(toe) - start).Magnitude)
		twisted = math.max(twisted, math.abs(yaw(foot) - heading))
	end
	check("the toe stays put throughout", drift < 0.002, drift)
	check("the foot does not turn with the hips", twisted < 0.1, twisted)
	local lifted = placedAt(clip, 0.6).LeftFoot
	check("at the top the heel is lifted as far as asked", math.abs(-pitch(lifted) - 30) < 0.1, pitch(lifted))
	check("and the heel is what rose", lifted:PointToWorldSpace(-toe).Y > start.Y + 0.4)
	check("halfway up, part of the way", math.abs(-pitch(placedAt(clip, 0.5).LeftFoot) - 15) < 0.5)
	local checked = Validate.run(clip, { joints = REAL }, assert(Validate.thresholds({})))
	local slides = 0
	for _, issue in checked.issues do
		if issue.code == "FOOT_SLIDE" and issue.joints[1] == "LeftFoot" then
			slides += 1
		end
	end
	check("rolling over the toe is not taken for sliding", slides == 0, slides)

	-- Landing heel first: the toes start lifted and come down onto the floor.
	local landing = turning()
	local heel = roblox.Vector3.new(0, -size.Y / 2, size.Z / 2)
	realRun(landing, {
		{
			type = "pin",
			part = "LeftFoot",
			time_from = 0,
			time_to = 0.3,
			pivot = "heel",
			roll = { 25, 0 },
			on_floor = true,
		},
	})
	local first = placedAt(landing, 0).LeftFoot
	check("landing, the toes start lifted", math.abs(pitch(first) - 25) < 0.1, pitch(first))
	local heelStart = first:PointToWorldSpace(heel)
	local heelDrift = 0
	for frame = 0, 9 do
		heelDrift =
			math.max(heelDrift, (placedAt(landing, frame / 30).LeftFoot:PointToWorldSpace(heel) - heelStart).Magnitude)
	end
	check("the heel stays put", heelDrift < 0.002, heelDrift)
	check("and on the floor", math.abs(heelStart.Y - FLOOR) < 0.002, heelStart.Y - FLOOR)
	check("the foot ends flat", math.abs(pitch(placedAt(landing, 0.3).LeftFoot)) < 0.1)
	check(
		"a toe pivot on a hand is refused",
		refusal(landing, { { type = "pin", part = "LeftHand", time_from = 0, time_to = 1, pivot = "toe" } }) ~= nil
	)
	check(
		"a roll without a pivot is refused",
		refusal(landing, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1, roll = { 0, 10 } } }) ~= nil
	)
end)

finish()
