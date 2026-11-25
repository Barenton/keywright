--!strict
-- Offline tests for the preview lifecycle. Run with: lune run plugin/test/preview/preview.test.luau
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

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local task = require("@lune/task")

local Capture = require("../../src/Preview/Capture")
local Curves = require("../../src/Editing/Curves")
local Preview = require("../../src/Preview/Preview")
local Sampler = require("../../src/Preview/Sampler")

local Instance = roblox.Instance
local CFrame = roblox.CFrame

-- Whether a screenshot would be allowed before any case has opened the gate.
local SHIPPED_REFUSAL = Preview.captureRefusal()

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
	Preview.setCaptureGate(nil)
	if not ok then
		count += 1
		failures += 1
		print(
			`FAIL [{name}] raised: {if type(problem) == "table" then (problem :: any).message else tostring(problem)}`
		)
	end
end

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
		local track = { TimePosition = 0, Looped = true, playing = false, steps = 0, destroyed = false } :: any
		-- Until a track has loaded it has no length, and a seek lands at zero.
		track.loadsAt = if world.neverLoads then math.huge else world.now + world.loadAfter
		track.loadedLength = world.registeredLength
		track.Length = if track.loadsAt <= world.now then track.loadedLength else 0
		function track:Play()
			self.playing = true
		end
		function track:Stop()
			if world.failStop then
				error("forced stop failure")
			end
			self.playing = false
		end
		function track:AdjustSpeed() end
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
		step = function(animator: any)
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
			for _, track in world.tracks[animator] or {} do
				if track.playing then
					track.steps += 1
					for _, descendant in model:GetDescendants() do
						if descendant:IsA("Motor6D") then
							descendant.Transform = CFrame.new(math.min(track.TimePosition, track.Length), 0, 0)
						end
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

case("screenshots stay off unless an entry point opens the gate", function()
	check(
		"the module ships with the capture gate closed",
		SHIPPED_REFUSAL == Preview.CAPTURE_GATE_CLOSED,
		SHIPPED_REFUSAL
	)
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local called = false
	local shown = false
	world.onStep = function(model: any)
		for _, descendant in model:GetDescendants() do
			shown = shown or (descendant:IsA("BasePart") and descendant.Transparency == 0)
		end
	end
	local result = Preview.run(request(rig, {
		capture = function()
			called = true
			return { status = "ok" }
		end,
	}))
	check("the capture function was not called", not called)
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check("the reason is stated", result.capture.reason == Preview.CAPTURE_GATE_CLOSED, result.capture.reason)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	check("the clone was never shown", not shown)
	checkUntouched(world, rig, before)
end)

for label, rule in
	{
		["refuses"] = function(): string?
			return "not armed"
		end,
		["fails"] = function(): string?
			error("forced gate failure")
		end,
		["answers with something that is not a reason"] = function(): any
			return false
		end,
	} :: { [string]: () -> any }
do
	case(`a gate that {label} keeps screenshots off`, function()
		local world = newWorld()
		local rig = buildRig(world)
		local before = snapshot(rig.model)
		Preview.setCaptureGate(rule)
		local called = false
		local result = Preview.run(request(rig, {
			capture = function()
				called = true
				return { status = "ok" }
			end,
		}))
		check("the capture function was not called", not called)
		check("the capture is reported unavailable", result.capture.status == "unavailable")
		check("a reason is given", type(result.capture.reason) == "string" and result.capture.reason ~= "")
		checkUntouched(world, rig, before)
	end)
