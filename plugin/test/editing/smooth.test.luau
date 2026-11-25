--!strict
-- Offline tests for the smooth curve through a joint's keys.
-- Run with: lune run plugin/test/editing/smooth.test.luau
--
-- Real here: the arithmetic of the curve, on plain numbers. Not tested here: how the
-- result looks when Studio plays it, which is for a person to judge.

local process = require("@lune/process")

local Smooth = require("../../src/Editing/Smooth")

local failures = 0
local count = 0
local current = ""

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL [{current}] {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

local function case(name: string, run: () -> ())
	current = name
	local ok, problem = pcall(run)
	if not ok then
		count += 1
		failures += 1
		print(`FAIL [{name}] raised: {tostring(problem)}`)
	end
end

-- Keys of one number each, from pairs of time and value.
local function keys(pairs: { { number } }): { Smooth.Key }
	local list = {}
	for _, pair in pairs do
		table.insert(list, { time = pair[1], values = { pair[2] } })
	end
	return list
end

-- The curve at `steps` evenly spread times from the first key to the last.
local function curve(list: { Smooth.Key }, steps: number, options: Smooth.Options?): ({ number }, { number })
	local times = {}
	local first, last = list[1].time, list[#list].time
	for index = 0, steps do
		times[index + 1] = first + (last - first) * index / steps
	end
	local values = {}
	for index, sample in Smooth.sample(list, times, options) do
		values[index] = sample[1]
	end
	return values, times
end

-- The speed over each step, and the largest change of speed from one step to the next.
local function speeds(values: { number }, times: { number }): ({ number }, number)
	local list = {}
	for index = 2, #values do
		list[index - 1] = (values[index] - values[index - 1]) / (times[index] - times[index - 1])
	end
	local jump = 0
	for index = 2, #list do
		jump = math.max(jump, math.abs(list[index] - list[index - 1]))
	end
	return list, jump
end

local function near(a: number, b: number, within: number?): boolean
	return math.abs(a - b) <= (within or 1e-9)
end

case("the curve passes through every key", function()
	local list = keys({ { 0, 0 }, { 0.2, 5 }, { 0.5, 3 }, { 1, 9 } })
	local times = { 0, 0.2, 0.5, 1 }
	local samples = Smooth.sample(list, times)
	for index, key in list do
		check(`at {key.time} seconds`, near(samples[index][1], key.values[1]), samples[index][1])
	end
end)

case("steady motion stays a straight line", function()
	local values = curve(keys({ { 0, 0 }, { 1, 2 }, { 2, 4 }, { 3, 6 } }), 30)
	local middle = true
	for index = 11, 21 do
		middle = middle and near(values[index], (index - 1) * 0.2, 1e-9)
	end
	check("between its inner keys it is exactly the line", middle)
	-- At its two ends it starts from rest and comes to rest.
	check("it starts slower than the line", values[2] < 0.2 - 1e-6, values[2])
	check("and ends slower than the line", values[30] > 5.8 + 1e-6, values[30])
end)

case("a key the motion passes through is passed at speed", function()
	-- From 0 up to 10, by way of 4: all one direction.
	local list = keys({ { 0, 0 }, { 0.5, 4 }, { 1, 10 } })
	local values, times = curve(list, 100)
	local list2 = speeds(values, times)
	check("the speed at the middle key is not nought", list2[50] > 5, list2[50])
	check("and is the same on both sides of it", near(list2[50], list2[51], 0.5), `{list2[50]} {list2[51]}`)
	local rising = true
	for index = 2, #values do
		rising = rising and values[index] >= values[index - 1] - 1e-12
	end
	check("it never goes backwards", rising)
end)

case("a key where the motion turns round is come to rest at, without going past it", function()
	local list = keys({ { 0, 0 }, { 0.5, 10 }, { 1, 2 }, { 1.5, 6 } })
	local values, times = curve(list, 150)
	local highest, lowest = -math.huge, math.huge
	for index, value in values do
		highest = math.max(highest, value)
		if times[index] > 0.5 then
			lowest = math.min(lowest, value)
		end
	end
	check("it does not rise past the key at the top", highest <= 10 + 1e-9, highest)
	check("nor fall past the key at the bottom", lowest >= 2 - 1e-9, lowest)
	local list2 = speeds(values, times)
	-- Against an average of 20 a second on the way up.
	check("it is nearly still at the top", math.abs(list2[50]) < 2 and math.abs(list2[51]) < 2, list2[50])
end)

case("the speed is continuous where straight stretches would turn a corner", function()
	local list = keys({ { 0, 0 }, { 0.3, 2 }, { 0.5, 8 }, { 1, 10 } })
	local values, times = curve(list, 200)
	local _, smoothJump = speeds(values, times)
	-- The same keys joined by straight lines.
	local straight = {}
	for index, time in times do
		local a, b = list[1], list[2]
		for key = 2, #list do
			if time <= list[key].time + 1e-12 then
				a, b = list[key - 1], list[key]
				break
			end
		end
		straight[index] = a.values[1] + (b.values[1] - a.values[1]) * (time - a.time) / (b.time - a.time)
	end
	local _, straightJump = speeds(straight, times)
	check("straight stretches jump in speed at the keys", straightJump > 20, straightJump)
	check("the curve changes speed a little at a time", smoothJump < straightJump / 5, smoothJump)
end)

case("a snap arrives fast and stops dead", function()
	local list = keys({ { 0, 0 }, { 0.2, 10 }, { 0.6, 8 } })
	local eased, times = curve(list, 300)
	local snapped = curve(list, 300, { snap = { [2] = true } })
	local easedSpeeds = speeds(eased, times)
	local snappedSpeeds = speeds(snapped, times)
	-- The key is at sample 101: the stretch before it ends at speed index 100.
	check("eased, it is nearly still as it arrives", math.abs(easedSpeeds[100]) < 2, easedSpeeds[100])
	check("snapped, it arrives at well over its average speed", snappedSpeeds[100] > 100, snappedSpeeds[100])
	check("about two and a half times it", near(snappedSpeeds[100], Smooth.SNAP * 50, 4), snappedSpeeds[100])
	check("and leaves from rest", math.abs(snappedSpeeds[101]) < 1, snappedSpeeds[101])
	local highest = 0
	for _, value in snapped do
		highest = math.max(highest, value)
	end
	check("without going past the key", highest <= 10 + 1e-9, highest)
	check(
		"a snap on the first key changes nothing",
		curve(list, 20, { snap = { [1] = true } })[5] == curve(list, 20)[5]
	)
end)

case("a loop carries its speed across the join", function()
	-- A cycle that is on its way down at both ends: 5, up to 9, down to 1, back to 5.
	local list = keys({ { 0, 5 }, { 0.25, 9 }, { 0.75, 1 }, { 1, 5 } })
	local open, times = curve(list, 200)
	local closed = curve(list, 200, { loop = true })
	local openSpeeds = speeds(open, times)
	local closedSpeeds = speeds(closed, times)
	check("not looping, it starts from rest", math.abs(openSpeeds[1]) < 1, openSpeeds[1])
	check("looping, it is already moving", closedSpeeds[1] > 4, closedSpeeds[1])
	check(
		"at the speed it ends with",
		near(closedSpeeds[1], closedSpeeds[#closedSpeeds], 0.5),
		`{closedSpeeds[1]} {closedSpeeds[#closedSpeeds]}`
	)
	check("and still passes through the keys", near(closed[1], 5) and near(closed[51], 9) and near(closed[201], 5))
	-- Ends that turn round are still come to rest at.
	local bounce = keys({ { 0, 0 }, { 0.5, 9 }, { 1, 0 } })
	local bounced, bounceTimes = curve(bounce, 100, { loop = true })
	-- Against an average of 18 a second on the way up.
	check("a loop that turns round at the join rests there", math.abs(speeds(bounced, bounceTimes)[1]) < 2)
end)

case("each number has its own curve, and two keys alone make an eased move", function()
	local list = { { time = 0, values = { 0, 10, 5 } }, { time = 1, values = { 4, 10, -5 } } }
	local samples = Smooth.sample(list, { 0, 0.25, 0.5, 0.75, 1 })
	check("a number that does not change stays put", samples[2][2] == 10 and samples[4][2] == 10)
	check("half way in time is half way there", near(samples[3][1], 2) and near(samples[3][3], 0))
	check("slow at the start", samples[2][1] < 1, samples[2][1])
	check("and at the end", samples[4][1] > 3, samples[4][1])
end)

print(`{count - failures}/{count} smoothing checks passed`)
if failures > 0 then
	process.exit(1)
end
