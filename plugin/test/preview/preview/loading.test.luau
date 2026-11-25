--!strict
-- Sampling clips as they load and at their edges: loading, never loading, no length, one keyframe, past the end.
-- Run with: lune run plugin/test/preview/preview/loading.test.luau

local Kit = require("./kit")

local buildRig = Kit.buildRig
local checkUntouched = Kit.checkUntouched
local Curves = Kit.Curves
local CurveStore = Kit.CurveStore
local expectError = Kit.expectError
local Instance = Kit.Instance
local newWorld = Kit.newWorld
local Preview = Kit.Preview
local request = Kit.request
local roblox = Kit.roblox
local Sampler = Kit.Sampler
local snapshot = Kit.snapshot

local check, case, finish = Kit.suite("preview loading")
case("a clip that is still loading is sampled only once it has loaded", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	world.loadAfter = 0.1
	local result = Preview.run(request(rig))
	check("the sample is the clip's pose, not the rest pose", result.transforms.Head.X == 0.5, result.transforms.Head)
	check("the preview waited for the clip", world.now >= 0.1, world.now)
	checkUntouched(world, rig, before)
end)

case("a curve clip with no length is sampled through a copy padded by a curve that moves nothing", function()
	-- Keys are kept in an attribute here, as in the curve tests; Studio keeps them itself.
	local serde = require("@lune/serde")
	local Roblox = require("../../../src/Core/Roblox") :: any
	Roblox.Instance, Roblox.CFrame, Roblox.Enum = roblox.Instance, roblox.CFrame, roblox.Enum
	CurveStore.backend = {
		keys = function(curve)
			local text = curve:GetAttribute("Keys")
			return if text then serde.decode("json", text) else {}
		end,
		setKeys = function(curve, keys)
			curve:SetAttribute("Keys", serde.encode("json", keys))
		end,
		markers = function()
			return {}
		end,
		setMarkers = function() end,
	}
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	for _, clip in { Instance.new("CurveAnimation"), Instance.new("CurveAnimation") } do
		if #world.destroyed > 0 then
			-- The second clip has keys, all at time zero.
			Curves.setKeys(Curves.channel(clip, "Head", "rotation.y", true) :: any, {
				{ time = 0, value = 0.5, interpolation = "Cubic", left = 0, right = 0 },
			})
		end
		local result = Preview.run(request(rig, { sequence = clip, time = 0 }))
		check("the sample is returned", result.transforms.Head ~= nil)
		check("a copy was played, not the clip", world.registered ~= clip and world.registered ~= nil)
		check("the copy had a length", world.registeredLength == Sampler.PAD_SECONDS, world.registeredLength)
		check(
			"padded by a folder named after no part",
			world.registeredPadded and rig.model:FindFirstChild(Sampler.PAD_NAME, true) == nil
		)
		check("the clip itself was not changed", clip:FindFirstChild(Sampler.PAD_NAME) == nil)
		check("the copy was destroyed", table.find(world.destroyed, world.registered) ~= nil)
		checkUntouched(world, rig, before)
	end
	CurveStore.backend = nil
end)

case("a clip that never loads fails closed and cleans up", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	world.neverLoads = true
	local problem = expectError(function()
		return Preview.run(request(rig))
	end)
	check("it fails closed", problem.code == "PREVIEW_UNAVAILABLE", problem.code)
	check("it names loading", string.find(problem.message or "", "loading") ~= nil, problem.message)
	check("it gave up within the load budget", world.now <= Sampler.LOAD_BUDGET + 1, world.now)
	checkUntouched(world, rig, before)
end)

case("a clip whose only keyframe is at time zero is sampled through a padded copy", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local sequence = Instance.new("KeyframeSequence")
	local keyframe = Instance.new("Keyframe")
	keyframe.Time = 0
	keyframe.Parent = sequence
	local result = Preview.run(request(rig, { sequence = sequence, time = 0 }))
	check("the sample is returned", result.transforms.Head ~= nil)
	check("a copy was played, not the clip", world.registered ~= sequence and world.registered ~= nil)
	check("the copy had a length", world.registeredLength == Sampler.PAD_SECONDS, world.registeredLength)
	check("the clip itself was not changed", #sequence:GetChildren() == 1, #sequence:GetChildren())
	check("the copy was destroyed", table.find(world.destroyed, world.registered) ~= nil)
	checkUntouched(world, rig, before)

	-- Past the only keyframe there is nothing of the clip to sample.
	local late = Preview.run(request(rig, { sequence = sequence, time = 0.5 }))
	check("a later time is held at the last keyframe", late.transforms.Head.X == 0, late.transforms.Head)
	checkUntouched(world, rig, before)
end)

case("a time past the end of a clip is held at its last keyframe", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(request(rig, { time = 5 }))
	check("the sample is taken at the last keyframe", result.transforms.Head.X == 1, result.transforms.Head)
	check("the clip itself was played", world.registered == rig.sequence)
	checkUntouched(world, rig, before)
end)

finish()
