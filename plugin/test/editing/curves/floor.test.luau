--!strict
-- The floor: putting the body on it, keeping a hand or foot off it, and the contact checks.
-- Run with: lune run plugin/test/editing/curves/floor.test.luau

local Kit = require("./kit")

local blank = Kit.blank
local difference = Kit.difference
local FLOOR = Kit.FLOOR
local keysOf = Kit.keysOf
local lowestAt = Kit.lowestAt
local near = Kit.near
local placedAt = Kit.placedAt
local REAL = Kit.REAL
local realRun = Kit.realRun
local squat = Kit.squat
local turnBetween = Kit.turnBetween
local Validate = Kit.Validate

local check, case, finish = Kit.suite("floor")
case("clear_floor lifts a hand or foot to a clearance, and leaves the rest", function()
	-- Straight legs as the hips drop: the feet go into the floor.
	local original = squat(0.4)
	local clip = squat(0.4)
	local changed =
		realRun(clip, { { type = "clear_floor", part = "LeftFoot", time_from = 0, time_to = 1, clearance = 0.1 } })
	check("frames were lifted", (changed.frames_lifted or 0) > 20, changed.frames_lifted)
	local low, across, turned = math.huge, 0, 0
	for frame = 0, 30 do
		local time = frame / 30
		low = math.min(low, lowestAt(clip, time, { "LeftFoot" }))
		local before, after = placedAt(original, time).LeftFoot, placedAt(clip, time).LeftFoot
		across = math.max(
			across,
			math.abs(after.Position.X - before.Position.X) + math.abs(after.Position.Z - before.Position.Z)
		)
		turned = math.max(turned, turnBetween(after, before))
	end
	check("the foot never comes nearer the floor than the clearance", low > FLOOR + 0.1 - 0.004, low - FLOOR)
	-- Within what reducing the keys to a tenth of a degree allows at the foot.
	check("it only rose: across the floor it is where it was", across < 0.005, across)
	check("and turned as it was", turned < 0.15, turned)
	check(
		"the hips are not touched",
		difference({ placedAt(clip, 0.5).LowerTorso.Position.Y }, { placedAt(original, 0.5).LowerTorso.Position.Y })
			< 1e-9
	)

	-- Hips that rise: the foot is already clear, and nothing is written.
	local high = squat(-0.3)
	realRun(high, { { type = "set_key", joint = "LeftUpperLeg", time = 0.5, rotation = { 40, 0, 0 } } })
	local before = #keysOf(high, "LeftUpperLeg", "rotation.x")
	local clear = realRun(high, { { type = "clear_floor", part = "LeftFoot", time_from = 0.4, time_to = 0.6 } })
	check(
		"a part already clear is left alone",
		clear.frames_lifted == 0 and #keysOf(high, "LeftUpperLeg", "rotation.x") == before
	)
end)

case("place_on_floor lifts what sank, and leaves the rest", function()
	local clip = squat(0.8)
	check("before, the feet sink", lowestAt(clip, 0.5) < FLOOR - 0.7, lowestAt(clip, 0.5) - FLOOR)
	local changed = realRun(clip, { { type = "place_on_floor", time_from = 0, time_to = 1 } })
	check("frames were moved", (changed.frames_moved or 0) > 20, changed.frames_moved)
	check("by as much as the deepest sink", math.abs((changed.largest_raise_studs or 0) - 0.8) < 0.01)
	local worst = 0
	for frame = 0, 30 do
		worst = math.max(worst, math.abs(lowestAt(clip, frame / 30) - FLOOR))
	end
	check("after, the lowest part is on the floor at every frame", worst < 0.002, worst)

	local floating = blank()
	realRun(floating, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0.5, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0.5, 0 } },
	})
	local lifted = realRun(floating, { { type = "place_on_floor", time_from = 0, time_to = 1 } })
	check("lift leaves a body in the air where it is", lifted.frames_moved == 0, lifted.frames_moved)
	check("without writing a key", lifted.keys_written == nil, lifted.keys_written)
end)

