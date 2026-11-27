--!strict
-- Evaluates a clip on a rig with the engine's own animation system: the clip is
-- registered under a temporary ID, played at zero speed, and stepped to an exact time.
--
-- Stepping an Animator advances every track playing on it, so the sampler refuses an
-- Animator that already has playing tracks. It writes joint transforms on the model it
-- is given and on nothing else; Preview only ever gives it a disposable clone.
--
-- A newly registered clip loads asynchronously. Until it has, the track has no length and
-- a seek lands on the rest pose (observed in Studio on 2026-11-23), so the sampler waits
-- for the track to report a length and refuses to sample if it never does. A clip whose
-- only keyframe is at time zero never has a length, so a temporary copy with one empty
-- keyframe added after it is played instead; the clip itself is not changed.
--
-- Exact seek and immediate read-back have only been spot-checked in Studio by hand.

local Curves = require("../Editing/Curves")
local Errors = require("../Core/Errors")
local Rig = require("../Rigs/Rig")

local Sampler = {}

-- Everything that touches the engine goes through this table, so the lifecycle and
-- ownership rules can be tested without Studio.
export type Engine = {
	newInstance: (className: string) -> any,
	registerClip: (sequence: any) -> string,
	loadTrack: (animator: any, animation: any) -> any,
	step: (animator: any, delta: number) -> (),
	playingTracks: (animator: any) -> { any },
	getTransform: (joint: any) -> any,
	setTransform: (joint: any, transform: any) -> (),
	destroy: (object: any) -> (),
	waitFrames: (count: number) -> (),
	clock: () -> number,
	spawn: (run: () -> ()) -> any,
	cancel: (thread: any) -> (),
}

export type Handle = {
	model: Model,
	joints: { [string]: Rig.Joint },
	animator: any,
	track: any?,
	-- Joint transforms as they were when the sampler opened, restored on close.
	saved: { [any]: any },
	-- Objects this sampler created, in creation order. Only these are destroyed.
	owned: { any },
	-- Latest time that can be sampled: the time of the clip's last keyframe.
	duration: number,
	-- Further tracks on the same Animator, as the clip that interrupts this one.
	others: { any },
	-- Whether the clip loops, which a static seek ignores and an interruption keeps.
	loops: boolean,
}

-- One moment of an interruption: the pose, and each clip's time and weight as the engine
-- reports them.
export type Moment = {
	transforms: { [string]: CFrame },
	times: { number },
	weights: { number },
}

-- Seconds a newly registered clip may take to load before sampling is refused.
Sampler.LOAD_BUDGET = 5
-- Seconds after the only keyframe at which a clip without duration is padded.
Sampler.PAD_SECONDS = 1
-- The folder that pads a curve clip with no length. Named after no part of any rig.
Sampler.PAD_NAME = "KeywrightPad"

-- How the track is moved to a time. scripts/measure.mjs compares these in Studio.
export type Strategy = "set_position" | "step_delta"

local function robloxEngine(): Engine
	local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
	local AnimationClipProvider = game:GetService("AnimationClipProvider")
	local RunService = game:GetService("RunService")
	return {
		newInstance = function(className)
			return Instance.new(className)
		end,
		registerClip = function(sequence)
			if sequence:IsA("CurveAnimation") then
				-- A clip made of curves, not keyframes. Being measured; see the notes.
				return AnimationClipProvider:RegisterAnimationClip(sequence)
			end
			return KeyframeSequenceProvider:RegisterKeyframeSequence(sequence)
		end,
		loadTrack = function(animator, animation)
			return animator:LoadAnimation(animation)
		end,
		step = function(animator, delta)
			animator:StepAnimations(delta)
		end,
		playingTracks = function(animator)
			return animator:GetPlayingAnimationTracks()
		end,
		getTransform = function(joint)
			return joint.Transform
		end,
		setTransform = function(joint, transform)
			joint.Transform = transform
		end,
		destroy = function(object)
			object:Destroy()
		end,
		waitFrames = function(count)
			for _ = 1, count do
				RunService.Heartbeat:Wait()
			end
		end,
		clock = os.clock,
		spawn = function(run)
			return task.spawn(run)
		end,
		cancel = function(thread)
			task.cancel(thread)
		end,
	}
end

