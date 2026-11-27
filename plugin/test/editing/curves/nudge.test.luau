--!strict
-- nudge: a hand or foot moved off its own path by an offset that eases in and out, the
-- part travelling on along its motion rather than held at a point.

local Kit = require("./kit")

local Limb = require("../../../src/Rigs/Limb")

local placedAt = Kit.placedAt
local realRun = Kit.realRun
local roblox = Kit.roblox

local check, case, finish = Kit.suite("nudge")

-- A kick: the right thigh swings up and back down over a second, the knee folding and
-- opening, so the foot moves fast through the middle.
local function kick(): any
	local clip = Kit.blank()
	realRun(clip, {
		{ type = "set_key", joint = "RightUpperLeg", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "RightUpperLeg", time = 0.5, rotation = { 80, 0, 0 } },
		{ type = "set_key", joint = "RightUpperLeg", time = 1, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "RightLowerLeg", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "RightLowerLeg", time = 0.3, rotation = { -70, 0, 0 } },
		{ type = "set_key", joint = "RightLowerLeg", time = 0.5, rotation = { -10, 0, 0 } },
		{ type = "set_key", joint = "RightLowerLeg", time = 1, rotation = { 0, 0, 0 } },
		{ type = "auto_tangents", time_from = 0, time_to = 1 },
	})
	return clip
end

