--!strict
-- Previews a clip without touching the rig it belongs to.
--
-- The rig is cloned, the clone is sanitized and given a new Animator of its own, and
-- the clip is sampled on the clone. The original rig is only read: its joints are never
-- written, its Animator is never stepped, and its tracks never advance. Everything the
-- preview creates is destroyed when it ends, whether it succeeded, failed part-way, or
-- ran out of time, and only objects created here are ever destroyed.
--
-- Where isolation or timing cannot be confirmed the preview fails rather than return a
-- result that might be wrong.
--
-- A screenshot is taken only when the request asks for one and the capture gate allows
-- it. The gate is closed unless an entry point opens it; the plugin people install never
-- does. For a screenshot the clone is shown where the rig stands and nothing else is
-- touched: the camera is never moved or changed here, so the picture is whatever a person
-- has already framed. Whether that framing is right is for the gate to prove; the image
-- is dropped if the gate, the clone or the clip changes while it is taken.
--
-- Sampling has been spot-checked in Studio by hand. Screenshots have not been run there.

local Capture = require("./Capture")
local Errors = require("./Errors")
local Rig = require("./Rig")
local Sampler = require("./Sampler")

local Preview = {}

Preview.CLONE_NAME = "MotionBridgePreview"
-- Seconds allowed for cloning, seeking and sampling.
Preview.SAMPLE_BUDGET = 10
-- Seconds a capture may take before it is abandoned and the clone removed.
Preview.CAPTURE_BUDGET = 45

-- Frames the viewport is given to draw the clone before the screenshot.
Preview.FRAMES_BEFORE_CAPTURE = 2

export type CaptureResult = { status: string, reason: string?, [string]: any }

-- The capture gate lives in Capture, so that nothing can take a screenshot around it.
Preview.CAPTURE_GATE_CLOSED = Capture.GATE_CLOSED

-- Opens the capture gate under the given rule, or closes it with nil. The gate starts
-- closed, and the rule is asked before every screenshot and again before it is returned.
function Preview.setCaptureGate(rule: Capture.Gate?, onRevoke: ((reason: string) -> ())?)
	Capture.setGate(rule, onRevoke)
end

-- Nil when a screenshot may be taken now, otherwise the reason it may not.
function Preview.captureRefusal(): string?
	return Capture.refusal()
end

export type Request = {
	model: Model,
	sequence: KeyframeSequence,
	time: number,
	joints: { string }?,
	-- Where the clone is placed while it exists.
	parent: Instance,
	-- Takes the screenshot. Called only while the clone is shown. It is handed a guard
	-- to ask before taking the image and before returning it.
	capture: ((guard: () -> string?) -> CaptureResult)?,
	-- False once what is being previewed has changed, which makes a screenshot stale.
	current: (() -> boolean)?,
}

export type Result = {
	transforms: { [string]: CFrame },
	capture: CaptureResult?,
}

-- Clones this module created that still exist. Normally empty between previews.
local owned: { [any]: boolean } = {}
-- A preview yields while its clip loads, so a second request can arrive meanwhile. Only
-- one runs at a time; otherwise the second would sweep the first one's clone.
local running = false

-- The preview in progress. A screenshot belongs to exactly one of these.
type Run = { ended: boolean, cancelled: string?, model: Model, clone: Model?, capturing: boolean }
local active: Run? = nil

-- Asks the preview in progress to give up its screenshot, and withdraws whatever
-- approval stood behind the capture gate. Used when agent access is turned off.
function Preview.cancel(reason: string?)
	local why = reason or "the preview was cancelled"
	if active then
		active.cancelled = why
	end
	Capture.revoke(why)
end

-- The rig being previewed for a screenshot right now and the clone standing in for it,
-- or nil when no screenshot is in progress. The capture gate uses this to check that
-- the picture would be of the subject it approved.
function Preview.subject(): { model: Model, clone: Model? }?
	local run = active
	if not run or run.ended or not run.capturing then
		return nil
	end
	return { model = run.model, clone = run.clone }
end

function Preview.ownedCount(): number
	local count = 0
	for _ in owned do
		count += 1
	end
	return count
end

-- Destroys clones left by a preview that could not finish cleaning up. Returns a
-- description of each one that still could not be destroyed.
local function clearLeftovers(): { string }
	local engine = Sampler.engine()
	local problems: { string } = {}
	for clone in owned do
		local ok, problem = pcall(engine.destroy :: any, clone)
		if ok then
			owned[clone] = nil
		else
			table.insert(problems, `destroy preview clone: {tostring(problem)}`)
		end
	end
	return problems
end