-- Time of the clip's last keyframe, or for a clip made of curves, of the last key of any
-- of its curves.
local function clipDuration(sequence: Instance): number
	local last = 0
	if sequence:IsA("CurveAnimation") then
		for _, descendant: any in sequence:GetDescendants() do
			local ok, keys = pcall(function()
				return descendant:GetKeys()
			end)
			if ok and type(keys) == "table" then
				for _, key in keys do
					last = math.max(last, key.Time)
				end
			end
		end
		return last
	end
	for _, child in sequence:GetChildren() do
		if child:IsA("Keyframe") then
			last = math.max(last, (child :: Keyframe).Time)
		end
	end
	return last
end

local current: Engine? = nil

function Sampler.engine(): Engine
	if not current then
		current = robloxEngine()
	end
	return current :: Engine
end

-- Replaces the engine. For tests.
function Sampler.setEngine(engine: Engine?)
	current = engine
end

-- Stops the track, restores the joints and destroys what this sampler created.
-- Never throws: it attempts every step and returns a description of each that failed.
function Sampler.close(handle: Handle): { string }
	local engine = Sampler.engine()
	local problems: { string } = {}
	local function attempt(label: string, run: () -> ())
		local ok, problem = pcall(run :: any)
		if not ok then
			table.insert(problems, `{label}: {tostring(problem)}`)
		end
	end

	for _, other in handle.others do
		attempt("stop track", function()
			other:Stop(0)
		end)
	end
	if handle.track then
		attempt("stop track", function()
			handle.track:Stop(0)
			engine.step(handle.animator, 0)
		end)
	end
	for joint, transform in handle.saved do
		attempt("restore joint", function()
			engine.setTransform(joint, transform)
		end)
	end
	for index = #handle.owned, 1, -1 do
		local object = handle.owned[index]
		attempt("destroy sampler object", function()
			engine.destroy(object)
		end)
	end
	table.clear(handle.owned)
	table.clear(handle.saved)
	table.clear(handle.others)
	handle.track = nil
	return problems
end

-- Registers a clip and loads it as a track on the handle's Animator, waiting until it has
-- loaded. Everything made is recorded as the handle's own, so close destroys it.
local function load(handle: Handle, sequence: Instance, duration: number, checkpoint: (() -> ())?): any
	local engine = Sampler.engine()
	local animation = engine.newInstance("Animation")
	table.insert(handle.owned, animation)
	local played: any = sequence
	if duration <= 0 then
		-- A loaded track is recognised by its length, which this clip would never have.
		-- A copy is played with something at a later time that moves nothing: an empty
		-- keyframe, or for a clip made of curves, a curve that drives no joint.
		played = sequence:Clone()
		table.insert(handle.owned, played)
		if sequence:IsA("CurveAnimation") then
			local folder = engine.newInstance("Folder")
			-- Owned from the start, so a failure while it is put together still frees it.
			table.insert(handle.owned, folder)
			folder.Name = Sampler.PAD_NAME
			-- Laid out as a joint's rotation is, so that it counts toward the length.
			local group = engine.newInstance("EulerRotationCurve")
			group.Name = "Rotation"
			group.Parent = folder
			local curve = engine.newInstance("FloatCurve")
			curve.Name = "X"
			curve.Parent = group
			Curves.setKeys(curve, {
				{ time = 0, value = 0, interpolation = "Constant" },
				{ time = Sampler.PAD_SECONDS, value = 0, interpolation = "Constant" },
			})
			folder.Parent = played
		else
			local pad = engine.newInstance("Keyframe")
			pad.Time = Sampler.PAD_SECONDS
			pad.Parent = played
		end
	end
	animation.AnimationId = engine.registerClip(played)
	local track = engine.loadTrack(handle.animator, animation)
	table.insert(handle.owned, track)
	local deadline = engine.clock() + Sampler.LOAD_BUDGET
	while track.Length <= 0 do
		if engine.clock() >= deadline then
			Errors.throw("PREVIEW_UNAVAILABLE", "The clip did not finish loading in time.")
		end
		engine.waitFrames(1)
		if checkpoint then
			checkpoint()
		end
	end
	return track
end

