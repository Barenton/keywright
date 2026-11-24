--!strict
-- The methods a Studio session answers. Each takes decoded parameters and returns a
-- plain table, or throws a structured error.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")

local Capture = require("./Capture")
local Clips = require("./Clips")
local Codec = require("./Codec")
local Edit = require("./Edit")
local Errors = require("./Errors")
local Preview = require("./Preview")
local Rig = require("./Rig")

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
		return {
			edit_mode = RunService:IsEdit(),
			rigs = rigs,
			selection = selection,
			working_copies = Clips.list(),
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
		elseif params.source ~= nil then
			Errors.throw("INVALID_ARGUMENT", 'source must be omitted or "selection".')
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
				"Stop any playtest and retry."
			)
		end
		local ok, result = pcall(Clips.open, rigId, name, source)
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
		return Clips.read(working, params.joints, params.time_from, params.time_to)
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
		Rig.require(model)
		local revision = Clips.revisionOf(working)
		local maxEdge = if type(params.max_edge) == "number" then math.clamp(params.max_edge, 64, 1536) else 768

		local preview = Preview.run({
			model = model,
			sequence = working.instance,
			time = time,
			joints = joints,
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
		for name, cframe in preview.transforms do
			sampled[name] = Rig.encode(cframe)
		end
		local response: any = {
			clip_id = working.id,
			revision = revision,
			time = time,
			camera = "current",
			joints = sampled,
		}
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
