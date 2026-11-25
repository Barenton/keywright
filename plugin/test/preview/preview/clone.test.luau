--!strict
-- The preview's disposable clone: placed and reported as asked, isolated, hidden, released, and cleaned up whatever fails.
-- Run with: lune run plugin/test/preview/preview/clone.test.luau

local Kit = require("./kit")

local buildRig = Kit.buildRig
local CFrame = Kit.CFrame
local checkUntouched = Kit.checkUntouched
local childNames = Kit.childNames
local expectError = Kit.expectError
local newWorld = Kit.newWorld
local Preview = Kit.Preview
local request = Kit.request
local snapshot = Kit.snapshot

local check, case, finish = Kit.suite("preview clone")
case("where the clone's parts are is reported only when asked, relative to its root", function()
	local world = newWorld()
	local rig = buildRig(world)
	rig.model.HumanoidRootPart.CFrame = CFrame.new(10, 0, -4)
	rig.model.LowerTorso.CFrame = CFrame.new(10, 1, -4)
	rig.model.Head.CFrame = CFrame.new(10, 3, -4)
	local before = snapshot(rig.model)
	check("nothing is measured unless asked", Preview.run(request(rig)).placed == nil)
	local placed = Preview.run(request(rig, { measure = true })).placed
	check("every driven part is measured", placed ~= nil and placed.LowerTorso ~= nil and placed.UpperTorso ~= nil)
	check("the root part is not among them", placed.HumanoidRootPart == nil)
	local head = placed.Head.Position
	check("positions are relative to the root part", head.X == 0 and head.Y == 3 and head.Z == 0, head)
	checkUntouched(world, rig, before)
end)

