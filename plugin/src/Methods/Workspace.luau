--!strict
-- The workspace and its rigs: what sessions, rigs and working copies there are, and what a
-- rig is made of.

local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")

local Capture = require("../Preview/Capture")
local Clips = require("../Storage/Clips")
local Pose = require("../Rigs/Pose")
local Proposals = require("../Storage/Proposals")
local Rig = require("../Rigs/Rig")
local Saves = require("../Storage/Saves")
local Shared = require("./Shared")

local register = Shared.register

local Workspace = {}

function Workspace.install(methods: { [string]: (params: any) -> any }, kit: Shared.Kit)
	local registry = kit.registry
	local rigModel = kit.rigModel
	local restore = kit.restore

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
		-- Also counts the working copies whose rig has gone, deleted or taken out of the
		-- place, as it would after a reload; they are left out of the list below. If the
		-- rig comes back, for example by an undo, so does the copy.
		local unassigned = restore()
		local copies = {}
		for _, copy in Clips.list() do
			local model = registry.models[copy.rig_id]
			if model and model.Parent ~= nil then
				-- A working copy says so when a replacement of its source has been proposed.
				local proposal = Proposals.get(copy.clip_id)
				if proposal then
					copy.replacement = { status = proposal.status, revision = proposal.revision }
				end
				table.insert(copies, copy)
			end
		end
		return {
			edit_mode = RunService:IsEdit(),
			rigs = rigs,
			selection = selection,
			working_copies = copies,
			-- Working copies in the place whose rig is gone or can no longer be told.
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
end

return Workspace
