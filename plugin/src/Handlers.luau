--!strict
-- The methods a Studio session answers. Each takes decoded parameters and returns a
-- plain table, or throws a structured error.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
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
local Rig = require("./Rig")
local Saves = require("./Saves")

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

function Handlers.create(): ({ [string]: (params: any) -> any }, Registry)
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
				table.insert(rigs, {
					rig_id = register(registry, child),
					name = child.Name,
					supported = description.supported,
					joint_classes = description.joint_classes,
					-- Clips saved for this rig, as the Animation Editor lists them.
					saved_clips = Saves.names(child, ServerStorage),
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
		return {
			edit_mode = RunService:IsEdit(),
			rigs = rigs,
			selection = selection,
			working_copies = Clips.list(),
			-- Working copies in the place whose rig can no longer be told.
			unassigned_working_copies = if unassigned > 0 then unassigned else nil,
			capture = { available = captureAvailable, reason = captureReason },
		}
	end

	methods.inspect_rig = function(params: any): any
		local model, rigId = rigModel(params)
		local description = Rig.describe(model, params.detail == true) :: any
		description.rig_id = rigId
		return description
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

		local recording = ChangeHistoryService:TryBeginRecording("MotionBridgeOpen", "Motion Bridge open animation")
		if not recording then
			Errors.throw(
				"STUDIO_NOT_IN_EDIT_MODE",
				"Studio could not start an undo recording.",
				"Close the Animation Editor if it is open, stop any playtest, and retry."
			)
		end
		local ok, result = pcall(Clips.open, rigId, name, source, model)
		ChangeHistoryService:FinishRecording(
			recording :: string,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
		if not ok then
			error(result, 0)
		end
		return Clips.read(result :: Clips.Working)
	end

	methods.read_animation = function(params: any): any
		local working = Clips.get(requireString(params, "clip_id"))
		local result = Clips.read(working, params.joints, params.time_from, params.time_to)
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
		return Edit.apply(working, scan.joints, params.expected_revision, params.operations)
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

		local recording = ChangeHistoryService:TryBeginRecording("MotionBridgeSave", "Motion Bridge save animation")
		if not recording then
			Errors.throw(
				"STUDIO_NOT_IN_EDIT_MODE",
				"Studio could not start an undo recording.",
				"Close the Animation Editor if it is open, stop any playtest, and retry."
			)
		end
		local ok, result = pcall(Saves.save, working.instance, model, ServerStorage, name, function(className: string)
			return Instance.new(className)
		end)
		ChangeHistoryService:FinishRecording(
			recording :: string,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
		if not ok then
			error(result, 0)
		end
		return {
			clip_id = working.id,
			revision = current,
			saved = { name = name, rig = model.Name, saved_clips = Saves.names(model, ServerStorage) },
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
		local recording =
			ChangeHistoryService:TryBeginRecording("MotionBridgeDiscard", "Motion Bridge discard animation")
		if not recording then
			Errors.throw(
				"STUDIO_NOT_IN_EDIT_MODE",
				"Studio could not start an undo recording.",
				"Close the Animation Editor if it is open, stop any playtest, and retry."
			)
		end
		local name = working.instance.Name
		local ok, problem = pcall(function()
			-- Taken out of the place, not destroyed, so that undo can put it back.
			working.instance.Parent = nil
		end)
		ChangeHistoryService:FinishRecording(
			recording :: string,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
		if not ok then
			error(problem, 0)
		end
		Clips.close(working)
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
		local sampledJoints = joints
		if render then
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
			response.pose = { parts = Pose.parts(scan, preview.transforms, CFrame.new()) }
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
	return methods, registry
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
