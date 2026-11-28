--!strict
-- Saving a working copy as a new clip, proposing that it replace the clip it came from,
-- and proposing that a saved clip be deleted; settling a proposal is the panel's alone.

local ServerStorage = game:GetService("ServerStorage")

local Clips = require("../Storage/Clips")
local Digest = require("../Inspection/Digest")
local Errors = require("../Core/Errors")
local Proposals = require("../Storage/Proposals")
local Recording = require("../Editing/Recording")
local Saves = require("../Storage/Saves")
local Shared = require("./Shared")
local Validate = require("../Inspection/Validate")

local REJECTED_IN_STUDIO = Shared.REJECTED_IN_STUDIO
local requireEdit = Shared.requireEdit
local requireString = Shared.requireString

export type Panel = {
	-- Approves or rejects the proposal waiting for a working copy. Returns nil, or what
	-- stopped an approval that can be tried again.
	decide: (clipId: string, approve: boolean) -> string?,
}

local Save = {}

function Save.install(methods: { [string]: (params: any) -> any }, kit: Shared.Kit): Panel
	local registry = kit.registry
	local validationContext = kit.validationContext

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

	-- A saved clip of a rig, by name, as the Animation Editor keeps it.
	local function savedClip(model: Model, name: string): Instance?
		local container = Saves.container(model, ServerStorage)
		local found = container and container:FindFirstChild(name)
		if found and (found:IsA("KeyframeSequence") or found:IsA("CurveAnimation")) then
			return found
		end
		return nil
	end

	-- Proposes deleting one of a rig's saved clips. Like a replacement, a person settles it
	-- in the panel; the agent only asks, and calls again to see the outcome.
	methods.delete_saved_clip = function(params: any): any
		requireEdit()
		local model, rigId = kit.rigModel(params)
		local name = requireString(params, "name")
		local clip = savedClip(model, name)
		if not clip then
			Errors.throw("NOT_FOUND", `The rig has no saved clip "{name}".`, "get_workspace lists a rig's saved clips.")
		end
		local key = `delete:{rigId}:{name}`
		local fingerprint = Digest.of(clip :: Instance)
		local existing = Proposals.get(key)
		local proposal = if existing
				and existing.revision == fingerprint
				and existing.status ~= "approved"
			then existing
			else (Proposals.propose(key, fingerprint, name, model.Name, "delete"))
		return {
			rig_id = rigId,
			deletion = {
				name = name,
				status = proposal.status,
				reason = proposal.reason,
				hint = if proposal.status == "pending"
					then "A person must approve or reject this in the Keywright panel in Studio. Call again to see the outcome."
					elseif
						proposal.status == "rejected"
					then "It will not be proposed again while the clip is unchanged."
					else nil,
			},
		}
	end

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
				Proposals.settle(clipId, false, REJECTED_IN_STUDIO)
				return nil
			end
			-- A replacement: everything is checked again, as time has passed since it was proposed.
			local function replace()
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
			end
			local ok, problem = pcall(function()
				requireEdit()
				if proposal.kind == "delete" then
					-- The clip must still be there and still be what the agent asked about.
					local rigId = string.match(clipId, "^delete:([^:]+):")
					local model = rigId and registry.models[rigId]
					if not model or model.Parent == nil then
						Errors.throw("NOT_FOUND", "The rig the clip belongs to no longer exists.")
					end
					local clip = savedClip(model :: Model, proposal.name)
					if not clip then
						Errors.throw("NOT_FOUND", "The saved clip is no longer there.")
					end
					if Digest.of(clip :: Instance) ~= proposal.revision then
						Errors.throw("SOURCE_CHANGED", "The saved clip was changed after the deletion was proposed.")
					end
					-- Taken out of the place as one undo step, so Undo puts it back.
					local recording = Recording.begin("KeywrightDelete", "Keywright delete saved clip")
					local removed, failure = pcall(function()
						(clip :: Instance).Parent = nil
					end)
					Recording.finish(recording, removed)
					if not removed then
						error(failure, 0)
					end
				else
					replace()
				end
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
	return panel
end

return Save
