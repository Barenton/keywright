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

finish()
