--!strict
-- copy_pose from another clip of the same rig: a revised guard carried into an attack,
-- the joints named taking the other clip's pose and everything else left as it was.

local Kit = require("./kit")

local Curves = Kit.Curves
local Digest = Kit.Digest
local keysOf = Kit.keysOf
local lopsided = Kit.lopsided
local squat = Kit.squat

local check, case, finish = Kit.suite("copypose")

local function value(clip: any, joint: string, channel: string, time: number): number
	return Curves.evaluate(keysOf(clip, joint, channel), time)
end

local function run(clip: any, operations: { any }, clips: { [string]: any }): { [string]: number }
	Curves.check(operations, Kit.REAL)
	return Curves.run(clip, operations, { joints = Kit.REAL, clips = clips })
end

local function sameKeys(a: { any }, b: { any }): boolean
	if #a ~= #b then
		return false
	end
	for index, key in a do
		local other = b[index]
		if
			math.abs(key.time - other.time) > 1e-9
			or key.value ~= other.value
			or key.interpolation ~= other.interpolation
			or key.left ~= other.left
			or key.right ~= other.right
		then
			return false
		end
	end
	return true
end

local COPIED = { "UpperTorso", "LeftUpperArm", "LeftLowerArm" }

case("the joints named take the other clip's pose, and nothing else changes", function()
	local ready = lopsided()
	local readyBefore = Digest.of(ready)
	local jab = squat(0.6)
	local untouched = squat(0.6)
	run(jab, {
		{
			type = "copy_pose",
			from_clip = "saved:Ready",
			from = 0.5,
			to = 0.2,
			joints = COPIED,
			channels = { "rotation" },
		},
	}, { ["saved:Ready"] = ready })
	local worst = 0
	for _, joint in COPIED do
		for _, channel in { "rotation.x", "rotation.y", "rotation.z" } do
			worst = math.max(worst, math.abs(value(jab, joint, channel, 0.2) - value(ready, joint, channel, 0.5)))
		end
	end
	check("each joint named matches the other clip at that time", worst < 1e-9, worst)
	local copied: { [string]: boolean } = {}
	for _, joint in COPIED do
		copied[joint] = true
	end
	local changed = {}
	for _, joint in Kit.Rig.R15_ORDER do
		for _, channel in Curves.CHANNELS do
			local named = copied[joint] and string.sub(channel, 1, 8) == "rotation"
			if not named and not sameKeys(keysOf(jab, joint, channel), keysOf(untouched, joint, channel)) then
				table.insert(changed, `{joint} {channel}`)
			end
		end
	end
	check("every other channel keeps its keys, key for key", #changed == 0, table.concat(changed, ", "))
	check("and the clip copied from is only read", Digest.of(ready) == readyBefore)
end)

case("a channel this clip animates that the other leaves at rest goes to rest", function()
	-- Without it, part of the old pose would stay: the head still turned on Y.
	-- Only the head's X keyed: set_key would key all three axes.
	local ready = Kit.blank()
	Curves.setKeys(Curves.channel(ready, "Head", "rotation.x", true), {
		{ time = 0, value = math.rad(20), interpolation = "Linear" },
		{ time = 1, value = math.rad(20), interpolation = "Linear" },
	})
	local jab = Kit.blank()
	Kit.realRun(jab, {
		{ type = "set_key", joint = "Head", time = 0, rotation = { 0, 45, 0 } },
		{ type = "set_key", joint = "Head", time = 0.5, rotation = { 0, 45, 0 } },
	})
	run(
		jab,
		{ { type = "copy_pose", from_clip = "saved:Ready", from = 0, to = 0.5, joints = { "Head" } } },
		{ ["saved:Ready"] = ready }
	)
	check(
		"the turn the other clip has is copied",
		math.abs(math.deg(value(jab, "Head", "rotation.x", 0.5)) - 20) < 1e-6
	)
	check(
		"and the one it does not have is gone",
		math.abs(value(jab, "Head", "rotation.y", 0.5)) < 1e-9,
		math.deg(value(jab, "Head", "rotation.y", 0.5))
	)
end)

case("a pose sampled from a keyframe clip is copied without its length counted", function()
	-- edit_animation samples a keyframe clip with the engine into a clip made for it, with
	-- keys only where a joint is away from rest; one at rest throughout has none at all.
	local holder = Kit.Instance.new("CurveAnimation")
	holder:SetAttribute(Curves.SAMPLED, true)
	local jab = squat(0.6)
	local ok, problem = pcall(run, jab, {
		{
			type = "copy_pose",
			from_clip = "saved:Guard",
			from = 0.4,
			to = 0.2,
			joints = { "LowerTorso" },
			channels = { "position" },
		},
	}, { ["saved:Guard"] = holder })
	check(
		"a pose at rest is copied, not refused as past the end",
		ok,
		if type(problem) == "table" then problem.message else problem
	)
	check(
		"as rest",
		math.abs(value(jab, "LowerTorso", "position.y", 0.2)) < 1e-9,
		value(jab, "LowerTorso", "position.y", 0.2)
	)
end)

case("a curve has a key's own value at its time, after a Constant stretch too", function()
	local keys = {
		{ time = 0, value = 0, interpolation = "Constant" },
		{ time = 0.5, value = 1, interpolation = "Linear" },
		{ time = 1, value = 2, interpolation = "Linear" },
	}
	check("before the key, the step holds", Curves.evaluate(keys, 0.49) == 0)
	check("at the key, the curve is where the step lands", Curves.evaluate(keys, 0.5) == 1, Curves.evaluate(keys, 0.5))
end)

case("what copying from another clip refuses", function()
	local ready = lopsided()
	local refused = function(operation: any, clips: any): boolean
		return not pcall(run, squat(0.6), { operation }, clips)
	end
	check(
		"a clip that was not found",
		refused({ type = "copy_pose", from_clip = "saved:Nowhere", from = 0, to = 0.2 }, {})
	)
	check(
		"a time past the end of the clip copied from",
		refused({ type = "copy_pose", from_clip = "saved:Ready", from = 5, to = 0.2 }, { ["saved:Ready"] = ready })
	)
	check("an empty name", refused({ type = "copy_pose", from_clip = "", from = 0, to = 0.2 }, {}))
end)

finish()