function Sampler.open(model: Model, joints: { [string]: Rig.Joint }, sequence: Instance): Handle
	local engine = Sampler.engine()
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		Errors.throw("UNSUPPORTED_RIG", "The rig has no Humanoid.")
	end
	local animator: any = (humanoid :: Humanoid):FindFirstChildOfClass("Animator")
	if animator and #engine.playingTracks(animator) > 0 then
		Errors.throw(
			"PREVIEW_UNAVAILABLE",
			"The rig's Animator already has playing tracks, and stepping it would advance them."
		)
	end

	local duration = clipDuration(sequence)
	local handle: Handle = {
		model = model,
		joints = joints,
		animator = animator,
		track = nil,
		saved = {},
		owned = {},
		duration = duration,
		others = {},
		loops = (sequence :: any).Loop == true,
	}
	local ok, problem = pcall(function()
		for _, joint in joints do
			handle.saved[joint.instance] = engine.getTransform(joint.instance)
		end
		if not handle.animator then
			local created = engine.newInstance("Animator")
			table.insert(handle.owned, created)
			created.Parent = humanoid
			handle.animator = created
		end
		local track = load(handle, sequence, duration)
		handle.track = track
		track.Looped = false
		track:Play(0, 1, 0)
	end)
	if not ok then
		-- Initialisation failed part-way: release whatever was created before reporting it.
		local problems = Sampler.close(handle)
		if #problems > 0 then
			Errors.throw(
				"PREVIEW_UNAVAILABLE",
				`Sampling could not start ({tostring(Errors.from(problem).message)}) and cleanup was incomplete: {table.concat(
					problems,
					"; "
				)}`
			)
		end
		error(problem, 0)
	end
	return handle
end

function Sampler.seek(handle: Handle, time: number, strategy: Strategy?)
	local engine = Sampler.engine()
	if handle.track == nil then
		Errors.throw("PREVIEW_UNAVAILABLE", "The sampler is closed.")
	end
	local track: any = handle.track
	-- Never sample past the clip's last keyframe, where a padded copy has nothing.
	time = math.clamp(time, 0, handle.duration)
	if strategy == "step_delta" then
		track:AdjustSpeed(1)
		track.TimePosition = 0
		engine.step(handle.animator, 0)
		engine.step(handle.animator, time)
		track:AdjustSpeed(0)
	else
		track.TimePosition = time
		engine.step(handle.animator, 0)
	end
end

function Sampler.transforms(handle: Handle, names: { string }?): { [string]: CFrame }
	local engine = Sampler.engine()
	local result: { [string]: CFrame } = {}
	for _, name in names or Rig.R15_ORDER do
		local joint = handle.joints[name]
		if joint then
			result[name] = engine.getTransform(joint.instance)
		end
	end
	return result
end

-- Plays another clip interrupting this one, as a game does: this clip plays on from `at`,
-- the other starts from `from`, and over `fade` seconds this one fades out and the other
-- in, each by the engine's own fading, its priorities and blending. Both clips advance at
-- their own speed. The Animator is stepped to each of `offsets`, seconds after the
-- interruption in rising order, and the pose, each clip's time and each track's weight
-- are read there as the engine has them.
function Sampler.interrupt(
	handle: Handle,
	sequence: Instance,
	at: number,
	from: number,
	fade: number,
	offsets: { number },
	names: { string }?,
	checkpoint: (() -> ())?
): { Moment }
	local engine = Sampler.engine()
	if handle.track == nil then
		Errors.throw("PREVIEW_UNAVAILABLE", "The sampler is closed.")
	end
	local first: any = handle.track
	local second: any = load(handle, sequence, clipDuration(sequence), checkpoint)
	table.insert(handle.others, second)
	-- Each clip loops or not as it was made to, as in a game; a static seek ignores it.
	first.Looped = handle.loops
	second.Looped = (sequence :: any).Loop == true
	first.TimePosition = math.clamp(at, 0, handle.duration)
	first:AdjustSpeed(1)
	second:Play(fade, 1, 1)
	second.TimePosition = math.max(0, from)
	first:Stop(fade)
	engine.step(handle.animator, 0)
	local moments: { Moment } = {}
	local elapsed = 0
	for _, offset in offsets do
		-- Asked before each step: a preview given up on, or out of time, goes no further.
		if checkpoint then
			checkpoint()
		end
		if offset > elapsed then
			engine.step(handle.animator, offset - elapsed)
			elapsed = offset
		end
		table.insert(moments, {
			transforms = Sampler.transforms(handle, names),
			times = { first.TimePosition, second.TimePosition },
			weights = { first.WeightCurrent, second.WeightCurrent },
		})
	end
	return moments
end

return Sampler
