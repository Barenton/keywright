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

		local source: KeyframeSequence? = nil
		if params.source == "selection" then
			local selected = Selection:Get()[1]
			if not selected then
				Errors.throw("NOT_FOUND", "Nothing is selected in the Explorer.")
			elseif selected:IsA("CurveAnimation") then
				Errors.throw(
					"UNSUPPORTED_CLIP_FORMAT",
					"CurveAnimation clips are not supported.",
					"Only KeyframeSequence clips can be opened."
				)
			elseif not selected:IsA("KeyframeSequence") then
				Errors.throw("INVALID_ARGUMENT", `The selection is a {selected.ClassName}, not a KeyframeSequence.`)
			end
			source = selected :: KeyframeSequence
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
			elseif found:IsA("CurveAnimation") then
				Errors.throw(
					"UNSUPPORTED_CLIP_FORMAT",
					"CurveAnimation clips are not supported.",
					"Only KeyframeSequence clips can be opened."
				)
			elseif not found:IsA("KeyframeSequence") then
				Errors.throw("INVALID_ARGUMENT", `"{wanted}" is a {found.ClassName}, not a KeyframeSequence.`)
			end
			source = found :: KeyframeSequence
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

		local recording = Recording.begin("MotionBridgeOpen", "Motion Bridge open animation")
		local ok, result = pcall(Clips.open, rigId, name, source, model)
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
		local function sample(sequence: KeyframeSequence, time: number, joints: { string }): { [string]: CFrame }
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
						then "A person must approve or reject this in the Motion Bridge panel in Studio. Call again to see the outcome."
						elseif found.status == "rejected" then "It will not be proposed again for this revision."
						else nil,
				},
			}
		end

		local recording = Recording.begin("MotionBridgeSave", "Motion Bridge save animation")
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
		local recording = Recording.begin("MotionBridgeDiscard", "Motion Bridge discard animation")
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
		local time = params.time
		if type(time) ~= "number" or time ~= time or time < 0 or time > Edit.MAX_TIME then
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
		-- A picture of the pose is drawn by the relay from where the parts are, which takes
		-- the transform of every joint, not only the ones asked about.
		local render = params.render == true
		-- Checking where Studio put the parts also takes every joint.
		local checkPlacement = params.check_placement == true
		local sampledJoints = joints
		if render or checkPlacement then
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
		local duration = 0
		for _, keyframe in Clips.sortedKeyframes(working.instance) do
			duration = math.max(duration, keyframe.Time)
		end
		local sampledTime = math.min(time, duration)

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

		local sampled = {}
		for _, name in joints do
			local cframe = preview.transforms[name]
			if cframe then
				sampled[name] = Rig.encode(cframe)
			end
		end
		local response: any = {
			clip_id = working.id,
			revision = revision,
			time = sampledTime,
			requested_time = if sampledTime ~= time then time else nil,
			camera = "current",
			joints = sampled,
		}
		if render then
			-- Positions relative to the rig's root part: nothing about the place is in them.
			-- The rest pose goes along, so that every picture of this rig can be framed the
			-- same way, whatever the pose: the rig then stays put from one picture to the next.
			local resting: { [string]: CFrame } = {}
			for name in scan.joints do
				resting[name] = CFrame.new()
			end
			response.pose = {
				parts = Pose.parts(scan, preview.transforms, CFrame.new()),
				rest = Pose.parts(scan, resting, CFrame.new()),
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
				local recording = Recording.begin("MotionBridgeReplace", "Motion Bridge replace clip")
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
