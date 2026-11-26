--!strict
-- What every method shares: the registry of rigs, the checks of a request's arguments, and
-- the limits.

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Clips = require("../Storage/Clips")
local Errors = require("../Core/Errors")
local Saves = require("../Storage/Saves")
local Validate = require("../Inspection/Validate")

local Shared = {}

export type Registry = {
	ids: { [Model]: string },
	models: { [string]: Model },
	nextId: number,
}

-- What the methods share from the session that installs them: the rigs it knows, and
-- the helpers that need them.
export type Kit = {
	registry: Registry,
	rigModel: (params: any) -> (Model, string),
	restore: () -> number,
	validationContext: (model: Model) -> Validate.Context,
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
-- Most findings an edit lists when it is asked to check the clip it leaves.
local EDIT_FINDINGS = 10

local function requireEdit()
	if not RunService:IsEdit() then
		Errors.throw("STUDIO_NOT_IN_EDIT_MODE", "Studio is running a playtest.", "Stop the playtest and try again.")
	end
end

-- The reason recorded when a person turns a proposal down.
local REJECTED_IN_STUDIO = "A person rejected it in Studio."

-- Another clip of a working copy's rig, named as compare_with and from_clip name one: the
-- clip it was opened from ("source"), a saved clip of the rig ("saved:" and its name), or
-- another working copy of the same rig by its id. `argument` names it in messages.
local function otherClip(working: Clips.Working, wanted: any, model: Model, argument: string): Instance
	if wanted == "source" then
		if Clips.sourceState(working) == "none" or Clips.sourceState(working) == "missing" then
			Errors.throw("INVALID_ARGUMENT", `{argument}: this working copy has no source clip.`)
		end
		return working.source :: Instance
	elseif type(wanted) == "string" and string.sub(wanted, 1, 6) == "saved:" then
		local container = Saves.container(model, ServerStorage)
		local found = container and container:FindFirstChild(string.sub(wanted, 7))
		if not found or not (found:IsA("KeyframeSequence") or found:IsA("CurveAnimation")) then
			Errors.throw(
				"NOT_FOUND",
				`{argument}: the rig has no saved clip "{string.sub(wanted, 7)}".`,
				"get_workspace lists a rig's saved clips."
			)
		end
		return found :: Instance
	elseif type(wanted) == "string" then
		local second = Clips.get(wanted)
		if second.rigId ~= working.rigId then
			Errors.throw("INVALID_ARGUMENT", `{argument}: the two clips are for different rigs.`)
		end
		return second.instance
	end
	Errors.throw("INVALID_ARGUMENT", `{argument} must be "source", "saved:" and a name, or a clip id.`)
	error("unreachable")
end

Shared.otherClip = otherClip
Shared.newRegistry = newRegistry
Shared.register = register
Shared.requireString = requireString
Shared.requireEdit = requireEdit
Shared.MAX_FRAMES = MAX_FRAMES
Shared.MIN_SAMPLES = MIN_SAMPLES
Shared.MAX_SAMPLES = MAX_SAMPLES
Shared.MAX_TRACKS = MAX_TRACKS
Shared.EDIT_FINDINGS = EDIT_FINDINGS
Shared.REJECTED_IN_STUDIO = REJECTED_IN_STUDIO

return Shared
