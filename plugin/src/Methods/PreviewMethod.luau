--!strict
-- Previewing a working copy: sampling it at times or over the whole clip, with a picture,
-- numbers and comparisons.

local Capture = require("../Preview/Capture")
local Clips = require("../Storage/Clips")
local Codec = require("../Core/Codec")
local Edit = require("../Editing/Edit")
local Errors = require("../Core/Errors")
local Pose = require("../Rigs/Pose")
local Preview = require("../Preview/Preview")
local Sampler = require("../Preview/Sampler")
local Rig = require("../Rigs/Rig")
local Shared = require("./Shared")

local MAX_FRAMES = Shared.MAX_FRAMES
local MAX_SAMPLES = Shared.MAX_SAMPLES
local MAX_TRACKS = Shared.MAX_TRACKS
local MIN_SAMPLES = Shared.MIN_SAMPLES
local requireEdit = Shared.requireEdit
local requireString = Shared.requireString

local PreviewMethod = {}

function PreviewMethod.install(methods: { [string]: (params: any) -> any }, kit: Shared.Kit)
	local registry = kit.registry

	methods.preview_animation = function(params: any): any
		requireEdit()
		local working = Clips.get(requireString(params, "clip_id"))
		local model = registry.models[working.rigId]
		if not model or model.Parent == nil then
			Errors.throw("NOT_FOUND", "The rig this clip was opened for no longer exists.")
		end
		local function usableTime(value: any): boolean
			return type(value) == "number" and value == value and value >= 0 and value <= Edit.MAX_TIME
		end
		-- Several times at once make a filmstrip: the clip sampled at each, in order.
		local times: { number }? = nil
		if params.times ~= nil then
			if type(params.times) ~= "table" or #params.times < 2 or #params.times > MAX_FRAMES then
				Errors.throw("INVALID_ARGUMENT", `times must list from 2 to {MAX_FRAMES} times.`)
			end
			for _, value in params.times do
				if not usableTime(value) then
					Errors.throw("INVALID_ARGUMENT", `Every time must be from 0 to {Edit.MAX_TIME} seconds.`)
				end
			end
			if params.capture == true or params.check_placement == true then
				Errors.throw("INVALID_ARGUMENT", "A screenshot or a placement check is for one time, not several.")
			end
			times = params.times
		end
		-- The other clip's own times, one for each of times, when a move has been retimed:
		-- its impact compared with this clip's impact, wherever each falls.
		local otherTimes: { number }? = nil
		if params.compare_times ~= nil then
			if params.compare_with == nil or times == nil then
				Errors.throw("INVALID_ARGUMENT", "compare_times goes with times and compare_with.")
			end
			if type(params.compare_times) ~= "table" or #params.compare_times ~= #(times :: { number }) then
				Errors.throw("INVALID_ARGUMENT", "compare_times must list one time for each of times.")
			end
			for _, value in params.compare_times do
				if not usableTime(value) then
					Errors.throw("INVALID_ARGUMENT", `Every time must be from 0 to {Edit.MAX_TIME} seconds.`)
				end
			end
			otherTimes = params.compare_times
		end
		-- A number of samples asks for the motion over the whole clip: that many moments,
		-- evenly spread, with the parts tracked at each.
		local samples: number? = nil
		if params.samples ~= nil then
			if
				type(params.samples) ~= "number"
				or params.samples ~= math.floor(params.samples)
				or params.samples < MIN_SAMPLES
				or params.samples > MAX_SAMPLES
			then
				Errors.throw("INVALID_ARGUMENT", `samples must be a whole number from {MIN_SAMPLES} to {MAX_SAMPLES}.`)
			end
			if times or params.capture == true or params.check_placement == true or params.interrupt ~= nil then
				Errors.throw(
					"INVALID_ARGUMENT",
					"samples cannot be combined with times, an interruption, a screenshot or a placement check."
				)
			end
			samples = params.samples
		end
		local time = if times then times[1] elseif samples then 0 else params.time
		if not usableTime(time) then
			Errors.throw("INVALID_ARGUMENT", `time must be from 0 to {Edit.MAX_TIME} seconds.`)
		end
		local joints: { string } = {}
		if type(params.joints) == "table" then
			if #params.joints > 32 then
				Errors.throw("LIMIT_EXCEEDED", "At most 32 joints can be sampled in one preview.")
			end
			for _, name in params.joints do
				if type(name) ~= "string" then
					Errors.throw("INVALID_ARGUMENT", "joints must be a list of joint names.")
				end
				table.insert(joints, name)
			end
		end
		-- The original rig is only read here. Preview samples a disposable clone of it.
		local scan = Rig.require(model)
		-- Parts whose place in the rig is wanted as numbers, not only as a picture.
		local track: { string } = {}
		if params.track ~= nil then
			if type(params.track) ~= "table" or #params.track > 15 then
				Errors.throw("INVALID_ARGUMENT", "track must list at most 15 part names.")
			end
			for _, name in params.track do
				if type(name) ~= "string" or not scan.joints[name] then
					Errors.throw(
						"INVALID_ARGUMENT",
						`track: the rig has no joint "{tostring(name)}".`,
						"Call inspect_rig for the joint names."
					)
				end
				table.insert(track, name)
			end
		end
		-- A picture of the pose is drawn by the relay from where the parts are, which takes
		-- the transform of every joint, not only the ones asked about.
		local render = params.render == true
		-- Checking where Studio put the parts also takes every joint.
		local checkPlacement = params.check_placement == true
		local sampledJoints = joints
		if render or checkPlacement or #track > 0 or params.compare_with ~= nil then
			sampledJoints = {}
			for _, name in Rig.R15_ORDER do
				if scan.joints[name] then
					table.insert(sampledJoints, name)
				end
			end
		end
		local revision = Clips.revisionOf(working)
		local maxEdge = if type(params.max_edge) == "number" then math.clamp(params.max_edge, 64, 1536) else 768
		-- A clip has nothing after its last keyframe, so a later time is held there, and
		-- the result says which time it shows.
		local duration = Clips.duration(working.instance)
		local sampledTime = math.min(time, duration)

		local function restPose(): { any }
			local resting: { [string]: CFrame } = {}
			for name in scan.joints do
				resting[name] = CFrame.new()
			end
			return Pose.parts(scan, resting, CFrame.new())
		end
		local function encoded(transforms: { [string]: CFrame }): { [string]: any }
			local sampled = {}
			for _, name in joints do
				local cframe = transforms[name]
				if cframe then
					sampled[name] = Rig.encode(cframe)
				end
			end
			return sampled
		end

		if samples then
			if duration <= 0 then
				Errors.throw("INVALID_ARGUMENT", "The clip has no length, so there is no motion to sample.")
			end
			-- The parts to follow: the ones asked for, or the ends of the limbs, the head
			-- and the hips.
			local followed = track
			if #followed == 0 then
				followed = {}
				for _, name in { "Head", "LeftFoot", "LeftHand", "LowerTorso", "RightFoot", "RightHand" } do
					if scan.joints[name] then
						table.insert(followed, name)
					end
				end
			end
			if #followed > MAX_TRACKS then
				Errors.throw("INVALID_ARGUMENT", `At most {MAX_TRACKS} parts can be followed over a clip.`)
			end
			local everyJoint = {}
			for _, name in Rig.R15_ORDER do
				if scan.joints[name] then
					table.insert(everyJoint, name)
				end
			end
			local sampleTimes: { number } = {}
			local paths: { [string]: { { number } } } = {}
			-- The height of each part's lowest point at each moment, as validate measures it.
			local lowest: { [string]: { number } } = {}
			for _, name in followed do
				paths[name] = {}
			end
			local firstPose: { any }? = nil
			for index = 0, samples - 1 do
				if Clips.revisionOf(working) ~= revision then
					Errors.throw(
						"PREVIEW_UNAVAILABLE",
						"The clip changed while it was being sampled.",
						"Preview it again."
					)
				end
				local at = duration * index / (samples - 1)
				local sample = Preview.run({
					model = model,
					sequence = working.instance,
					time = at,
					joints = everyJoint,
					parent = workspace,
				})
				table.insert(sampleTimes, math.round(at * 10000) / 10000)
				for name, tracked in Pose.track(scan, sample.transforms, CFrame.new(), followed) do
					table.insert(paths[name], tracked.position)
					lowest[name] = lowest[name] or {}
					table.insert(lowest[name], tracked.lowest)
				end
				if index == 0 and render then
					firstPose = Pose.parts(scan, sample.transforms, CFrame.new())
				end
			end
			local keyframes = Clips.keyTimes(working.instance)
			return {
				clip_id = working.id,
				revision = revision,
				duration = math.round(duration * 1000) / 1000,
				motion = { times = sampleTimes, keyframes = keyframes, parts = paths, lowest = lowest },
				pose = if firstPose then { parts = firstPose, rest = restPose() } else nil,
			}
		end

		if params.interrupt ~= nil then
			-- Another clip of the rig interrupting this one, played by the engine as a game
			-- plays it: the pose through the hand-over, and how each clip was weighted.
			local cut = params.interrupt
			if type(cut) ~= "table" then
				Errors.throw("INVALID_ARGUMENT", "interrupt must give the clip, at and fade.")
			end
			if not times then
				Errors.throw(
					"INVALID_ARGUMENT",
					"interrupt needs times: the moments to show, in seconds after the interruption."
				)
			end
			if params.compare_with ~= nil or params.capture == true then
				Errors.throw("INVALID_ARGUMENT", "interrupt cannot be combined with compare_with or a screenshot.")
			end
			local offsets = times :: { number }
			for index = 2, #offsets do
				if offsets[index] <= offsets[index - 1] then
					Errors.throw("INVALID_ARGUMENT", "With interrupt, times must rise: seconds after the interruption.")
				end
			end
			if not usableTime(cut.at) or cut.at > duration + Clips.TIME_TOLERANCE then
				Errors.throw(
					"INVALID_ARGUMENT",
					`interrupt.at must be a time in this clip, from 0 to {math.round(duration * 1000) / 1000} seconds.`
				)
			end
			if type(cut.fade) ~= "number" or cut.fade ~= cut.fade or cut.fade < 0 or cut.fade > 2 then
				Errors.throw("INVALID_ARGUMENT", "interrupt.fade must be from 0 to 2 seconds.")
			end
			local from = if cut.from == nil then 0 else cut.from
			if not usableTime(from) then
				Errors.throw("INVALID_ARGUMENT", `interrupt.from must be from 0 to {Edit.MAX_TIME} seconds.`)
			end
			local other = Shared.otherClip(working, cut.clip, model, "interrupt.clip")
			-- The other clip's own length, and whether it loops: a clip that doesn't ends,
			-- and after both have ended nothing is playing to show.
			local otherLength = Clips.duration(other)
			local otherLoops = (other :: any).Loop == true
			if from > otherLength + Clips.TIME_TOLERANCE then
				Errors.throw(
					"INVALID_ARGUMENT",
					`interrupt.from is after the other clip ends, at {math.round(otherLength * 1000) / 1000} seconds.`
				)
			end
			if not otherLoops then
				-- A clip of a single pose has no length; it is played padded, for as long.
				local left = if otherLength > 0 then otherLength - from else Sampler.PAD_SECONDS
				if offsets[#offsets] > left + Clips.TIME_TOLERANCE then
					Errors.throw(
						"INVALID_ARGUMENT",
						`The other clip ends {math.round(left * 1000) / 1000} seconds after the interruption, and it doesn't loop: ask for times up to then.`
					)
				end
			end
			local result = Preview.run({
				model = model,
				sequence = working.instance,
				time = 0,
				parent = workspace,
				interrupt = { sequence = other, at = cut.at, from = from, fade = cut.fade, offsets = offsets },
			})
			if Clips.revisionOf(working) ~= revision then
				Errors.throw("PREVIEW_UNAVAILABLE", "The clip changed while it was being sampled.", "Preview it again.")
			end
			local frames, poses, moments = {}, {}, {}
			local function round(value: number, places: number): number
				return math.round(value * 10 ^ places) / 10 ^ places
			end
			local found: { any } = result.moments or {}
			for index, moment in found do
				local tracked = if #track > 0 then Pose.track(scan, moment.transforms, CFrame.new(), track) else nil
				if tracked then
					table.insert(moments, tracked)
				end
				local asked: { [string]: CFrame } = {}
				for _, name in joints do
					asked[name] = moment.transforms[name]
				end
				table.insert(frames, {
					time = offsets[index],
					this_time = round(moment.times[1], 3),
					-- A clip of a single pose plays padded to a length of its own: its time is 0.
					other_time = round(math.min(moment.times[2], otherLength), 3),
					weights = { this = round(moment.weights[1], 3), other = round(moment.weights[2], 3) },
					joints = if #joints > 0 then encoded(asked) else nil,
					parts = tracked,
				})
				if render then
					table.insert(poses, Pose.parts(scan, moment.transforms, CFrame.new()))
				end
			end
			if #moments > 0 then
				Pose.speeds(moments, offsets)
			end
			local priorities = result.priorities or {}
			return {
				clip_id = working.id,
				revision = revision,
				interrupt = {
					clip = other.Name,
					at = cut.at,
					from = from,
					fade = cut.fade,
					priorities = { this = priorities[1], other = priorities[2] },
					blended_by = "Roblox's animation engine, on a disposable copy of the rig: the other clip started with Play(fade) and this one stopped with Stop(fade), both advancing in real time. The weights are the tracks' own as the engine reports them.",
				},
				frames = frames,
				ranges = if #moments > 0 then Pose.ranges(moments) else nil,
				pose = if render then { frames = poses, rest = restPose() } else nil,
			}
		end

		if times then
			-- Another clip of the same rig to sample at the same times, for comparison.
			local other: Instance? = nil
			local otherName: string? = nil
			-- The other clip's length: it is sampled no later than its own end.
			local otherDuration = 0
			if params.compare_with ~= nil then
				other = Shared.otherClip(working, params.compare_with, model, "compare_with")
				otherName = (other :: Instance).Name
				otherDuration = Clips.duration(other :: Instance)
			end
			local frames, poses, moments = {}, {}, {}
			local shownTimes: { number } = {}
			local otherPoses, differences = {}, {}
			for index, at in times do
				if Clips.revisionOf(working) ~= revision then
					Errors.throw(
						"PREVIEW_UNAVAILABLE",
						"The clip changed while it was being sampled.",
						"Preview it again."
					)
				end
				local sample = Preview.run({
					model = model,
					sequence = working.instance,
					time = at,
					joints = sampledJoints,
					parent = workspace,
				})
				local shown = math.min(at, duration)
				local tracked = if #track > 0 then Pose.track(scan, sample.transforms, CFrame.new(), track) else nil
				if tracked then
					table.insert(moments, tracked)
					table.insert(shownTimes, shown)
				end
				table.insert(frames, {
					time = shown,
					requested_time = if shown ~= at then at else nil,
					joints = if #joints > 0 then encoded(sample.transforms) else nil,
					parts = tracked,
				})
				if render then
					table.insert(poses, Pose.parts(scan, sample.transforms, CFrame.new()))
				end
				if other then
					local otherAt = if otherTimes then otherTimes[index] else at
					local second = Preview.run({
						model = model,
						sequence = other,
						time = otherAt,
						joints = sampledJoints,
						parent = workspace,
					})
					-- How far apart the two clips put the rig's parts at this moment.
					local apart = Pose.compare(
						Pose.place(scan, sample.transforms, CFrame.new()),
						Pose.place(scan, second.transforms, CFrame.new())
					)
					table.insert(differences, {
						time = shown,
						-- When the other clip was sampled, its end allowing: with compare_times or
						-- not, it can differ from this clip's time.
						other_time = math.min(otherAt, otherDuration),
						studs = math.round(apart.studs * 1000) / 1000,
						degrees = math.round(apart.degrees * 100) / 100,
						part = apart.worst,
					})
					if render then
						table.insert(otherPoses, Pose.parts(scan, second.transforms, CFrame.new()))
					end
				end
			end
			-- How fast each tracked part moved from one frame to the next.
			Pose.speeds(moments, shownTimes)
			return {
				clip_id = working.id,
				revision = revision,
				frames = frames,
				-- Over all the frames: how far each tracked part ranges.
				ranges = if #moments > 0 then Pose.ranges(moments) else nil,
				-- At each time: the largest distance and turn between the two clips' parts,
				-- and the part that is furthest apart.
				compared = if other then { name = otherName, differences = differences } else nil,
				pose = if render
					then { frames = poses, compare = if other then otherPoses else nil, rest = restPose() }
					else nil,
			}
		end

		local preview = Preview.run({
			model = model,
			sequence = working.instance,
			time = time,
			joints = sampledJoints,
			parent = workspace,
			measure = checkPlacement,
			-- A screenshot is taken only when the request asks for one, and then only if
			-- the capture gate allows it. The camera is whatever a person has framed.
			capture = if params.capture == true
				then function(guard: () -> string?)
					return Capture.capture(maxEdge, nil, guard) :: any
				end
				else nil,
			-- The clip as sampled; a screenshot of anything else is stale.
			current = function()
				return working.instance.Parent ~= nil and Clips.revisionOf(working) == revision
			end,
		})

		local sampled = encoded(preview.transforms)
		local response: any = {
			clip_id = working.id,
			revision = revision,
			time = sampledTime,
			requested_time = if sampledTime ~= time then time else nil,
			camera = "current",
			joints = sampled,
			parts = if #track > 0 then Pose.track(scan, preview.transforms, CFrame.new(), track) else nil,
		}
		if render then
			-- Positions relative to the rig's root part: nothing about the place is in them.
			-- The rest pose goes along, so that every picture of this rig can be framed the
			-- same way, whatever the pose: the rig then stays put from one picture to the next.
			response.pose = {
				parts = Pose.parts(scan, preview.transforms, CFrame.new()),
				rest = restPose(),
			}
		end
		if checkPlacement and preview.placed then
			-- How far Studio's own placement of the parts is from what the joints say.
			response.placement = Pose.compare(Pose.place(scan, preview.transforms, CFrame.new()), preview.placed)
		end
		local captured = preview.capture
		if captured then
			-- Exactly one image, and only for a request that asked for one and got it.
			local image = if captured.status == "ok" and type(captured.png) == "buffer" then captured.png else nil
			response.capture = {
				status = if image then "ok" else "unavailable",
				reason = if image then nil else (captured.reason or "the capture returned no image"),
				format = if image then captured.format else nil,
				width = if image then captured.width else nil,
				height = if image then captured.height else nil,
				bytes = if image then captured.bytes else nil,
				max_edge = if image then maxEdge else nil,
				milliseconds = captured.milliseconds,
			}
			if image then
				response.images = { { png_base64 = Codec.toBase64(image) } }
			end
		end
		return response
	end
end

return PreviewMethod
