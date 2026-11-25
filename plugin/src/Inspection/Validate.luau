--!strict
-- Checks on a clip. Each finding is a measurement with the limit it was held to, never a
-- judgement of whether the motion looks right.
--
-- An error means the clip is not structurally sound: the engine may play it wrongly, and
-- it cannot be saved. A warning is a number worth looking at: the clip is sound, and
-- saving is never refused for one.
--
-- Everything here only reads the KeyframeSequence it is given.

local Curves = require("../Editing/Curves")
local Operations = require("../Editing/Operations")
local Rig = require("../Rigs/Rig")

local Validate = {}

-- Most findings listed in one result. The counts are always of all of them.
Validate.MAX_ISSUES = 50

-- Limits a caller may override. A loop is held to how far its last keyframe is from its
-- first; an abrupt change is a joint moving faster than this between two keyframes.
Validate.DEFAULTS = {
	loop_rotation_degrees = 2,
	loop_position_studs = 0.02,
	speed_degrees_per_second = 2000,
	speed_studs_per_second = 40,
}

export type Context = {
	-- The rig's joints by the name of the driven part.
	joints: { [string]: any },
	-- Joints that follow a clip through forces, so the rendered pose can differ from it.
	nonKinematic: { [string]: boolean }?,
}

export type Issue = {
	code: string,
	severity: "error" | "warning",
	message: string,
	joints: { string }?,
	time: number?,
	time_from: number?,
	time_to: number?,
	measured: number?,
	threshold: number?,
	unit: string?,
}

local function milliseconds(time: number): number
	return math.round(time * 1000) / 1000
end

local function rounded(value: number): number
	return math.round(value * 1000) / 1000
end

local function finite(value: number): boolean
	return value == value and math.abs(value) ~= math.huge
end

-- The angle between two rotations, in degrees, in a form that stays exact when small.
local function turn(a: CFrame, b: CFrame): number
	local squares = (a.RightVector - b.RightVector).Magnitude ^ 2
		+ (a.UpVector - b.UpVector).Magnitude ^ 2
		+ (a.LookVector - b.LookVector).Magnitude ^ 2
	return math.deg(2 * math.asin(math.min(1, math.sqrt(squares / 8))))
end

-- Reads the limits a caller gave over the defaults. Returns nil and what is wrong with
-- them if they cannot be used.
function Validate.thresholds(given: any): ({ [string]: number }?, string?)
	local thresholds = table.clone(Validate.DEFAULTS)
	if given == nil then
		return thresholds, nil
	elseif type(given) ~= "table" then
		return nil, "thresholds must be an object."
	end
	for name, value in given do
		if thresholds[name] == nil then
			return nil, `"{tostring(name)}" is not a threshold.`
		elseif type(value) ~= "number" or not finite(value) or value <= 0 then
			return nil, `{name} must be a number above 0.`
		end
		thresholds[name] = value
	end
	return thresholds, nil
end

