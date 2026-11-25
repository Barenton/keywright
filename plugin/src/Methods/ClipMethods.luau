--!strict
-- Working copies: opening, reading, editing, checking and discarding them.

local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")

local Clips = require("../Storage/Clips")
local Digest = require("../Inspection/Digest")
local Edit = require("../Editing/Edit")
local Errors = require("../Core/Errors")
local Preview = require("../Preview/Preview")
local Proposals = require("../Storage/Proposals")
local Reading = require("../Inspection/Reading")
local Recording = require("../Editing/Recording")
local Rig = require("../Rigs/Rig")
local Saves = require("../Storage/Saves")
local Shared = require("./Shared")
local Validate = require("../Inspection/Validate")

local EDIT_FINDINGS = Shared.EDIT_FINDINGS
local requireEdit = Shared.requireEdit
local requireString = Shared.requireString

local ClipMethods = {}

function ClipMethods.install(methods: { [string]: (params: any) -> any }, kit: Shared.Kit)
	local registry = kit.registry
	local rigModel = kit.rigModel
	local validationContext = kit.validationContext

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
		local result = Edit.apply(working, scan.joints, params.expected_revision, params.operations, sample)
		if params.validate == true then
			-- The checks on the clip as the edit leaves it, cut short: the full list is
			-- validate_animation's.
			local checked = Validate.run(working.instance, validationContext(model), table.clone(Validate.DEFAULTS))
			local issues = {}
			for index = 1, math.min(#checked.issues, EDIT_FINDINGS) do
				issues[index] = checked.issues[index]
			end
			result.validation = {
				valid = checked.valid,
				errors = checked.errors,
				warnings = checked.warnings,
				counts = checked.counts,
				issues = issues,
			}
		end
		return result
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
end

return ClipMethods