-- Ends whatever a preview left behind when it was interrupted, for example by the plugin
-- unloading: gives up any screenshot in progress, withdraws the approval behind the
-- capture gate, and destroys leftover clones. Returns what could not be destroyed.
function Preview.sweep(): { string }
	Preview.cancel("the preview was interrupted")
	return clearLeftovers()
end

local function unavailable(message: string): never
	return Errors.throw("PREVIEW_UNAVAILABLE", message, "The original rig was not changed.")
end

-- True when a joint or constraint is tied to something that is not part of the clone.
local function reachesOutside(instance: any, clone: Model): boolean
	local first, second = nil, nil
	if instance:IsA("JointInstance") or instance:IsA("WeldConstraint") then
		first, second = instance.Part0, instance.Part1
	elseif instance:IsA("Constraint") then
		first, second = instance.Attachment0, instance.Attachment1
	end
	return (first ~= nil and not first:IsDescendantOf(clone)) or (second ~= nil and not second:IsDescendantOf(clone))
end

-- Removes everything from the clone that could act on its own or reach outside it.
local function sanitize(clone: Model, engine: Sampler.Engine)
	for _, descendant: any in clone:GetDescendants() do
		if descendant.Parent == nil then
			continue
		end
		local remove = descendant:IsA("LuaSourceContainer") or descendant:IsA("Animator") or descendant:IsA("Sound")
		-- A joint or constraint tied to something outside the clone would pull on it.
		remove = remove or reachesOutside(descendant, clone)
		if remove then
			engine.destroy(descendant)
		else
			for _, tag in descendant:GetTags() do
				descendant:RemoveTag(tag)
			end
		end
	end
	for _, tag in clone:GetTags() do
		clone:RemoveTag(tag)
	end
end

-- Shows the clone for a screenshot: visible apart from its root part, and unable to be
-- hit, touched, found by queries or picked up in Studio.
local function show(clone: Model)
	for _, descendant: any in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = if descendant.Name == "HumanoidRootPart" then 1 else 0
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Locked = true
		end
	end
end

local function hide(clone: Model)
	for _, descendant: any in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CastShadow = false
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Locked = true
		elseif descendant:IsA("Decal") then
			descendant.Transparency = 1
		end
	end
end

-- Confirms the clone is self-contained before anything is played on it.
local function verifyIsolated(original: Model, clone: Model, animator: any, engine: Sampler.Engine)
	if clone == original or clone:IsDescendantOf(original) or original:IsDescendantOf(clone) then
		unavailable("The preview clone is not separate from the original rig.")
	end
	local animators = 0
	for _, descendant: any in clone:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			unavailable("The preview clone still contains a script.")
		elseif descendant:IsA("Animator") then
			animators += 1
			if descendant ~= animator then
				unavailable("The preview clone still contains an Animator from the original rig.")
			end
		end
		if reachesOutside(descendant, clone) then
			unavailable("The preview clone is still joined to something outside it.")
		end
	end
	if animators ~= 1 then
		unavailable("The preview clone does not have exactly one Animator.")
	end
	if #engine.playingTracks(animator) > 0 then
		unavailable("The preview clone's Animator already has playing tracks.")
	end
end

-- Runs a call that may yield, for at most `seconds` and only until `abandon` says to
-- stop. If it has not finished by then it is cancelled, and whatever it produces later
-- goes nowhere. Returns finished, succeeded, value.
local function bounded(
	engine: Sampler.Engine,
	seconds: number,
	run: () -> any,
	abandon: () -> boolean
): (boolean, boolean, any)
	local finished, succeeded, value = false, false, nil :: any
	-- Set before the call starts, so that time the call spends before yielding counts.
	local deadline = engine.clock() + seconds
	local thread = engine.spawn(function()
		local ok, result = pcall(run)
		succeeded, value = ok, result
		finished = true
	end)
	while not finished and engine.clock() < deadline and not abandon() do
		engine.waitFrames(1)
	end
	-- A result that is ready only after the deadline, or after being abandoned, is late.
	if finished and (engine.clock() > deadline or abandon()) then
		finished = false
	end
	if not finished then
		pcall(engine.cancel, thread)
		return false, false, nil
	end
	return finished, succeeded, value
end