case("a rig in a non-identity pose is sampled without being changed", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(request(rig))
	check("the sampled pose comes from the stepped clone", result.transforms.Head.X == 0.5, result.transforms.Head)
	check(
		"only requested joints are returned",
		result.transforms.LowerTorso == nil and result.transforms.UpperTorso ~= nil
	)
	check("the clip was stepped", #world.stepped > 0)
	check("no capture was reported", result.capture == nil)
	checkUntouched(world, rig, before)
end)

case("the preview's own track and Animator are isolated and released", function()
	local world = newWorld()
	local rig = buildRig(world)
	Preview.run(request(rig))
	local previewTracks = 0
	for animator, tracks in world.tracks do
		if animator ~= rig.animator then
			for _, track in tracks do
				previewTracks += 1
				check("the preview track was destroyed", track.destroyed)
				check("the preview track was stepped", track.steps > 0)
			end
		end
	end
	check("the preview used exactly one track of its own", previewTracks == 1, previewTracks)
	check("the original Animator has only its own track", #world.tracks[rig.animator] == 1)
end)

case("the clone is sanitized, isolated and hidden while it exists", function()
	local world = newWorld()
	local rig = buildRig(world)
	local observed = false
	world.onStep = function(model: any, animator: any)
		if observed then
			return
		end
		observed = true
		check("the stepped model is not the original", model ~= rig.model)
		check("the clone has the preview name", model.Name == Preview.CLONE_NAME)
		check("the clone is not archivable", model.Archivable == false)
		check("the clone sits where it was asked to", model.Parent == rig.place)
		local scripts, sounds, animators, outsideJoints, tags, visible = 0, 0, 0, 0, #model:GetTags(), 0
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("LuaSourceContainer") then
				scripts += 1
			elseif descendant:IsA("Sound") then
				sounds += 1
			elseif descendant:IsA("Animator") then
				animators += 1
				check("the clone's Animator is its own", descendant == animator and descendant ~= rig.animator)
			elseif descendant:IsA("Motor6D") then
				if not descendant.Part0:IsDescendantOf(model) or not descendant.Part1:IsDescendantOf(model) then
					outsideJoints += 1
				end
			elseif descendant:IsA("BasePart") and descendant.Transparency < 1 then
				visible += 1
			end
			tags += #descendant:GetTags()
		end
		check("no scripts in the clone", scripts == 0, scripts)
		check("no sounds in the clone", sounds == 0, sounds)
		check("exactly one Animator in the clone", animators == 1, animators)
		check("no joint to anything outside the clone", outsideJoints == 0, outsideJoints)
		check("no tags on the clone", tags == 0, tags)
		check("the clone is hidden when no screenshot is taken", visible == 0, visible)
	end
	local before = snapshot(rig.model)
	Preview.run(request(rig))
	check("the clone was observed", observed)
	check("the original still has its scripts", rig.model:FindFirstChildOfClass("Script") ~= nil)
	check("the original still has its outside joint", rig.model.Head:FindFirstChild("Grip") ~= nil)
	check("the original still has its tags", rig.model:HasTag("Enemy") and rig.model.Head:HasTag("Hitbox"))
	checkUntouched(world, rig, before)
end)

for label, configure in
	{
		["clip registration fails"] = function(world: any)
			world.failRegister = true
		end,
		["track loading fails"] = function(world: any)
			world.failLoad = true
		end,
		["sanitizing fails part-way"] = function(world: any)
			world.failDestroy = function(object: any)
				return typeof(object) ~= "table" and object:IsA("LuaSourceContainer")
			end
		end,
		["the first step fails"] = function(world: any)
			world.failStepAt = 1
		end,
	} :: { [string]: (world: any) -> () }
do
	case(`cleanup after partial failure: {label}`, function()
		local world = newWorld()
		local rig = buildRig(world)
		local before = snapshot(rig.model)
		configure(world)
		local problem = expectError(function()
			return Preview.run(request(rig))
		end)
		check("the original failure is reported", string.find(tostring(problem), "forced") ~= nil, problem)
		world.failDestroy = nil
		checkUntouched(world, rig, before)
	end)
end

case("a preview that overruns its time budget fails and cleans up", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	world.stepCost = Preview.SAMPLE_BUDGET + 1
	local problem = expectError(function()
		return Preview.run(request(rig))
	end)
	check("it fails closed", problem.code == "PREVIEW_UNAVAILABLE", problem.code)
	check("it names the budget", string.find(problem.message or "", "time budget") ~= nil, problem.message)
	checkUntouched(world, rig, before)
end)

case("a second preview does not start while one is running", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local inner: any = nil
	local clonesDuringInner = 0
	world.onStep = function()
		if inner == nil then
			-- The refused request waits out its own turn; the first one's budget is longer.
			Preview.SAMPLE_BUDGET = 1
			inner = expectError(function()
				return Preview.run(request(rig))
			end)
			for _, child in rig.place:GetChildren() do
				if child.Name == Preview.CLONE_NAME then
					clonesDuringInner += 1
				end
			end
		end
	end
	local budget = Preview.SAMPLE_BUDGET
	Preview.SAMPLE_BUDGET = 1000
	local ok, result = pcall(Preview.run, request(rig))
	Preview.SAMPLE_BUDGET = budget
	check("the second request was refused", inner ~= nil and inner.code == "PREVIEW_UNAVAILABLE", inner and inner.code)
	check("it says why", string.find((inner and inner.message) or "", "still running") ~= nil, inner and inner.message)
	check("the first preview's clone survived the second request", clonesDuringInner == 1, clonesDuringInner)
	check("the first preview finished", ok and result.transforms.Head.X == 0.5, result)
	checkUntouched(world, rig, before)
	world.onStep = nil
	check("previews work again afterwards", Preview.run(request(rig)).transforms.Head.X == 0.5)
end)

case("when the clone cannot be destroyed the preview fails closed and later sweeps it", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	world.failDestroy = function(object: any)
		return typeof(object) ~= "table" and object.ClassName == "Model" and object.Name == Preview.CLONE_NAME
	end
	local problem = expectError(function()
		return Preview.run(request(rig))
	end)
	check("it fails closed", problem.code == "PREVIEW_UNAVAILABLE", problem.code)
	check(
		"it reports the cleanup",
		string.find(problem.message or "", "could not be cleaned up") ~= nil,
		problem.message
	)
	check("the clone is still tracked", Preview.ownedCount() == 1, Preview.ownedCount())
	check("the original is unchanged despite the failure", snapshot(rig.model) == before)
	for animator, tracks in world.tracks do
		if animator ~= rig.animator then
			check("the preview track was still destroyed", tracks[1].destroyed)
		end
	end

	-- While the leftover cannot be removed, no further preview starts and no second clone is made.
	local children = #rig.place:GetChildren()
	local again = expectError(function()
		return Preview.run(request(rig))
	end)
	check(
		"the next preview refuses to start",
		string.find(again.message or "", "earlier preview") ~= nil,
		again.message
	)
	check("no second clone was made", #rig.place:GetChildren() == children)

	-- Once it can be destroyed, the sweep removes it and previews work again.
	world.failDestroy = nil
	check("the sweep succeeds", #Preview.sweep() == 0)
	local result = Preview.run(request(rig))
	check("previews work again", result.transforms.Head.X == 0.5)
	checkUntouched(world, rig, before)
end)

case("when stopping the track fails everything else is still released", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	world.failStop = true
	local problem = expectError(function()
		return Preview.run(request(rig))
	end)
	check("it fails closed", problem.code == "PREVIEW_UNAVAILABLE", problem.code)
	check("it names the failed step", string.find(problem.message or "", "stop track") ~= nil, problem.message)
	for animator, tracks in world.tracks do
		if animator ~= rig.animator then
			check("the preview track was destroyed anyway", tracks[1].destroyed)
		end
	end
	checkUntouched(world, rig, before)
end)

case("a failed start with a failed cleanup reports both", function()
	local world = newWorld()
	local rig = buildRig(world)
	world.failLoad = true
	world.failDestroy = function(object: any)
		return typeof(object) ~= "table" and object.ClassName == "Model" and object.Name == Preview.CLONE_NAME
	end
	local problem = expectError(function()
		return Preview.run(request(rig))
	end)
	check("the cleanup failure is reported", string.find(problem.message or "", "could not be cleaned up") ~= nil)
	check(
		"the original failure is reported too",
		string.find(problem.message or "", "forced load failure") ~= nil,
		problem.message
	)
	world.failDestroy = nil
	check("the sweep removes the leftover", #Preview.sweep() == 0 and Preview.ownedCount() == 0)
	check("nothing of the preview remains", childNames(rig.place) == "Hero,Outside", childNames(rig.place))
end)

finish()
