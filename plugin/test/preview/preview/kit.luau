--!strict
-- Shared by the preview suites in this folder: what they are run against, and the
-- helpers they use. Not a suite.
--
--
-- What is real here: Lune's Roblox instance model, so cloning, parenting, destroying,
-- tags and property values behave like instances do.
-- What is modelled: the animation engine. The fake below encodes the assumptions the
-- plugin relies on: stepping an Animator advances every track playing on it and writes
-- the joints of that Animator's own model. Whether Studio behaves this way is unverified.
-- These tests show that, given those assumptions, the preview never writes the original
-- rig, never steps its Animator, and removes everything it created on every path.
--
-- The preview never reads or writes a camera, so none is modelled. The screenshot itself
-- is a function supplied by each case, and the capture gate is a rule supplied by each
-- case, standing for a person's approval of a scene and camera. Whether Studio draws the
-- shown clone, and what a screenshot there contains, is unverified.

-- The suite that is running, for helpers here that record checks as they go.
local active: ((name: string, condition: any, detail: any?) -> ())? = nil
local function check(name: string, condition: any, detail: any?)
	(active :: any)(name, condition, detail)
end

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local task = require("@lune/task")

local Capture = require("../../../src/Preview/Capture")
local Curves = require("../../../src/Editing/Curves")
local CurveStore = require("../../../src/Editing/CurveEdit/Store")
local Preview = require("../../../src/Preview/Preview")
local Sampler = require("../../../src/Preview/Sampler")

local Instance = roblox.Instance
local CFrame = roblox.CFrame

-- Whether a screenshot would be allowed before any case has opened the gate.
local SHIPPED_REFUSAL = Preview.captureRefusal()

type Track = {
	TimePosition: number,
	Length: number,
	loadsAt: number,
	loadedLength: number,
	Looped: boolean,
	playing: boolean,
	steps: number,
	destroyed: boolean,
	Play: (self: any, ...any) -> (),
	Stop: (self: any, ...any) -> (),
	AdjustSpeed: (self: any, ...any) -> (),
	Destroy: (self: any) -> (),
}