local function smoothstep(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

case("the foot is moved by the offset, eased, and keeps travelling along its own path", function()
	local original = kick()
	local clip = kick()
	local offset = roblox.Vector3.new(0, 0.15, 0)
	local changed = realRun(clip, {
		{
			type = "nudge",
			part = "RightFoot",
			time_from = 0.3,
			time_to = 0.3,
			offset = { 0, 0.15, 0 },
			blend_in = 2 / 30,
			blend_out = 3 / 30,
		},
	})
	check("six frames are written, from 0.233 to 0.4", changed.frames_nudged == 6, changed.frames_nudged)
	check("all within reach", changed.frames_out_of_reach == nil, changed.largest_miss_studs)
	local worst, turned = 0, 0
	for frame = 7, 12 do
		local time = frame / 30
		local weight = if time <= 0.3 then smoothstep((time - 7 / 30) / (2 / 30)) else smoothstep((0.4 - time) / 0.1)
		local before = placedAt(original, time).RightFoot
		local after = placedAt(clip, time).RightFoot
		worst = math.max(worst, (after.Position - (before.Position + offset * weight)).Magnitude)
		local _, angle = (before.Rotation:Inverse() * after.Rotation):ToAxisAngle()
		turned = math.max(turned, math.abs(angle))
	end
	check("at every frame it is where its own path has it, moved by its share", worst < 1e-3, worst)
	check("without the foot turning", turned < 1e-3, math.deg(turned))
	local outside = 0
	for _, frame in { 0, 3, 6, 7, 12, 13, 20, 30 } do
		outside =
			math.max(outside, Kit.difference(Kit.sampleAll(clip, frame / 30), Kit.sampleAll(original, frame / 30)))
	end
	check("the frames at the ends of the blends and outside them are as they were", outside < 1e-6, outside)
	local others = 0
	for frame = 7, 12 do
		local a, b = placedAt(clip, frame / 30), placedAt(original, frame / 30)
		for _, part in { "LeftFoot", "LeftHand", "RightHand", "Head", "LowerTorso" } do
			others = math.max(others, (a[part].Position - b[part].Position).Magnitude)
		end
	end
	check("and nothing but the leg moves", others < 1e-6, others)
end)

case("with hold position, the foot turns with the leg instead", function()
	local original = kick()
	local clip = kick()
	realRun(clip, {
		{
			type = "nudge",
			part = "RightFoot",
			time_from = 0.3,
			time_to = 0.3,
			offset = { 0, 0.15, 0 },
			hold = "position",
		},
	})
	-- The ankle, the joint the foot turns about, is what is moved.
	local ankle = Kit.REAL.RightFoot
	local before = Limb.pivotOf(ankle, placedAt(original, 0.3).RightFoot)
	local after = Limb.pivotOf(ankle, placedAt(clip, 0.3).RightFoot)
	local moved = (after - before - roblox.Vector3.new(0, 0.15, 0)).Magnitude
	check("the ankle is where it is asked to be", moved < 1e-3, moved)
end)

case("with hold full the foot keeps its facing, with hold position it keeps its turn against the leg", function()
	local function footTurn(clip: any): { number }
		local values = {}
		for _, channel in { "rotation.x", "rotation.y", "rotation.z" } do
			table.insert(values, Kit.Curves.evaluate(Kit.keysOf(clip, "RightFoot", channel), 0.3))
		end
		return values
	end
	local original, full, position = kick(), kick(), kick()
	local lift = { type = "nudge", part = "RightFoot", time_from = 0.3, time_to = 0.3, offset = { 0, 0.15, 0 } }
	realRun(full, { lift })
	local held = table.clone(lift)
	held.hold = "position"
	realRun(position, { held })
	local before, kept, turned = footTurn(original), footTurn(position), footTurn(full)
	local same, differs = 0, 0
	for index = 1, 3 do
		same = math.max(same, math.abs(kept[index] - before[index]))
		differs = math.max(differs, math.abs(turned[index] - before[index]))
	end
	check("hold position leaves the ankle joint's own turn as it was", same < 1e-6, math.deg(same))
	check("hold full turns the ankle joint, to keep the foot's facing", differs > 1e-3, math.deg(differs))
end)

case("a hand is moved the same way", function()
	local function punch(): any
		local clip = Kit.blank()
		realRun(clip, {
			{ type = "set_key", joint = "RightUpperArm", time = 0, rotation = { 20, 0, 0 } },
			{ type = "set_key", joint = "RightUpperArm", time = 0.5, rotation = { 85, 0, 0 } },
			{ type = "set_key", joint = "RightUpperArm", time = 1, rotation = { 20, 0, 0 } },
			{ type = "set_key", joint = "RightLowerArm", time = 0, rotation = { 90, 0, 0 } },
			{ type = "set_key", joint = "RightLowerArm", time = 0.5, rotation = { 10, 0, 0 } },
			{ type = "set_key", joint = "RightLowerArm", time = 1, rotation = { 90, 0, 0 } },
			{ type = "auto_tangents", time_from = 0, time_to = 1 },
		})
		return clip
	end
	local original, clip = punch(), punch()
	realRun(clip, {
		{
			type = "nudge",
			part = "RightHand",
			time_from = 0.4,
			time_to = 0.4,
			offset = { 0, 0.1, 0 },
			blend_in = 0.1,
			blend_out = 0.1,
		},
	})
	local moved = (
		placedAt(clip, 0.4).RightHand.Position
		- placedAt(original, 0.4).RightHand.Position
		- roblox.Vector3.new(0, 0.1, 0)
	).Magnitude
	check("the hand is where it is asked to be", moved < 1e-3, moved)
end)

case("soft eases in with the offset, so a limb at full stretch doesn't jump", function()
	-- At rest the legs are straight: at full stretch, where soft acts.
	local clip = Kit.blank()
	realRun(clip, {
		{ type = "set_key", joint = "LeftUpperArm", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "LeftUpperArm", time = 1, rotation = { 0, 0, 0 } },
	})
	local before = placedAt(clip, 4 / 30).RightFoot.Position
	realRun(clip, {
		{
			type = "nudge",
			part = "RightFoot",
			time_from = 0.4,
			time_to = 0.4,
			offset = { 0, 0.015, 0 },
			blend_in = 0.3,
			soft = 0.1,
		},
	})
	local jump = (placedAt(clip, 4 / 30).RightFoot.Position - before).Magnitude
	check("the first frame of the blend moves the foot by about its share, not by the softening", jump < 0.01, jump)
end)

case("a point too near for the limb to fold to is reported out of reach", function()
	local clip = kick()
	-- A longer shin, so the leg can't fold its ankle up to the hip.
	realRun(clip, { { type = "set_key", joint = "RightLowerLeg", time = 0.5, position = { 0, -0.4, 0 } } })
	-- The ankle sent to the hip itself, nearer than the leg can fold to.
	local placed = placedAt(clip, 0.5)
	local hip = Limb.pivotOf(Kit.REAL.RightUpperLeg, placed.RightUpperLeg)
	local ankle = Limb.pivotOf(Kit.REAL.RightFoot, placed.RightFoot)
	local toHip = hip - ankle
	local changed = realRun(clip, {
		{
			type = "nudge",
			part = "RightFoot",
			time_from = 0.5,
			time_to = 0.5,
			offset = { toHip.X, toHip.Y, toHip.Z },
		},
	})
	check("as out of reach", (changed.frames_out_of_reach or 0) > 0, changed.largest_miss_studs)
	check("not as softened", changed.largest_soft_studs == nil, changed.largest_soft_studs)
end)

case("a guard key never goes past the clip's end", function()
	local clip = Kit.blank()
	realRun(clip, {
		{ type = "set_key", joint = "RightUpperLeg", time = 0, rotation = { 0, 0, 0 } },
		{ type = "set_key", joint = "RightUpperLeg", time = 0.98, rotation = { 40, 0, 0 } },
	})
	realRun(
		clip,
		{ { type = "nudge", part = "RightFoot", time_from = 29 / 30, time_to = 29 / 30, offset = { 0, 0.05, 0 } } }
	)
	check("the clip is as long as it was", math.abs(Kit.Curves.duration(clip) - 0.98) < 1e-6, Kit.Curves.duration(clip))
end)

case("what nudge refuses", function()
	local function refused(operation: any): boolean
		return not pcall(realRun, kick(), { operation })
	end
	check(
		"a part that is not a hand or foot",
		refused({ type = "nudge", part = "Head", time_from = 0.3, time_to = 0.3, offset = { 0, 0.1, 0 } })
	)
	check("no offset", refused({ type = "nudge", part = "RightFoot", time_from = 0.3, time_to = 0.3 }))
	check(
		"an offset of the wrong shape",
		refused({ type = "nudge", part = "RightFoot", time_from = 0.3, time_to = 0.3, offset = { 0, 0.1 } })
	)
	check(
		"a range past the end",
		refused({ type = "nudge", part = "RightFoot", time_from = 0.3, time_to = 5, offset = { 0, 0.1, 0 } })
	)
end)

finish()