end

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
	local Roblox = require("../../src/Core/Roblox") :: any
	Roblox.Instance, Roblox.CFrame, Roblox.Enum = roblox.Instance, roblox.CFrame, roblox.Enum
	Curves.backend = {
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
	Curves.backend = nil
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

-- A request for a screenshot with the gate open, as when a person has approved the scene.
local function shot(world: any, rig: any, capture: (guard: () -> string?) -> any, extra: { [string]: any }?): any
	arm(world)
	local fields: { [string]: any } = { capture = capture }
	for key, value in extra or {} do
		fields[key] = value
	end
	return request(rig, fields)
end

case("a successful screenshot shows the clone where the rig stands and moves nothing", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local seen: any = {}
	local result = Preview.run(shot(world, rig, function(guard)
		local clone = rig.place:FindFirstChild(Preview.CLONE_NAME)
		seen.clone = clone ~= nil
		seen.visible, seen.inert = 0, 0
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("BasePart") then
				if descendant.Transparency == 0 then
					seen.visible += 1
				end
				if
					not descendant.CanCollide
					and not descendant.CanQuery
					and not descendant.CanTouch
					and descendant.Locked
				then
					seen.inert += 1
				end
			end
		end
		seen.rootHidden = clone.HumanoidRootPart.Transparency == 1
		seen.samePlace = clone.HumanoidRootPart.CFrame == rig.model.HumanoidRootPart.CFrame
		seen.subject = Preview.subject()
		seen.guard = guard()
		return { status = "ok", width = 4, height = 3 }
	end))
	check("the clone existed during the capture", seen.clone)
	check("the clone's body was visible", seen.visible == 3, seen.visible)
	check("the clone's root part stayed hidden", seen.rootHidden)
	check("the clone could not be hit, touched, queried or selected", seen.inert == 4, seen.inert)
	check("the clone stood exactly where the rig stands", seen.samePlace)
	check(
		"the screenshot's subject is the rig being previewed",
		seen.subject ~= nil and seen.subject.model == rig.model
	)
	check(
		"the subject names the clone",
		seen.subject ~= nil and seen.subject.clone ~= nil and seen.subject.clone ~= rig.model
	)
	check("the guard allowed the screenshot", seen.guard == nil, seen.guard)
	check("the gate was asked as for a capture", table.find(world.gateCalls, true) ~= nil)
	check("the capture result is passed through", result.capture.status == "ok" and result.capture.width == 4)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	check("no screenshot is in progress afterwards", Preview.subject() == nil)
	check("no approval was withdrawn", #world.revoked == 0, table.concat(world.revoked, "; "))
	checkUntouched(world, rig, before)
end)

case("a preview without a screenshot has no screenshot subject", function()
	local world = newWorld()
	local rig = buildRig(world)
	arm(world)
	local steps, withSubject = 0, 0
	world.onStep = function()
		steps += 1
		if Preview.subject() ~= nil then
			withSubject += 1
		end
	end
	Preview.run(request(rig))
	check("the clip was sampled", steps > 0, steps)
	check("no subject at any point while sampling", withSubject == 0, withSubject)
end)

case("a failing capture leaves no clone", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(shot(world, rig, function()
		error("forced capture failure")
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check("the reason carries the failure", string.find(result.capture.reason, "forced capture failure") ~= nil)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	checkUntouched(world, rig, before)
end)

case("a capture that returns nothing usable is reported unavailable", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(shot(world, rig, function()
		return nil
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	checkUntouched(world, rig, before)
end)

case("a capture that never returns is abandoned, and its late result is refused", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local resumed = false
	local lateGuard: any = nil
	local result = Preview.run(shot(world, rig, function(guard)
		lateGuard = guard
		coroutine.yield()
		resumed = true
		return { status = "ok" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check("the reason names the budget", string.find(result.capture.reason, "time budget") ~= nil)
	check("the capture budget elapsed", world.now >= Preview.CAPTURE_BUDGET, world.now)
	check("the abandoned capture never continued", not resumed)
	check("the abandoned capture may no longer take an image", lateGuard() == "the preview has ended", lateGuard())
	check(
		"the approval it ran under was withdrawn",
		table.find(world.revoked, "the capture exceeded its time budget") ~= nil,
		table.concat(world.revoked, "; ")
	)
	checkUntouched(world, rig, before)

	-- A later preview has its own clone; the old capture still may not shoot.
	local duringNext: any = "unset"
	local nextResult = Preview.run(shot(world, rig, function()
		duringNext = lateGuard()
		return { status = "ok", width = 2, height = 2 }
	end))
	check("the old capture is refused during a later preview", duringNext == "the preview has ended", duringNext)
	check("the later preview gets its own image", nextResult.capture.status == "ok")
	checkUntouched(world, rig, before)
end)

case("a capture that runs out of time leaves no permission request waiting", function()
	local world = newWorld()
	local rig = buildRig(world)
	local abandons = 0
	local original = Capture.abandon
	Capture.abandon = function()
		abandons += 1
	end
	local ok, problem = pcall(function()
		Preview.run(shot(world, rig, function()
			coroutine.yield()
			return { status = "ok" }
		end))
		check("the waiting permission request was given up on", abandons == 1, abandons)
		Preview.run(shot(world, rig, function()
			return { status = "ok", width = 2, height = 2 }
		end))
		check("a capture that finishes gives up on nothing", abandons == 1, abandons)
		-- Withdrawing approval, switching tab or camera, and unloading all cancel.
		Preview.cancel("approval was withdrawn in the panel")
		check("cancelling gives up on a waiting permission request at once", abandons == 2, abandons)
		Preview.sweep()
		check("so does an unload", abandons == 3, abandons)
	end)
	Capture.abandon = original
	check("the case ran", ok, problem)
end)

case("a rig the gate has not approved is never shown, even for a moment", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local asked: { any } = {}
	-- Screenshots are possible in general, but not of this rig.
	Preview.setCaptureGate(function(capturing: boolean): string?
		local subject = Preview.subject()
		table.insert(
			asked,
			{ capturing = capturing, model = subject and subject.model, clone = subject and subject.clone }
		)
		return if capturing then "screenshots are off: the preview is not of the probe's synthetic rig" else nil
	end)
	local shown, called = false, false
	world.onStep = function(model: any)
		for _, descendant in model:GetDescendants() do
			shown = shown or (descendant:IsA("BasePart") and descendant.Transparency == 0)
		end
	end
	local result = Preview.run(request(rig, {
		capture = function()
			called = true
			return { status = "ok", png = "image" }
		end,
	}))
	check(
		"the gate was asked before any clone existed",
		asked[1] ~= nil and asked[1].capturing == true and asked[1].clone == nil
	)
	check("the gate was told which rig", asked[1] ~= nil and asked[1].model == rig.model)
	check("the clone was never shown", not shown)
	check("the capture function was not called", not called)
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check(
		"the reason is the gate's",
		string.find(result.capture.reason, "not of the probe's synthetic rig") ~= nil,
		result.capture.reason
	)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	checkUntouched(world, rig, before)
end)

case("an image is not handed on if approval is lost while the preview cleans up", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local taken = false
	world.onStep = function()
		-- The sampler's last step happens during cleanup, after the image is in hand.
		if taken then
			world.gateRefusal = "screenshots are off: the active tab changed"
		end
	end
	local result = Preview.run(shot(world, rig, function()
		taken = true
		return { status = "ok", width = 4, height = 3, png = "image" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
	check("no image is passed on", result.capture.png == nil)
	check(
		"the reason is the lost approval",
		string.find(result.capture.reason, "the active tab changed") ~= nil,
		result.capture.reason
	)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	checkUntouched(world, rig, before)
end)

case("a capture that finishes only after its deadline is not a success", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(shot(world, rig, function()
		-- Ready, but late: the image exists and must still not be passed on.
		world.now += Preview.CAPTURE_BUDGET + 1
		return { status = "ok", width = 4, height = 3, png = "image" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
	check("no image is passed on", result.capture.png == nil)
	check(
		"the reason names the budget",
		string.find(result.capture.reason, "time budget") ~= nil,
		result.capture.reason
	)
	checkUntouched(world, rig, before)
end)

-- The gate stands for the approval of a scene and camera. When the scene, the camera or
-- the active tab changes, the approval is withdrawn and the gate answers with the reason.
for label, disturb in
	{
		["the clip changes"] = function(_world: any, state: any)
			state.current = false
		end,
		["the scene changes"] = function(world: any)
			world.gateRefusal = "screenshots are off: the scene changed after it was approved"
		end,
		["the camera is moved or switched"] = function(world: any)
			world.gateRefusal = "screenshots are off: the camera or the viewport changed after it was approved"
		end,
		["the fixture is unarmed"] = function(world: any)
			world.gateRefusal = "screenshots are off: the fixture was unarmed"
		end,
		["the gate is closed outright"] = function()
			Preview.setCaptureGate(nil)
		end,
		["the clone is removed"] = function(_world: any, _state: any, rig: any)
			rig.place:FindFirstChild(Preview.CLONE_NAME).Parent = nil
		end,
	} :: { [string]: (world: any, state: any, rig: any) -> () }
do
	case(`an image taken while {label} is not returned`, function()
		local world = newWorld()
		local rig = buildRig(world)
		local before = snapshot(rig.model)
		local state = { current = true }
		local result = Preview.run(shot(world, rig, function()
			disturb(world, state, rig)
			return { status = "ok", width = 4, height = 3, png = "image" }
		end, {
			current = function()
				return state.current
			end,
		}))
		check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
		check("no image is passed on", result.capture.png == nil)
		check("a reason is given", type(result.capture.reason) == "string" and result.capture.reason ~= "")
		check("the sample is still returned", result.transforms.Head.X == 0.5)
		checkUntouched(world, rig, before)
	end)

	case(`no image is requested once {label} before the screenshot`, function()
		local world = newWorld()
		local rig = buildRig(world)
		local before = snapshot(rig.model)
		local state = { current = true }
		local called = false
		-- The change happens while the clone is being drawn, before the capture is called.
		world.onWait = function()
			if Preview.subject() ~= nil and not called then
				disturb(world, state, rig)
			end
		end
		local result = Preview.run(shot(world, rig, function()
			called = true
			return { status = "ok", png = "image" }
		end, {
			current = function()
				return state.current
			end,
		}))
		check("the capture function was not called", not called)
		check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
		checkUntouched(world, rig, before)
	end)
end

case("cancelling abandons the screenshot and withdraws the approval", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local resumed = false
	local result = Preview.run(shot(world, rig, function()
		Preview.cancel("agent access was turned off")
		coroutine.yield()
		resumed = true
		return { status = "ok" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check(
		"the reason is the cancellation",
		result.capture.reason == "agent access was turned off",
		result.capture.reason
	)
	check("it did not wait out the capture budget", world.now < 5, world.now)
	check("the abandoned capture never continued", not resumed)
	check("the approval was withdrawn", table.find(world.revoked, "agent access was turned off") ~= nil)
	checkUntouched(world, rig, before)
end)

case("an image that arrives after a cancellation is not returned", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(shot(world, rig, function()
		Preview.cancel("agent access was turned off")
		return { status = "ok", png = "image" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
	check("no image is passed on", result.capture.png == nil)
	check(
		"the reason is the cancellation",
		result.capture.reason == "agent access was turned off",
		result.capture.reason
	)
	checkUntouched(world, rig, before)
	check("a later preview is not affected", Preview.run(request(rig)).transforms.Head.X == 0.5)
end)

case("a preview interrupted mid-screenshot is undone by one sweep, as on unload", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local frozen = false
	world.onWait = function()
		-- Stop the preview dead while its clone is shown, as an unload would.
		if Preview.subject() ~= nil and not frozen then
			frozen = true
			coroutine.yield()
		end
	end
	local thread = coroutine.create(function()
		return pcall(
			Preview.run,
			shot(world, rig, function()
				return { status = "ok", png = "image" }
			end)
		)
	end)
	coroutine.resume(thread)
	check("the preview stopped with its clone shown", frozen and rig.place:FindFirstChild(Preview.CLONE_NAME) ~= nil)

	local problems = Preview.sweep()
	check("the sweep reports no problem", #problems == 0, table.concat(problems, "; "))
	check("the clone is gone at once", rig.place:FindFirstChild(Preview.CLONE_NAME) == nil)
	check("nothing is owned any more", Preview.ownedCount() == 0)
	check("the approval was withdrawn", table.find(world.revoked, "the preview was interrupted") ~= nil)
	check("the original rig is unchanged", snapshot(rig.model) == before)

	-- Were the stopped preview ever to continue, it takes no image and changes nothing more.
	world.onWait = nil
	local _, finished, outcome = coroutine.resume(thread)
	local image = finished and type(outcome) == "table" and outcome.capture and outcome.capture.status == "ok"
	check("the interrupted preview returns no image", not image)
	check("the original rig is still unchanged", snapshot(rig.model) == before)
	check("previews work again", Preview.run(request(rig)).transforms.Head.X == 0.5)
end)

case("a second preview cannot start, or take an image, while a screenshot is in progress", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local inner: any = nil
	local innerShot = false
	local budget = Preview.SAMPLE_BUDGET
	local result = Preview.run(shot(world, rig, function()
		Preview.SAMPLE_BUDGET = 1
		inner = expectError(function()
			return Preview.run(request(rig, {
				capture = function()
					innerShot = true
					return { status = "ok", png = "other image" }
				end,
			}))
		end)
		Preview.SAMPLE_BUDGET = budget
		return { status = "ok", width = 4, height = 3, png = "image" }
	end))
	Preview.SAMPLE_BUDGET = budget
	check("the second preview was refused", inner ~= nil and inner.code == "PREVIEW_UNAVAILABLE", inner and inner.code)
	check("the second preview took no image", not innerShot)
	check("the first preview kept its own image", result.capture.status == "ok" and result.capture.png == "image")
	checkUntouched(world, rig, before)
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

Sampler.setEngine(nil)
Preview.setCaptureGate(nil)
print(`{count - failures}/{count} preview checks passed`)
if failures > 0 then
	process.exit(1)
end