-- A fresh fake engine and a fresh rig for every case.
local function newWorld()
	local world = {
		now = 0,
		stepped = {} :: { any },
		tracks = {} :: { [any]: { Track } },
		transformWrites = {} :: { any },
		destroyed = {} :: { any },
		stepCount = 0,
		stepCost = 0,
		-- The rig that must never be touched, and whether the engine was asked to touch it.
		protected = nil :: any,
		steppedProtected = false,
		wroteProtected = false,
		failRegister = false,
		failLoad = false,
		failStop = false,
		failStepAt = nil :: number?,
		-- Seconds a new track takes to load, as a newly registered clip does in Studio.
		loadAfter = 0,
		registered = nil :: any,
		registeredLength = 1,
		-- What the capture gate answers, how it was asked, and what was withdrawn through it.
		gateRefusal = nil :: string?,
		gateCalls = {} :: { boolean },
		revoked = {} :: { string },
		onWait = nil :: (() -> ())?,
		neverLoads = false,
		failDestroy = nil :: ((object: any) -> boolean)?,
		onStep = nil :: ((model: any, animator: any) -> ())?,
		engine = nil :: any,
	}

	local function newTrack(): Track
		local track = {
			TimePosition = 0,
			Looped = true,
			playing = false,
			steps = 0,
			destroyed = false,
			-- How fast it plays, its weight now and the one it fades toward, as the engine's are.
			speed = 1,
			WeightCurrent = 0,
			target = 0,
			fade = 0,
		} :: any
		-- Until a track has loaded it has no length, and a seek lands at zero.
		track.loadsAt = if world.neverLoads then math.huge else world.now + world.loadAfter
		track.loadedLength = world.registeredLength
		track.Length = if track.loadsAt <= world.now then track.loadedLength else 0
		function track:Play(fade: number?, weight: number?, speed: number?)
			self.playing = true
			self.speed = speed or 1
			self.target = weight or 1
			self.fade = fade or 0.1
			if self.fade <= 0 then
				self.WeightCurrent = self.target
			end
		end
		function track:Stop(fade: number?)
			if world.failStop then
				error("forced stop failure")
			end
			self.target = 0
			self.fade = fade or 0.1
			if self.fade <= 0 then
				self.WeightCurrent = 0
				self.playing = false
			end
		end
		function track:AdjustSpeed(speed: number?)
			self.speed = speed or 1
		end
		function track:Destroy()
			self.destroyed = true
			self.playing = false
		end
		return track
	end

	world.engine = {
		newInstance = function(className: string)
			return Instance.new(className)
		end,
		-- What was registered decides how long the next track is once it has loaded.
		registerClip = function(sequence: any)
			if world.failRegister then
				error("forced register failure")
			end
			local last = 0
			if sequence:IsA("CurveAnimation") then
				last = Curves.duration(sequence)
			end
			for _, child in sequence:GetChildren() do
				if child:IsA("Keyframe") then
					last = math.max(last, child.Time)
				end
			end
			world.registered = sequence
			world.registeredLength = last
			world.registeredPadded = sequence:FindFirstChild(Sampler.PAD_NAME) ~= nil
			return "rbxtemp://1"
		end,
		loadTrack = function(animator: any)
			if world.failLoad then
				error("forced load failure")
			end
			local track = newTrack()
			world.tracks[animator] = world.tracks[animator] or {}
			table.insert(world.tracks[animator], track)
			return track
		end,
		-- The engine advances every playing track on the Animator and poses that Animator's model.
		step = function(animator: any, delta: number?)
			local seconds = delta or 0
			world.stepCount += 1
			if world.failStepAt == world.stepCount then
				error("forced step failure")
			end
			world.now += world.stepCost
			table.insert(world.stepped, animator)
			if world.protected and animator:IsDescendantOf(world.protected) then
				world.steppedProtected = true
			end
			local model = animator.Parent.Parent
			-- Each playing track moves on by its speed and its weight toward its target over
			-- its fade; the pose is the playing tracks' positions blended by weight.
			local sum, weights = 0, 0
			for _, track in world.tracks[animator] or {} do
				if track.playing then
					track.steps += 1
					-- A looping track wraps at its end; any other stops there, once posed.
					local moved = track.TimePosition + seconds * track.speed
					local ended = false
					if track.Looped and track.Length > 0 then
						moved = moved % track.Length
					elseif moved >= track.Length and seconds > 0 then
						moved = track.Length
						ended = true
					end
					track.TimePosition = moved
					if track.WeightCurrent ~= track.target then
						local change = if track.fade > 0 then seconds / track.fade else 1
						if track.WeightCurrent < track.target then
							track.WeightCurrent = math.min(track.target, track.WeightCurrent + change)
						else
							track.WeightCurrent = math.max(track.target, track.WeightCurrent - change)
						end
					end
					if track.target == 0 and track.WeightCurrent <= 0 and track.fade > 0 and seconds > 0 then
						track.playing = false
					end
					sum += track.WeightCurrent * math.min(track.TimePosition, track.Length)
					weights += track.WeightCurrent
					if ended then
						track.playing = false
					end
				end
			end
			if weights > 0 then
				for _, descendant in model:GetDescendants() do
					if descendant:IsA("Motor6D") then
						descendant.Transform = CFrame.new(sum / weights, 0, 0)
					end
				end
			end
			if world.onStep then
				world.onStep(model, animator)
			end
		end,
		playingTracks = function(animator: any)
			local playing = {}
			for _, track in world.tracks[animator] or {} do
				if track.playing then
					table.insert(playing, track)
				end
			end
			return playing
		end,
		getTransform = function(joint: any)
			return joint.Transform
		end,
		setTransform = function(joint: any, transform: any)
			table.insert(world.transformWrites, joint)
			if world.protected and joint:IsDescendantOf(world.protected) then
				world.wroteProtected = true
			end
			joint.Transform = transform
		end,
		destroy = function(object: any)
			if world.failDestroy and world.failDestroy(object) then
				error("forced destroy failure")
			end
			table.insert(world.destroyed, object)
			object:Destroy()
		end,
		waitFrames = function(frames: number)
			if world.onWait then
				world.onWait()
			end
			world.now += frames / 60
			for _, tracks in world.tracks do
				for _, track in tracks do
					if track.loadsAt <= world.now then
						track.Length = track.loadedLength
					end
				end
			end
		end,
		clock = function()
			return world.now
		end,
		spawn = function(run: () -> ())
			return task.spawn(run)
		end,
		cancel = function(thread: any)
			task.cancel(thread)
		end,
	}
	Sampler.setEngine(world.engine)

	Preview.setCaptureGate(nil)
	return world