case("place_on_floor with touch brings a floating body down, by the parts asked", function()
	local clip = blank()
	realRun(clip, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0.5, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 1.2, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, rotation = { 80, 0, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	local changed = realRun(clip, { { type = "place_on_floor", time_from = 0, time_to = 1, mode = "touch" } })
	check("it was lowered", (changed.largest_drop_studs or 0) > 0.4, changed.largest_drop_studs)
	local worst = 0
	for frame = 0, 30 do
		worst = math.max(worst, math.abs(lowestAt(clip, frame / 30) - FLOOR))
	end
	check("the lowest part touches the floor at every frame", worst < 0.002, worst)

	realRun(clip, {
		{ type = "place_on_floor", time_from = 0.5, time_to = 1, mode = "touch", parts = { "UpperTorso" } },
	})
	local torso = math.abs(lowestAt(clip, 1, { "UpperTorso" }) - FLOOR)
	check("by the parts asked: the upper torso rests on the floor", torso < 0.002, torso)

	local function refusedFloor(operation: any): boolean
		return (pcall(realRun, clip, { operation })) == false
	end
	check("an unknown mode", refusedFloor({ type = "place_on_floor", time_from = 0, time_to = 1, mode = "sink" }))
	check("an unknown part", refusedFloor({ type = "place_on_floor", time_from = 0, time_to = 1, parts = { "Tail" } }))
	check("past the end", refusedFloor({ type = "place_on_floor", time_from = 0, time_to = 3 }))
end)

case("contact with the floor is checked in a curve clip", function()
	local function validate(clip: any): any
		return Validate.run(clip, { joints = REAL }, assert(Validate.thresholds({})))
	end
	local standing = squat(0)
	local still = validate(standing)
	check("a rig standing still touches nothing wrong", still.warnings == 0, still.warnings)

	local sunk = validate(squat(0.8))
	check(
		"hips dropping on straight legs sink the feet; the lower legs are not measured",
		sunk.counts.BELOW_FLOOR == 2,
		sunk.counts.BELOW_FLOOR
	)
	local deepest
	for _, issue in sunk.issues do
		if issue.joints[1] == "LeftFoot" then
			deepest = issue
		end
	end
	check("by how much", deepest and math.abs(deepest.measured - 0.8) < 0.02, deepest and deepest.measured)
	check("and when", deepest and math.abs(deepest.time - 0.5) < 0.04, deepest and deepest.time)

	local sliding = squat(0, 0.6)
	local slid = validate(sliding)
	check("feet on the floor that move with the hips slide", slid.counts.FOOT_SLIDE == 2, slid.counts.FOOT_SLIDE)
	realRun(sliding, { { type = "pin", part = "LeftFoot", time_from = 0, time_to = 1 } })
	local after = validate(sliding)
	check("a pinned foot does not", after.counts.FOOT_SLIDE == 1, after.counts.FOOT_SLIDE)
	check("the other still does", after.issues[1] and after.issues[1].joints[1] == "RightFoot")

	local cycle = blank()
	realRun(cycle, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0, 0 }, interpolation = "Linear" },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0, 1.5 }, interpolation = "Linear" },
		{ type = "set_properties", loop = true },
	})
	-- A leg swinging through: with the hips where they are the foot brushes the floor as
	-- it passes under; raised a little, it passes over it.
	local function swing(raised: number): any
		local clip = blank()
		realRun(clip, {
			{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, raised, 0 } },
			{ type = "set_key", joint = "LowerTorso", time = 0.4, position = { 0, raised, 0 } },
			{ type = "set_key", joint = "LeftUpperLeg", time = 0, rotation = { -40, 0, 0 }, interpolation = "Linear" },
			{ type = "set_key", joint = "LeftUpperLeg", time = 0.4, rotation = { 40, 0, 0 }, interpolation = "Linear" },
			-- The foot kept level, so only its sole comes near the floor.
			{ type = "set_key", joint = "LeftFoot", time = 0, rotation = { 40, 0, 0 }, interpolation = "Linear" },
			{ type = "set_key", joint = "LeftFoot", time = 0.4, rotation = { -40, 0, 0 }, interpolation = "Linear" },
		})
		return clip
	end
	local function codes(found: any, foot: string): { [string]: number }
		local seen = {}
		for _, issue in found.issues do
			if issue.joints and issue.joints[1] == foot then
				seen[issue.code] = (seen[issue.code] or 0) + 1
			end
		end
		return seen
	end
	local brushed = codes(validate(swing(0)), "LeftFoot")
	check("a swinging foot that touches the floor scuffs", brushed.FOOT_SCUFF == 1, brushed.FOOT_SCUFF)
	check("and is not called a slide", brushed.FOOT_SLIDE == nil, brushed.FOOT_SLIDE)
	local passed = codes(validate(swing(0.06)), "LeftFoot")
	check("one passing just over the floor is neither", passed.FOOT_SCUFF == nil and passed.FOOT_SLIDE == nil)
	local onTheSpot = validate(cycle)
	-- A foot on a moving floor that lands on its heel and pushes off its toe, in a loop.
	local stepping = blank()
	realRun(stepping, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, -0.4, 0 } },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, -0.4, 0 } },
		{ type = "set_properties", loop = true },
		{
			type = "pin",
			part = "LeftFoot",
			time_from = 0,
			time_to = 0.2,
			pivot = "heel",
			roll = { 15, 0 },
			on_floor = true,
			travel = { 0, 0, 1 },
		},
		{ type = "pin", part = "LeftFoot", time_from = 0.2, time_to = 0.4, on_floor = true, travel = { 0, 0, 1 } },
		{
			type = "pin",
			part = "LeftFoot",
			time_from = 0.4,
			time_to = 0.6,
			pivot = "toe",
			roll = { 0, 20 },
			travel = { 0, 0, 1 },
		},
	})
	local rolled = validate(stepping)
	local leftSlides = 0
	for _, issue in rolled.issues do
		if issue.code == "FOOT_SLIDE" and issue.joints[1] == "LeftFoot" then
			leftSlides += 1
		end
	end
	check("rolling heel to toe on a moving floor in a loop is a cycle, not a slide", leftSlides == 0, leftSlides)
	check(
		"in a loop, feet moving back steadily are a cycle made on the spot",
		onTheSpot.counts.FOOT_SLIDE == nil and onTheSpot.counts.FOOT_SCUFF == nil,
		onTheSpot.counts
	)

	-- The same cycle with the left foot flicked forward along the floor for one frame, the
	-- foot kept level: the flick is a scuff, judged against the moving floor, and the rest
	-- of the plant is not.
	local flicked = blank()
	realRun(flicked, {
		{ type = "set_key", joint = "LowerTorso", time = 0, position = { 0, 0, 0 }, interpolation = "Linear" },
		{ type = "set_key", joint = "LowerTorso", time = 1, position = { 0, 0, 1.5 }, interpolation = "Linear" },
		{ type = "set_properties", loop = true },
	})
	for _, joint in { "LeftUpperLeg", "LeftFoot" } do
		local sign = if joint == "LeftFoot" then -1 else 1
		realRun(flicked, {
			{ type = "set_key", joint = joint, time = 0.4, rotation = { 0, 0, 0 }, interpolation = "Linear" },
			{ type = "set_key", joint = joint, time = 0.4333, rotation = { 8 * sign, 0, 0 }, interpolation = "Linear" },
			{ type = "set_key", joint = joint, time = 0.4667, rotation = { 0, 0, 0 }, interpolation = "Linear" },
		})
	end
	local found = validate(flicked)
	local scuffs = {}
	for _, issue in found.issues do
		if issue.code == "FOOT_SCUFF" then
			table.insert(scuffs, issue)
		end
	end
	local flick = scuffs[1]
	check("a flick on a moving floor is one scuff", #scuffs == 1 and flick.joints[1] == "LeftFoot", #scuffs)
	check(
		"at the frame it happens, not the whole plant",
		flick and math.abs(flick.time_from - 0.433) < 0.002 and math.abs(flick.time_to - 0.433) < 0.002,
		flick and `{flick.time_from} to {flick.time_to}`
	)
	check("at its own speed against the floor", flick and flick.measured > 7, flick and flick.measured)
	check(
		"and the message says the floor moves",
		flick and string.find(flick.message, "against the floor", 1, true) ~= nil,
		flick and flick.message
	)
	check("the scuff is not also called a slide", found.counts.FOOT_SLIDE == nil, found.counts.FOOT_SLIDE)
end)

finish()
