--!strict
-- The sampler: it refuses a busy Animator, restores the pose it found, and releases what it made.
-- Run with: lune run plugin/test/preview/preview/sampler.test.luau

local Kit = require("./kit")

local buildRig = Kit.buildRig
local checkUntouched = Kit.checkUntouched
local expectError = Kit.expectError
local newWorld = Kit.newWorld
local POSES = Kit.POSES
local Sampler = Kit.Sampler
local snapshot = Kit.snapshot

local check, case, finish = Kit.suite("preview sampler")
case("the sampler refuses an Animator that already has playing tracks", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local children = #rig.humanoid:GetChildren()
	local problem = expectError(function()
		return Sampler.open(rig.model, { Head = { instance = rig.joints.Head } } :: any, rig.sequence)
	end)
	check("it fails closed", problem.code == "PREVIEW_UNAVAILABLE", problem.code)
	check("nothing was created on the rig", #rig.humanoid:GetChildren() == children)
	check("nothing was stepped", #world.stepped == 0)
	checkUntouched(world, rig, before)
end)

case("the sampler restores the pose it found, not the rest pose", function()
	local world = newWorld()
	local rig = buildRig(world, { playingTrack = false })
	world.protected = nil
	local joints = {}
	for name, instance in rig.joints do
		joints[name] = { instance = instance }
	end
	local handle = Sampler.open(rig.model, joints :: any, rig.sequence)
	Sampler.seek(handle, 0.75)
	check("the model it was given is posed", rig.joints.Head.Transform.X == 0.75, rig.joints.Head.Transform)
	check("closing reports no problem", #Sampler.close(handle) == 0)
	for name, pose in POSES do
		check(`{name} is back in the pose it had`, tostring(rig.joints[name].Transform) == tostring(pose))
	end
	check("the rig's own Animator was not destroyed", rig.animator.Parent == rig.humanoid)
	local animations = 0
	for _, object in world.destroyed do
		if typeof(object) ~= "table" and object.ClassName == "Animation" then
			animations += 1
		end
	end
	check("the Animation it created was destroyed", animations == 1, animations)
	check("the track it created was destroyed", world.tracks[rig.animator][1].destroyed)
end)

case("the sampler releases what it created when it cannot start", function()
	local world = newWorld()
	local rig = buildRig(world, { playingTrack = false })
	rig.animator:Destroy()
	world.failLoad = true
	local children = #rig.humanoid:GetChildren()
	local problem = expectError(function()
		return Sampler.open(rig.model, { Head = { instance = rig.joints.Head } } :: any, rig.sequence)
	end)
	check("the original failure is reported", string.find(tostring(problem), "forced load failure") ~= nil, problem)
	check("the Animator it created is gone", #rig.humanoid:GetChildren() == children, #rig.humanoid:GetChildren())
	local classes = {}
	for _, object in world.destroyed do
		table.insert(classes, object.ClassName)
	end
	table.sort(classes)
	check(
		"it destroyed exactly what it created",
		table.concat(classes, ",") == "Animation,Animator",
		table.concat(classes, ",")
	)
	check("the pose is unchanged", tostring(rig.joints.Head.Transform) == tostring(POSES.Head))
end)

case("another clip interrupts this one, both advancing as the engine fades them across", function()
	local world = newWorld()
	local rig = buildRig(world, { playingTrack = false })
	world.protected = nil
	local joints = {}
	for name, instance in rig.joints do
		joints[name] = { instance = instance }
	end
	local block = Kit.Instance.new("KeyframeSequence")
	local last = Kit.Instance.new("Keyframe")
	last.Time = 2
	last.Parent = block
	local handle = Sampler.open(rig.model, joints :: any, rig.sequence)
	local moments = Sampler.interrupt(handle, block, 0.5, 0, 0.1, { 0, 0.05, 0.1, 0.2 })
	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-9
	end
	local weights, times = {}, {}
	for _, moment in moments do
		table.insert(weights, `{moment.weights[1]}/{moment.weights[2]}`)
		table.insert(times, `{moment.times[1]}/{moment.times[2]}`)
	end
	check("four moments, as asked", #moments == 4, #moments)
	check(
		"the weights cross over through the fade",
		near(moments[1].weights[1], 1)
			and near(moments[1].weights[2], 0)
			and near(moments[2].weights[1], 0.5)
			and near(moments[2].weights[2], 0.5)
			and near(moments[3].weights[1], 0)
			and near(moments[3].weights[2], 1)
			and near(moments[4].weights[2], 1),
		table.concat(weights, " ")
	)
	check(
		"both clips advance in real time, this one from the interruption, the other from its start",
		near(moments[1].times[1], 0.5)
			and near(moments[2].times[1], 0.55)
			and near(moments[2].times[2], 0.05)
			and near(moments[4].times[2], 0.2),
		table.concat(times, " ")
	)
	check(
		"halfway through, the pose is the two blended",
		-- A CFrame holds single-precision numbers.
		math.abs(moments[2].transforms.Head.X - (0.55 + 0.05) / 2) < 1e-5,
		moments[2].transforms.Head.X
	)
	local tracks = world.tracks[rig.animator]
	check("the clip faded out has stopped", tracks[1].playing == false)
	check("closing reports no problem", #Sampler.close(handle) == 0)
	check(
		"both tracks it made are stopped and destroyed",
		tracks[1].destroyed and tracks[2].destroyed and not tracks[2].playing
	)
end)

case("an interruption keeps each clip's own looping", function()
	local world = newWorld()
	local rig = buildRig(world, { playingTrack = false })
	world.protected = nil
	local joints = {}
	for name, instance in rig.joints do
		joints[name] = { instance = instance }
	end
	local guard = Kit.Instance.new("KeyframeSequence")
	guard.Loop = true
	local last = Kit.Instance.new("Keyframe")
	last.Time = 0.5
	last.Parent = guard
	local handle = Sampler.open(rig.model, joints :: any, rig.sequence)
	local moments = Sampler.interrupt(handle, guard, 0.5, 0.45, 0.1, { 0, 0.1 })
	check("the looping clip comes round past its end", math.abs(moments[2].times[2] - 0.05) < 1e-9, moments[2].times[2])
	check("closing reports no problem", #Sampler.close(handle) == 0)
end)

case("an interruption given up on partway stops, and leaves nothing behind", function()
	local world = newWorld()
	local rig = buildRig(world, { playingTrack = false })
	world.protected = nil
	local joints = {}
	for name, instance in rig.joints do
		joints[name] = { instance = instance }
	end
	local block = Kit.Instance.new("KeyframeSequence")
	local last = Kit.Instance.new("Keyframe")
	last.Time = 1
	last.Parent = block
	local handle = Sampler.open(rig.model, joints :: any, rig.sequence)
	local asked = 0
	local ok = pcall(Sampler.interrupt, handle, block, 0.2, 0, 0.1, { 0, 0.05, 0.1 }, nil, function()
		asked += 1
		if asked == 2 then
			error("given up")
		end
	end)
	check("it stops where it was given up", not ok and asked == 2, asked)
	check("closing reports no problem", #Sampler.close(handle) == 0)
	local tracks = world.tracks[rig.animator]
	check("and both tracks it made are destroyed", #tracks == 2 and tracks[1].destroyed and tracks[2].destroyed)
end)

finish()