end

-- Opens the capture gate the way an approved fixture would; a case can close it again.
local function arm(world: any)
	Preview.setCaptureGate(function(capturing: boolean): string?
		table.insert(world.gateCalls, capturing)
		return world.gateRefusal
	end, function(reason: string)
		table.insert(world.revoked, reason)
	end)
end

local POSES = {
	LowerTorso = CFrame.new(0.5, 0.25, 0.125),
	UpperTorso = CFrame.new(1, 2, 3),
	Head = CFrame.new(-4, 5, -6),
}

-- An R15-shaped fragment in a pose that is not the rest pose, with the kinds of content a
-- real character carries: scripts, a sound, tags, an Animator with a playing track, and a
-- joint to a part outside the model.
local function buildRig(world: any, options: { playingTrack: boolean? }?)
	local place = Instance.new("Folder")
	place.Name = "Place"
	local model = Instance.new("Model")
	model.Name = "Hero"

	local function part(name: string)
		local created = Instance.new("Part")
		created.Name = name
		created.Parent = model
		return created
	end
	local root, lower, upper, head = part("HumanoidRootPart"), part("LowerTorso"), part("UpperTorso"), part("Head")
	local function motor(name: string, part0: any, part1: any)
		local created = Instance.new("Motor6D")
		created.Name = name
		created.Part0 = part0
		created.Part1 = part1
		created.C0 = CFrame.new(0, 1, 0)
		created.Transform = POSES[part1.Name]
		created.Parent = part1
		return created
	end
	local joints = {
		LowerTorso = motor("Root", root, lower),
		UpperTorso = motor("Waist", lower, upper),
		Head = motor("Neck", upper, head),
	}

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	local animator = Instance.new("Animator")
	animator.Parent = humanoid

	local script = Instance.new("Script")
	script.Parent = model
	local module = Instance.new("ModuleScript")
	module.Parent = head
	local sound = Instance.new("Sound")
	sound.Parent = root
	local decal = Instance.new("Decal")
	decal.Parent = head
	model:AddTag("Enemy")
	head:AddTag("Hitbox")

	local outside = Instance.new("Part")
	outside.Name = "Outside"
	outside.Parent = place
	local grip = Instance.new("Motor6D")
	grip.Name = "Grip"
	grip.Part0 = head
	grip.Part1 = outside
	grip.Transform = CFrame.new(9, 9, 9)
	grip.Parent = head

	model.Parent = place
	world.protected = model

	local existing: Track? = nil
	if not options or options.playingTrack ~= false then
		existing = world.engine.loadTrack(animator)
		local track = existing :: Track
		track.playing = true
		track.TimePosition = 0.4
	end

	local sequence = Instance.new("KeyframeSequence")
	for _, time in { 0, 1 } do
		local keyframe = Instance.new("Keyframe")
		keyframe.Time = time
		keyframe.Parent = sequence
	end

	return {
		place = place,
		model = model,
		joints = joints,
		humanoid = humanoid,
		animator = animator,
		existingTrack = existing,
		outside = outside,
		sequence = sequence,
	}
end

-- Everything observable about the original rig, as text, to compare before and after.
local function snapshot(model: any): string
	local lines = {}
	local function describe(instance: any, path: string)
		local line = `{path}|{instance.ClassName}|archivable={tostring(instance.Archivable)}|tags={table.concat(
			instance:GetTags(),
			","
		)}`
		if instance:IsA("Motor6D") then
			line ..= `|transform={tostring(instance.Transform)}|c0={tostring(instance.C0)}`
			line ..= `|part0={instance.Part0 and instance.Part0.Name}|part1={instance.Part1 and instance.Part1.Name}`
		elseif instance:IsA("BasePart") then
			line ..= `|transparency={instance.Transparency}|cframe={tostring(instance.CFrame)}|locked={tostring(
				instance.Locked
			)}`
		end
		table.insert(lines, line)
		for _, child in instance:GetChildren() do
			describe(child, `{path}/{child.Name}`)
		end
	end
	describe(model, model.Name)
	table.sort(lines)
	return table.concat(lines, "\n")
