--!strict
-- The methods a Studio session answers. Each takes decoded parameters and returns a
-- plain table, or throws a structured error. The methods themselves are in Methods/, a
-- module for each group; this makes the session they share and installs them.

local ClipMethods = require("./Methods/ClipMethods")
local Clips = require("./Storage/Clips")
local Errors = require("./Core/Errors")
local PreviewMethod = require("./Methods/PreviewMethod")
local Rig = require("./Rigs/Rig")
local Save = require("./Methods/Save")
local Shared = require("./Methods/Shared")
local Validate = require("./Inspection/Validate")
local Workspace = require("./Methods/Workspace")

local Handlers = {}

export type Registry = Shared.Registry
export type Panel = Save.Panel

-- The reason recorded when a person turns a proposal down.
Handlers.REJECTED_IN_STUDIO = Shared.REJECTED_IN_STUDIO

function Handlers.create(): ({ [string]: (params: any) -> any }, Registry, Panel)
	local registry = Shared.newRegistry()
	local methods: { [string]: (params: any) -> any } = {}
	local requireString = Shared.requireString
	local register = Shared.register

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

	local kit: Shared.Kit = {
		registry = registry,
		rigModel = rigModel,
		restore = restore,
		validationContext = validationContext,
	}
	Workspace.install(methods, kit)
	ClipMethods.install(methods, kit)
	PreviewMethod.install(methods, kit)
	local panel = Save.install(methods, kit)
	pcall(restore)

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