function Validate.run(sequence: Instance, context: Context, thresholds: { [string]: number }): { [string]: any }
	local clip = sequence :: any
	local issues: { Issue } = {}
	local function report(issue: Issue)
		table.insert(issues, issue)
	end

	-- A clip made of curves has checks of its own; what follows is for keyframe clips.
	if sequence:IsA("CurveAnimation") then
		Curves.validate(sequence, context.joints, context.nonKinematic, thresholds, report)
	else
		local keyframes = Operations.keyframes(sequence)

		-- The clip as a whole.
		if #keyframes > Operations.MAX_KEYFRAMES then
			report({
				code = "TOO_MANY_KEYFRAMES",
				severity = "error",
				message = `The clip has {#keyframes} keyframes; the most supported is {Operations.MAX_KEYFRAMES}.`,
				measured = #keyframes,
				threshold = Operations.MAX_KEYFRAMES,
				unit = "keyframes",
			})
		end
		local otherContent = 0
		for _, descendant in sequence:GetDescendants() do
			if not (descendant:IsA("Keyframe") or descendant:IsA("Pose") or descendant:IsA("KeyframeMarker")) then
				otherContent += 1
			end
		end
		if otherContent > 0 then
			report({
				code = "OTHER_CONTENT",
				severity = "warning",
				message = `The clip holds {otherContent} instances that are kept but cannot be edited or checked here.`,
				measured = otherContent,
				unit = "instances",
			})
		end

		-- Each keyframe by itself. `keyed` collects, for each joint, its poses in time order.
		local keyed: { [string]: { { time: number, cframe: CFrame } } } = {}
		local earlier: Keyframe? = nil
		for _, keyframe in keyframes do
			local time = keyframe.Time
			local shown = milliseconds(time)
			if not finite(time) or time < 0 or time > Operations.MAX_TIME then
				report({
					code = "INVALID_KEYFRAME_TIME",
					severity = "error",
					message = `A keyframe is at {time} seconds, outside 0 to {Operations.MAX_TIME}.`,
					time = if finite(time) then shown else nil,
					measured = if finite(time) then time else nil,
					threshold = Operations.MAX_TIME,
					unit = "seconds",
				})
			end
			if earlier and math.abs(time - earlier.Time) < Operations.TIME_TOLERANCE then
				report({
					code = "DUPLICATE_KEYFRAME",
					severity = "error",
					message = `Two keyframes are at {shown} seconds. Which one plays is not defined.`,
					time = shown,
				})
			end
			earlier = keyframe

			local seen: { [string]: boolean } = {}
			for _, descendant: any in keyframe:GetDescendants() do
				if not descendant:IsA("Pose") then
					continue
				end
				local name = descendant.Name
				local weighted = descendant.Weight > 0
				if seen[name] then
					report({
						code = "DUPLICATE_POSE",
						severity = "error",
						message = `"{name}" has more than one pose at {shown} seconds.`,
						joints = { name },
						time = shown,
					})
				end
				seen[name] = true

				local components = { descendant.CFrame:GetComponents() }
				local sound = true
				for _, value in components do
					sound = sound and finite(value)
				end
				if not sound then
					report({
						code = "NON_FINITE_TRANSFORM",
						severity = "error",
						message = `The pose of "{name}" at {shown} seconds holds a number that is not finite.`,
						joints = { name },
						time = shown,
					})
				elseif descendant.CFrame.Position.Magnitude > Operations.MAX_POSITION then
					report({
						code = "POSITION_OUT_OF_RANGE",
						severity = "error",
						message = `The pose of "{name}" at {shown} seconds is {rounded(
							descendant.CFrame.Position.Magnitude
						)} studs from rest.`,
						joints = { name },
						time = shown,
						measured = rounded(descendant.CFrame.Position.Magnitude),
						threshold = Operations.MAX_POSITION,
						unit = "studs",
					})
				end

				if not weighted then
					continue
				end
				if not context.joints[name] then
					-- The root part is posed by some tools; it has no joint and nothing moves.
					if name ~= Rig.ROOT then
						report({
							code = "UNKNOWN_JOINT",
							severity = "error",
							message = `"{name}" is posed at {shown} seconds, but the rig has no such joint.`,
							joints = { name },
							time = shown,
						})
					end
					continue
				end
				local parent = descendant.Parent
				local expected = Rig.R15_PARENTS[name]
				if expected and parent and parent:IsA("Pose") and parent.Name ~= expected then
					report({
						code = "POSE_HIERARCHY",
						severity = "warning",
						message = `At {shown} seconds the pose of "{name}" sits under "{parent.Name}", not under "{expected}" as in the rig.`,
						joints = { name },
						time = shown,
					})
				end
				if sound then
					keyed[name] = keyed[name] or {}
					table.insert(keyed[name], { time = time, cframe = descendant.CFrame })
				end
			end
		end

		-- Each joint across time.
		local first, last = keyframes[1], keyframes[#keyframes]
		for name, poses in keyed do
			if context.nonKinematic and context.nonKinematic[name] then
				report({
					code = "NON_KINEMATIC_JOINT",
					severity = "warning",
					message = `"{name}" is driven through forces (IsKinematic is off), so what is rendered can differ from the clip.`,
					joints = { name },
				})
			end

			for index = 2, #poses do
				local before, after = poses[index - 1], poses[index]
				local seconds = after.time - before.time
				if seconds < Operations.TIME_TOLERANCE then
					continue
				end
				local span = { time_from = milliseconds(before.time), time_to = milliseconds(after.time) }
				local angular = turn(before.cframe, after.cframe) / seconds
				if angular > thresholds.speed_degrees_per_second then
					report({
						code = "ABRUPT_ROTATION",
						severity = "warning",
						message = `"{name}" turns at {rounded(angular)} degrees per second between {span.time_from} and {span.time_to} seconds.`,
						joints = { name },
						time_from = span.time_from,
						time_to = span.time_to,
						measured = rounded(angular),
						threshold = thresholds.speed_degrees_per_second,
						unit = "degrees per second",
					})
				end
				local linear = (after.cframe.Position - before.cframe.Position).Magnitude / seconds
				if linear > thresholds.speed_studs_per_second then
					report({
						code = "ABRUPT_MOVE",
						severity = "warning",
						message = `"{name}" moves at {rounded(linear)} studs per second between {span.time_from} and {span.time_to} seconds.`,
						joints = { name },
						time_from = span.time_from,
						time_to = span.time_to,
						measured = rounded(linear),
						threshold = thresholds.speed_studs_per_second,
						unit = "studs per second",
					})
				end
			end

			-- A loop runs from its last keyframe straight back into its first.
			if clip.Loop == true and first and last and first ~= last then
				local start, finish = poses[1], poses[#poses]
				if
					math.abs(start.time - first.Time) < Operations.TIME_TOLERANCE
					and math.abs(finish.time - last.Time) < Operations.TIME_TOLERANCE
				then
					local span = { time_from = milliseconds(first.Time), time_to = milliseconds(last.Time) }
					local degrees = turn(start.cframe, finish.cframe)
					if degrees > thresholds.loop_rotation_degrees then
						report({
							code = "LOOP_ROTATION_MISMATCH",
							severity = "warning",
							message = `"{name}" ends {rounded(degrees)} degrees from where it starts, so the loop will jump.`,
							joints = { name },
							time_from = span.time_from,
							time_to = span.time_to,
							measured = rounded(degrees),
							threshold = thresholds.loop_rotation_degrees,
							unit = "degrees",
						})
					end
					local studs = (finish.cframe.Position - start.cframe.Position).Magnitude
					if studs > thresholds.loop_position_studs then
						report({
							code = "LOOP_POSITION_MISMATCH",
							severity = "warning",
							message = `"{name}" ends {rounded(studs)} studs from where it starts, so the loop will jump.`,
							joints = { name },
							time_from = span.time_from,
							time_to = span.time_to,
							measured = rounded(studs),
							threshold = thresholds.loop_position_studs,
							unit = "studs",
						})
					end
				end
			end
		end
	end

	-- Errors first, then by time, then by code and joint, so that the same clip always
	-- gives the same list.
	local function at(issue: Issue): number
		return issue.time or issue.time_from or -1
	end
	table.sort(issues, function(a, b)
		if a.severity ~= b.severity then
			return a.severity == "error"
		elseif at(a) ~= at(b) then
			return at(a) < at(b)
		elseif a.code ~= b.code then
			return a.code < b.code
		end
		return (a.joints and a.joints[1] or "") < (b.joints and b.joints[1] or "")
	end)

	local counts: { [string]: number } = {}
	local errors, warnings = 0, 0
	for _, issue in issues do
		counts[issue.code] = (counts[issue.code] or 0) + 1
		if issue.severity == "error" then
			errors += 1
		else
			warnings += 1
		end
	end
	local listed = table.move(issues, 1, math.min(#issues, Validate.MAX_ISSUES), 1, {})
	return {
		valid = errors == 0,
		errors = errors,
		warnings = warnings,
		counts = counts,
		issues = listed,
		issues_truncated = if #issues > #listed then true else nil,
		thresholds = thresholds,
	}
end

return Validate