end

local function request(rig: any, extra: { [string]: any }?): any
	local result = {
		model = rig.model,
		sequence = rig.sequence,
		time = 0.5,
		joints = { "Head", "UpperTorso" },
		parent = rig.place,
	}
	for key, value in extra or {} do
		(result :: any)[key] = value
	end
	return result
end

local function childNames(place: any): string
	local names = {}
	for _, child in place:GetChildren() do
		table.insert(names, child.Name)
	end
	table.sort(names)
	return table.concat(names, ",")
end

-- The original is intact and nothing of the preview remains.
local function checkUntouched(world: any, rig: any, before: string)
	check("original rig is unchanged", snapshot(rig.model) == before)
	check(
		"only the original and the outside part remain",
		childNames(rig.place) == "Hero,Outside",
		childNames(rig.place)
	)
	check("no preview clone is still owned", Preview.ownedCount() == 0, Preview.ownedCount())
	check("no screenshot is left in progress", Preview.subject() == nil)
	for name, pose in POSES do
		check(`{name} keeps its non-identity pose`, tostring(rig.joints[name].Transform) == tostring(pose))
	end
	check("no joint of the original was written", not world.wroteProtected)
	check("the original Animator was never stepped", not world.steppedProtected)
	if rig.existingTrack then
		check("the existing track did not advance", rig.existingTrack.steps == 0, rig.existingTrack.steps)
		check("the existing track kept its position", rig.existingTrack.TimePosition == 0.4)
		check("the existing track is still playing", rig.existingTrack.playing == true)
		check("the existing track was not destroyed", rig.existingTrack.destroyed == false)
	end
end

local function expectError(run: () -> any): any
	local ok, problem = pcall(run)
	check("the call fails", not ok)
	return if ok then {} else problem
end

local Kit = {}

-- A suite's own count of checks: `check` records one, `case` runs a group of them and
-- counts one that raises, `finish` prints the tally and fails the run if any failed.
function Kit.suite(
	label: string
): ((name: string, condition: any, detail: any?) -> (), (name: string, run: () -> ()) -> (), () -> ())
	local failures, count, current = 0, 0, ""
	local function suiteCheck(name: string, condition: any, detail: any?)
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
			print(
				`FAIL [{name}] raised: {if type(problem) == "table" then (problem :: any).message else tostring(problem)}`
			)
		end
	end
	local function finish()
		print(`{count - failures}/{count} {label} checks passed`)
		if failures > 0 then
			process.exit(1)
		end
	end
	active = suiteCheck
	return suiteCheck, case, finish
end

-- A request for a screenshot with the gate open, as when a person has approved the scene.
local function shot(world: any, rig: any, capture: (guard: () -> string?) -> any, extra: { [string]: any }?): any
	arm(world)
	local fields: { [string]: any } = { capture = capture }
	for key, value in extra or {} do
		fields[key] = value
	end
	return request(rig, fields)
end

Sampler.setEngine(nil)
Preview.setCaptureGate(nil)

Kit.newWorld = newWorld
Kit.arm = arm
Kit.buildRig = buildRig
Kit.snapshot = snapshot
Kit.request = request
Kit.childNames = childNames
Kit.checkUntouched = checkUntouched
Kit.expectError = expectError
Kit.shot = shot
Kit.process = process
Kit.roblox = roblox
Kit.task = task
Kit.Capture = Capture
Kit.Curves = Curves
Kit.CurveStore = CurveStore
Kit.Preview = Preview
Kit.Sampler = Sampler
Kit.Instance = Instance
Kit.CFrame = CFrame
Kit.SHIPPED_REFUSAL = SHIPPED_REFUSAL
Kit.POSES = POSES

return Kit
