--!strict
-- The methods a Studio session answers. Each takes decoded parameters and returns a
-- plain table, or throws a structured error.

local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")

local Capture = require("./Capture")
local Clips = require("./Clips")
local Codec = require("./Codec")
local Digest = require("./Digest")
local Edit = require("./Edit")
local Errors = require("./Errors")
local Pose = require("./Pose")
local Preview = require("./Preview")
local Proposals = require("./Proposals")
local Reading = require("./Reading")
local Recording = require("./Recording")
local Rig = require("./Rig")
local Saves = require("./Saves")
local Validate = require("./Validate")

local Handlers = {}

export type Registry = {
	ids: { [Model]: string },
	models: { [string]: Model },
	nextId: number,
}

local function newRegistry(): Registry
	return { ids = {}, models = {}, nextId = 1 }
end

local function register(registry: Registry, model: Model): string
	local existing = registry.ids[model]
	if existing then
		return existing
	end
	local id = "rig_" .. registry.nextId
	registry.nextId += 1
	registry.ids[model] = id
	registry.models[id] = model
	return id
end

local function requireString(params: any, key: string): string
	local value = params and params[key]
	if type(value) ~= "string" or value == "" then
		Errors.throw("INVALID_ARGUMENT", `"{key}" is required.`)
	end
	return value
end

-- Most moments of a clip that one preview samples for a filmstrip.
local MAX_FRAMES = 8
-- For following parts over a whole clip: how many moments, and how many parts.
local MIN_SAMPLES = 9
local MAX_SAMPLES = 48
local MAX_TRACKS = 8

local function requireEdit()
	if not RunService:IsEdit() then
		Errors.throw("STUDIO_NOT_IN_EDIT_MODE", "Studio is running a playtest.", "Stop the playtest and try again.")
	end
end

-- The reason recorded when a person turns a proposal down.
Handlers.REJECTED_IN_STUDIO = "A person rejected it in Studio."

-- What the panel may do that no request can: settle a proposed replacement.
export type Panel = {
	-- Approves or rejects the proposal waiting for a working copy. Returns nil, or what
	-- stopped an approval that can be tried again.
	decide: (clipId: string, approve: boolean) -> string?,
}