function Preview.run(request: Request): Result
	local engine = Sampler.engine()

	local turn = engine.clock() + Preview.SAMPLE_BUDGET
	while running do
		if engine.clock() >= turn then
			unavailable("Another preview is still running.")
		end
		engine.waitFrames(1)
	end
	running = true

	-- A clone left behind earlier must be gone before another is made.
	local leftovers = clearLeftovers()
	if #leftovers > 0 then
		running = false
		unavailable(`An earlier preview could not be cleaned up: {table.concat(leftovers, "; ")}`)
	end

	local deadline = engine.clock() + Preview.SAMPLE_BUDGET
	local function checkBudget()
		if engine.clock() > deadline then
			unavailable("The preview exceeded its time budget.")
		end
	end

	local run: Run = { ended = false, cancelled = nil, model = request.model, clone = nil, capturing = false }
	active = run

	-- Decided once, before the clone is made: a clone is either shown for a screenshot
	-- or hidden, never switched between the two.
	local refusal: string? = nil
	if request.capture then
		refusal = Preview.captureRefusal()
	end
	local wantsCapture = request.capture ~= nil and refusal == nil
	local clone: Model? = nil
	local handle: Sampler.Handle? = nil

	-- Nil while a screenshot taken now would still show this preview, else the reason not.
	local function guard(): string?
		if run.ended then
			return "the preview has ended"
		elseif run.cancelled then
			return run.cancelled
		elseif active ~= run then
			return "another preview has taken over"
		end
		local closed = Capture.refusal(true)
		if closed then
			return closed
		elseif not clone or clone.Parent ~= request.parent then
			return "the preview clone is no longer in place"
		elseif request.current and not request.current() then
			return "the clip changed while the screenshot was being taken"
		end
		return nil
	end

	-- Takes the screenshot of the shown clone and reports it. Never throws.
	local function shoot(capture: (guard: () -> string?) -> CaptureResult): CaptureResult
		local function without(reason: any): CaptureResult
			return { status = "unavailable", reason = tostring(reason) }
		end
		run.capturing = true
		local waited, problem = pcall(function(): string?
			engine.waitFrames(Preview.FRAMES_BEFORE_CAPTURE)
			return guard()
		end)
		if not waited then
			return without(Errors.from(problem).message)
		elseif problem then
			return without(problem)
		end
		local finished, succeeded, value = bounded(engine, Preview.CAPTURE_BUDGET, function()
			return capture(guard)
		end, function()
			return run.cancelled ~= nil
		end)
		if not finished then
			return without(run.cancelled or "the capture exceeded its time budget")
		elseif not succeeded then
			return without(`the capture failed: {tostring(value)}`)
		elseif type(value) ~= "table" or type(value.status) ~= "string" then
			return without("the capture returned nothing usable")
		end
		-- An image taken while anything changed is not passed on.
		local stale = if value.status == "ok" then guard() else nil
		return if stale then without(stale) else value
	end

	local ok, outcome = pcall(function(): Result
		local copy = request.model:Clone()
		if not copy then
			unavailable("The rig cannot be cloned because it is not Archivable.")
		end
		clone = copy
		run.clone = copy
		owned[copy] = true
		-- Never saved with the place, even if Studio is closed while the clone exists.
		copy.Archivable = false
		copy.Name = Preview.CLONE_NAME

		sanitize(copy, engine)
		local humanoid = copy:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			Errors.throw("UNSUPPORTED_RIG", "The rig has no Humanoid.")
		end
		local animator = engine.newInstance("Animator")
		animator.Parent = humanoid
		verifyIsolated(request.model, copy, animator, engine)

		local scan = Rig.scan(copy)
		local expected = Rig.scan(request.model)
		for name in expected.joints do
			if not scan.joints[name] then
				unavailable(`The preview clone lost the joint that drives "{name}".`)
			end
		end

		if wantsCapture then
			show(copy)
		else
			hide(copy)
		end
		copy.Parent = request.parent
		checkBudget()

		local sampler = Sampler.open(copy, scan.joints, request.sequence)
		handle = sampler
		if sampler.animator ~= animator then
			unavailable("The sampler did not use the preview clone's own Animator.")
		end
		Sampler.seek(sampler, request.time)
		checkBudget()

		local result: Result = { transforms = Sampler.transforms(sampler, request.joints or {}) }
		if request.capture then
			result.capture = if wantsCapture
				then shoot(request.capture)
				else { status = "unavailable", reason = refusal }
		end
		return result
	end)

	-- Cleanup runs on every path and touches only what this preview created. From here
	-- on a late screenshot is refused.
	run.ended = true
	run.capturing = false
	if active == run then
		active = nil
	end
	local problems: { string } = {}
	if handle then
		for _, problem in Sampler.close(handle) do
			table.insert(problems, problem)
		end
	end
	if clone then
		local destroyed, problem = pcall(engine.destroy :: any, clone)
		if destroyed then
			owned[clone] = nil
		else
			table.insert(problems, `destroy preview clone: {tostring(problem)}`)
		end
	end
	running = false
	if #problems > 0 then
		local cause = if ok then "" else ` It had already failed: {Errors.from(outcome).message}`
		unavailable(`The preview could not be cleaned up completely: {table.concat(problems, "; ")}.{cause}`)
	end
	if not ok then
		error(outcome, 0)
	end
	return outcome
end

return Preview