function Handlers.create(): ({ [string]: (params: any) -> any }, Registry, Panel)
	local registry = newRegistry()
	local methods: { [string]: (params: any) -> any } = {}

	local function rigModel(params: any): (Model, string)
		local rigId = requireString(params, "rig_id")
		local model = registry.models[rigId]
		if not model or model.Parent == nil then
			Errors.throw("NOT_FOUND", `No rig "{rigId}".`, "Call get_workspace to list rigs.")
		end
		return model, rigId
	end

	-- Working copies left in the place by an earlier session of the plugin are picked up
	-- for rigs that are still in the workspace.
	local function restore(): number
		return Clips.restore(function(model: Instance): string?
			if model:IsA("Model") and model.Parent == workspace and model:FindFirstChildOfClass("Humanoid") then
				return register(registry, model)
			end
			return nil
		end)
	end

	methods.get_workspace = function(_params: any): any
		local rigs = {}
		for _, child in workspace:GetChildren() do
			if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then
				local description = Rig.describe(child)
				local saved, savedTotal = Saves.names(child, ServerStorage)
				table.insert(rigs, {
					rig_id = register(registry, child),
					name = child.Name,
					supported = description.supported,
					joint_classes = description.joint_classes,
					-- Clips saved for this rig, as the Animation Editor lists them.
					saved_clips = saved,
					-- Present only when the list above is not all of them.
					saved_clips_total = if savedTotal > #saved then savedTotal else nil,
				})
			end
		end
		local selection = {}
		for index, instance in Selection:Get() do
			if index > 20 then
				break
			end
			table.insert(selection, {
				name = instance.Name,
				class = instance.ClassName,
				rig_id = if instance:IsA("Model") then registry.ids[instance] else nil,
			})
		end
		local captureAvailable, captureReason = Capture.available()
		local unassigned = restore()
		-- A working copy says so when a replacement of its source has been proposed.
		local copies = Clips.list()
		for _, copy in copies do
			local proposal = Proposals.get(copy.clip_id)
			if proposal then
				copy.replacement = { status = proposal.status, revision = proposal.revision }
			end
		end
		return {
			edit_mode = RunService:IsEdit(),
			rigs = rigs,
			selection = selection,
			working_copies = copies,
			-- Working copies in the place whose rig can no longer be told.
			unassigned_working_copies = if unassigned > 0 then unassigned else nil,
			capture = { available = captureAvailable, reason = captureReason },
		}
	end

	methods.inspect_rig = function(params: any): any
		local model, rigId = rigModel(params)
		local description, scan = Rig.describe(model, params.detail == true)
		local result = description :: any
		result.rig_id = rigId
		if description.supported then
			-- Which way each joint turns, so that a pose need not be found by trial.
			result.turns = Pose.turns(scan, CFrame.new())
			result.turns_note = Pose.TURNS_NOTE
		end
		return result
	end

	methods.open_animation = function(params: any): any
		requireEdit()
		local model, rigId = rigModel(params)
		Rig.require(model)

		local function clipOrRefuse(found: Instance, what: string): Instance
			if not found:IsA("KeyframeSequence") and not found:IsA("CurveAnimation") then
				Errors.throw("INVALID_ARGUMENT", `{what} is a {found.ClassName}, not an animation clip.`)
			end
			return found
		end
		local format = params.format
		if format ~= nil and format ~= "keyframes" and format ~= "curves" then
			Errors.throw("INVALID_ARGUMENT", 'format must be "keyframes" or "curves".')
		end
		local source: Instance? = nil
		if params.source == "selection" then
			local selected = Selection:Get()[1]
			if not selected then
				Errors.throw("NOT_FOUND", "Nothing is selected in the Explorer.")
			end
			source = clipOrRefuse(selected, "The selection")
		elseif type(params.source) == "string" and string.sub(params.source, 1, 6) == "saved:" then
			-- One of the rig's saved clips, as the Animation Editor lists them.
			local wanted = string.sub(params.source, 7)
			local container = Saves.container(model, ServerStorage)
			local found = container and container:FindFirstChild(wanted)
			if not found then
				Errors.throw(
					"NOT_FOUND",
					`This rig has no saved clip named "{wanted}".`,
					"Call get_workspace to list each rig's saved clips."
				)
			end
			source = clipOrRefuse(found :: Instance, `"{wanted}"`)
		elseif params.source ~= nil then
			Errors.throw(
				"INVALID_ARGUMENT",
				'source must be omitted, "selection", or "saved:" followed by a clip name.'
			)
		end

		local name = if type(params.name) == "string" and params.name ~= ""
			then string.sub(params.name, 1, 100)
			elseif source then source.Name
			else "Untitled"

		local recording = Recording.begin("KeywrightOpen", "Keywright open animation")
		local ok, result = pcall(Clips.open, rigId, name, source, model, format)
		Recording.finish(recording, ok)
		if not ok then
			error(result, 0)
		end
		return Clips.read(result :: Clips.Working)
	end

	methods.read_animation = function(params: any): any
		local working = Clips.get(requireString(params, "clip_id"))
		local joints = params.joints
		if joints ~= nil then
			if type(joints) ~= "table" or #joints > Reading.MAX_JOINTS then
				Errors.throw("LIMIT_EXCEEDED", `At most {Reading.MAX_JOINTS} joints can be read at once.`)
			end
			for _, name in joints do
				if type(name) ~= "string" then
					Errors.throw("INVALID_ARGUMENT", "joints must be a list of joint names.")
				end
			end
		end
		local function optionalNumber(value: any, field: string): number?
			if value ~= nil and (type(value) ~= "number" or value ~= value or value < 0) then
				Errors.throw("INVALID_ARGUMENT", `{field} must be a number that is not negative.`)
			end
			return value
		end
		local result = Clips.read(working, {
			joints = joints,
			timeFrom = optionalNumber(params.time_from, "time_from"),
			timeTo = optionalNumber(params.time_to, "time_to"),
			offset = optionalNumber(params.offset, "offset"),
			limit = optionalNumber(params.limit, "limit"),
			quaternion = params.rotation_format == "quaternion",
			posesOnly = params.poses_only == true,
		})
		if params.hash == true then
			-- Worked out only on request: it reads the whole clip.
			result.content_hash = Digest.of(working.instance)
		end
		return result
	end

	methods.edit_animation = function(params: any): any
		local working = Clips.get(requireString(params, "clip_id"))
		local model = registry.models[working.rigId]
		if not model or model.Parent == nil then
			Errors.throw("NOT_FOUND", "The rig this clip was opened for no longer exists.")
		end
		local scan = Rig.require(model)
		-- A keyframe that holds the current pose needs the engine to say what that pose is.
		local function sample(sequence: Instance, time: number, joints: { string }): { [string]: CFrame }
			if #joints == 0 then
				return {}
			end
			return Preview.run({ model = model, sequence = sequence, time = time, joints = joints, parent = workspace }).transforms
		end
		return Edit.apply(working, scan.joints, params.expected_revision, params.operations, sample)
	end

	-- What the checks need to know about a rig: its joints, and which of them are driven
	-- through forces.
	local function validationContext(model: Model): Validate.Context
		local scan = Rig.require(model)
		local nonKinematic: { [string]: boolean } = {}
		for name, joint in scan.joints do
			if not Rig.isKinematic(joint) then
				nonKinematic[name] = true
			end
		end
		return { joints = scan.joints, nonKinematic = nonKinematic }
	end

	-- Runs the checks on a working copy. Changes nothing.
	methods.validate_animation = function(params: any): any
		local working = Clips.get(requireString(params, "clip_id"))
		local model = registry.models[working.rigId]
		if not model or model.Parent == nil then
			Errors.throw("NOT_FOUND", "The rig this clip was opened for no longer exists.")
		end
		local thresholds, problem = Validate.thresholds(params.thresholds)
		if not thresholds then
			Errors.throw("INVALID_ARGUMENT", problem :: string)
		end
		local result = Validate.run(working.instance, validationContext(model), thresholds :: { [string]: number })
		result.clip_id = working.id
		result.revision = Clips.revisionOf(working)
		return result
	end

	-- Saves a copy of a working copy as a new clip where the Animation Editor keeps the
	-- rig's clips. Nothing saved is ever replaced, and one undo removes the new clip.
	methods.save_animation = function(params: any): any
		requireEdit()
		local working = Clips.get(requireString(params, "clip_id"))
		local model = registry.models[working.rigId]
		if not model or model.Parent == nil then
			Errors.throw("NOT_FOUND", "The rig this clip was opened for no longer exists.")
		end
		local current = Clips.revisionOf(working)
		if params.expected_revision ~= current then
			Errors.throw(
				"REVISION_CONFLICT",
				`Expected revision {tostring(params.expected_revision)}, but the clip is at {current}.`,
				"Read the clip again, then save the revision you have seen."
			)
		end
		local name = if type(params.name) == "string" and params.name ~= "" then params.name else working.instance.Name
		-- A clip with structural errors is not saved. Warnings never stop a save.
		local checked = Validate.run(working.instance, validationContext(model), table.clone(Validate.DEFAULTS))
		if not checked.valid then
			Errors.throw(
				"VALIDATION_FAILED",
				`The clip has {checked.errors} structural {if checked.errors == 1 then "error" else "errors"}, so it was not saved.`,
				"Call validate_animation to see them, correct them, and save again."
			)
		end

		if params.replace_source == true then
			-- Not a save: a proposal that a person settles in the panel.
			local existing = Proposals.get(working.id)
			local proposal = if existing and existing.revision == current then existing else nil
			if not proposal then
				local state = Clips.sourceState(working)
				if state == "none" then
					Errors.throw(
						"INVALID_ARGUMENT",
						"This working copy has no clip to replace: it was opened blank.",
						"Save it as a new clip instead."
					)
				elseif (working.source :: Instance).ClassName ~= working.instance.ClassName then
					Errors.throw(
						"UNSUPPORTED_CLIP_FORMAT",
						"This working copy was converted to curves, so it cannot replace the keyframe clip it came from.",
						"Save it as a new clip instead."
					)
				elseif state ~= "unchanged" then
					Errors.throw(
						"SOURCE_CHANGED",
						if state == "missing"
							then "The clip this working copy was opened from is no longer in the place."
							else "The clip this working copy was opened from has been changed since.",
						"Save this working copy as a new clip, or open a new working copy from the clip as it is now."
					)
				end
				proposal = Proposals.propose(working.id, current, working.instance.Name, (working.source :: any).Name)
			end
			local found = proposal :: Proposals.Proposal
			return {
				clip_id = working.id,
				revision = current,
				replacement = {
					status = found.status,
					source = found.source,
					reason = found.reason,
					hint = if found.status == "pending"
						then "A person must approve or reject this in the Keywright panel in Studio. Call again to see the outcome."
						elseif found.status == "rejected" then "It will not be proposed again for this revision."
						else nil,
				},
			}
		end

		local recording = Recording.begin("KeywrightSave", "Keywright save animation")
		local ok, result = pcall(Saves.save, working.instance, model, ServerStorage, name, function(className: string)
			return Instance.new(className)
		end)
		Recording.finish(recording, ok)
		if not ok then
			error(result, 0)
		end
		return {
			clip_id = working.id,
			revision = current,
			saved = { name = name, rig = model.Name, saved_clips = (Saves.names(model, ServerStorage)) },
		}
	end

	-- Removes a working copy. Saved clips are not touched. One undo brings it back, and
	-- it is then picked up again as a working copy of its rig.
	methods.discard_animation = function(params: any): any
		requireEdit()
		local working = Clips.get(requireString(params, "clip_id"))
		local current = Clips.revisionOf(working)
		if params.expected_revision ~= current then
			Errors.throw(
				"REVISION_CONFLICT",
				`Expected revision {tostring(params.expected_revision)}, but the clip is at {current}.`,
				"Read the clip again, then discard the revision you have seen."
			)
		end
		local recording = Recording.begin("KeywrightDiscard", "Keywright discard animation")
		local name = working.instance.Name
		local ok, problem = pcall(function()
			-- Taken out of the place, not destroyed, so that undo can put it back.
			working.instance.Parent = nil
			Clips.unlink(working)
		end)
		Recording.finish(recording, ok)
		if not ok then
			error(problem, 0)
		end
		Clips.close(working)
		Proposals.forget(working.id)
		return { discarded = { clip_id = working.id, name = name } }
	end

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
			if times or params.capture == true or params.check_placement == true then
				Errors.throw(
					"INVALID_ARGUMENT",
					"samples cannot be combined with times, a screenshot or a placement check."
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
				motion = { times = sampleTimes, keyframes = keyframes, parts = paths },
				pose = if firstPose then { parts = firstPose, rest = restPose() } else nil,
			}
		end

		if times then
			-- Another clip of the same rig to sample at the same times, for comparison.
			local other: Instance? = nil
			local otherName: string? = nil
			if params.compare_with ~= nil then
				local wanted = params.compare_with
				if wanted == "source" then
					if Clips.sourceState(working) == "none" or Clips.sourceState(working) == "missing" then
						Errors.throw("INVALID_ARGUMENT", "This working copy has no source to compare with.")
					end
					other = working.source
				elseif type(wanted) == "string" and string.sub(wanted, 1, 6) == "saved:" then
					local container = Saves.container(model, ServerStorage)
					local found = container and container:FindFirstChild(string.sub(wanted, 7))
					if not found or not (found:IsA("KeyframeSequence") or found:IsA("CurveAnimation")) then
						Errors.throw(
							"NOT_FOUND",
							`The rig has no saved clip "{string.sub(wanted, 7)}".`,
							"get_workspace lists a rig's saved clips."
						)
					end
					other = found :: Instance
				elseif type(wanted) == "string" then
					local second = Clips.get(wanted)
					if second.rigId ~= working.rigId then
						Errors.throw("INVALID_ARGUMENT", "The two clips are for different rigs.")
					end
					other = second.instance
				else
					Errors.throw(
						"INVALID_ARGUMENT",
						'compare_with must be "source", "saved:" and a name, or a clip id.'
					)
				end
				otherName = (other :: Instance).Name
			end
			local frames, poses, moments = {}, {}, {}
			local shownTimes: { number } = {}
			local otherPoses, differences = {}, {}
			for _, at in times do
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
					local second = Preview.run({
						model = model,
						sequence = other,
						time = at,
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

	pcall(restore)
	-- Settling a proposal is the panel's alone: it is not among the methods a request can
	-- reach. An approval checks everything again, because time has passed since the
	-- proposal was made.
	local panel: Panel = {
		decide = function(clipId: string, approve: boolean): string?
			local proposal = Proposals.get(clipId)
			if not proposal or proposal.status ~= "pending" then
				return nil
			end
			if not approve then
				Proposals.settle(clipId, false, Handlers.REJECTED_IN_STUDIO)
				return nil
			end
			local ok, problem = pcall(function()
				requireEdit()
				local working = Clips.get(clipId)
				if Clips.revisionOf(working) ~= proposal.revision then
					Errors.throw(
						"REVISION_CONFLICT",
						"The working copy was changed after the replacement was proposed."
					)
				end
				local state = Clips.sourceState(working)
				if state ~= "unchanged" then
					Errors.throw(
						"SOURCE_CHANGED",
						"The clip to be replaced was changed or removed after the replacement was proposed."
					)
				end
				local model = registry.models[working.rigId]
				if not model or model.Parent == nil then
					Errors.throw("NOT_FOUND", "The rig this clip was opened for no longer exists.")
				end
				if
					not Validate.run(working.instance, validationContext(model), table.clone(Validate.DEFAULTS)).valid
				then
					Errors.throw("VALIDATION_FAILED", "The working copy has structural errors.")
				end
				local recording = Recording.begin("KeywrightReplace", "Keywright replace clip")
				Clips.replaceSource(working, function(done: boolean)
					Recording.finish(recording, done)
				end)
			end)
			if ok then
				Proposals.settle(clipId, true)
				return nil
			end
			local failure = Errors.from(problem)
			if failure.code == "STUDIO_NOT_IN_EDIT_MODE" then
				-- Nothing is wrong with the proposal; Studio cannot record a change just now.
				return `{failure.message} {failure.hint or ""}`
			end
			Proposals.settle(clipId, false, failure.message)
			return nil
		end,
	}

	return methods, registry, panel
end

-- Wraps a method table as the connection's request handler.
function Handlers.dispatcher(methods: { [string]: (params: any) -> any }): (method: string, params: any) -> any
	return function(method: string, params: any): any
		local handler = methods[method]
		if not handler then
			Errors.throw("INVALID_ARGUMENT", `Unknown method "{method}".`)
		end
		return handler(if type(params) == "table" then params else {})
	end
end

return Handlers
