--!strict
-- Phase 0 experiments that need a real Studio. Each probe returns plain data describing
-- what was observed; the harness records it verbatim. Probes only ever run in the
-- disposable probe place (see Probe.server.luau).

local AnimationClipProvider = game:GetService("AnimationClipProvider")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Capture = require("../src/Preview/Capture")
local Clips = require("../src/Storage/Clips")
local Codec = require("../src/Core/Codec")
local Edit = require("../src/Editing/Edit")
local Handlers = require("../src/Handlers")
local Rig = require("../src/Rigs/Rig")
local Sampler = require("../src/Preview/Sampler")
local Sha256 = require("../src/Core/Sha256")
local CFrameVectors = require("./CFrameVectors")
local SyntheticRig = require("./SyntheticRig")

local Probes = {}

local TIMES = { 0, 0.25, 0.5, 0.75, 1 }

-- The test clip: three keyframes, linear easing, four joints including a translation.
local CLIP_OPERATIONS = {
	{ type = "set_pose", joint = "RightUpperArm", time = 0, rotation = { 0, 0, 0 } },
	{ type = "set_pose", joint = "RightLowerArm", time = 0, rotation = { 0, 0, 0 } },
	{ type = "set_pose", joint = "Head", time = 0, rotation = { 0, 0, 0 } },
	{ type = "set_pose", joint = "LowerTorso", time = 0, position = { 0, 0, 0 }, rotation = { 0, 0, 0 } },
	{ type = "set_pose", joint = "RightUpperArm", time = 0.5, rotation = { 0, 0, 120 } },
	{ type = "set_pose", joint = "RightLowerArm", time = 0.5, rotation = { 40, 0, 0 } },
	{ type = "set_pose", joint = "Head", time = 0.5, rotation = { 0, 30, 0 } },
	{ type = "set_pose", joint = "LowerTorso", time = 0.5, position = { 0, 0.5, 0 }, rotation = { 0, 15, 0 } },
	{ type = "set_pose", joint = "RightUpperArm", time = 1, rotation = { 30, -20, 170 } },
	{ type = "set_pose", joint = "RightLowerArm", time = 1, rotation = { 90, 0, 0 } },
	{ type = "set_pose", joint = "Head", time = 1, rotation = { 10, -30, 5 } },
	{ type = "set_pose", joint = "LowerTorso", time = 1, position = { 0.2, 0, -0.1 }, rotation = { 0, 0, 0 } },
}
local CLIP_JOINTS = { "RightUpperArm", "RightLowerArm", "Head", "LowerTorso" }

local function frames(count: number)
	for _ = 1, count do
		RunService.Heartbeat:Wait()
	end
end

local function delta(a: CFrame, b: CFrame): (number, number)
	local difference = a:ToObjectSpace(b)
	local _, angle = difference:ToAxisAngle()
	return difference.Position.Magnitude, math.deg(math.abs(angle))
end

local function identical(a: CFrame, b: CFrame): boolean
	local ca, cb = { a:GetComponents() }, { b:GetComponents() }
	for i = 1, 12 do
		if ca[i] ~= cb[i] then
			return false
		end
	end
	return true
end

-- Every animated part's CFrame relative to the root part.
local function relatives(model: Model): { [string]: CFrame }
	local root = model:FindFirstChild(Rig.ROOT) :: BasePart
	local result: { [string]: CFrame } = {}
	for _, name in Rig.R15_ORDER do
		local part = model:FindFirstChild(name, true)
		if part and part:IsA("BasePart") then
			result[name] = root.CFrame:ToObjectSpace(part.CFrame)
		end
	end
	return result
end

local function maxDelta(
	a: { [string]: CFrame },
	b: { [string]: CFrame }
): { position: number, degrees: number, joint: string }
	local worst = { position = 0, degrees = 0, joint = "" }
	for name, cframe in a do
		local other = b[name]
		if other then
			local position, degrees = delta(cframe, other)
			if position > worst.position or degrees > worst.degrees then
				worst.position = math.max(worst.position, position)
				worst.degrees = math.max(worst.degrees, degrees)
				worst.joint = name
			end
		end
	end
	return worst
end

local function guarded(run: () -> any): any
	local ok, result = xpcall(run, function(problem)
		return {
			ok = false,
			error = if type(problem) == "table" then problem else tostring(problem),
			trace = debug.traceback(),
		}
	end)
	if ok and type(result) == "table" and result.ok == nil then
		result.ok = true
	end
	return result
end

-- Runs a yielding call with a time limit. Returns finished, success, value.
local function withTimeout(seconds: number, run: () -> any): (boolean, boolean, any)
	local finished, success, value = false, false, nil :: any
	task.spawn(function()
		success, value = pcall(run)
		finished = true
	end)
	local deadline = os.clock() + seconds
	while not finished and os.clock() < deadline do
		task.wait(0.05)
	end
	return finished, success, value
end

function Probes.create(
	methods: { [string]: (params: any) -> any },
	registry: Handlers.Registry
): { [string]: (params: any) -> any }
	local probes: { [string]: (params: any) -> any } = {}
	local rigs: { [string]: Model } = {}
	local testClip: Clips.Working? = nil

	local function rigId(model: Model): string
		-- Registering through get_workspace keeps ids consistent with the real tool path.
		methods.get_workspace({})
		return registry.ids[model]
	end

	local function ensureRigs()
		if not rigs.Motor6D then
			rigs.Motor6D = SyntheticRig.build("Motor6D", "ProbeRigMotor6D", CFrame.new(-6, 5, 0))
			rigs.AnimationConstraint =
				SyntheticRig.build("AnimationConstraint", "ProbeRigAnimationConstraint", CFrame.new(6, 5, 0))
			frames(2)
		end
	end

	local function ensureClip(): Clips.Working
		ensureRigs()
		if not testClip then
			local opened = methods.open_animation({ rig_id = rigId(rigs.Motor6D), name = "ProbeClip" })
			local working = Clips.get(opened.clip_id)
			Edit.apply(working, Rig.scan(rigs.Motor6D).joints, opened.revision, CLIP_OPERATIONS)
			testClip = working
		end
		return testClip :: Clips.Working
	end

	probes["probe.echo"] = function(params: any): any
		return params
	end

	-- Stands in for the user pressing Ctrl+Z or Ctrl+Y in Studio.
	probes["probe.undo"] = function(params: any): any
		if params.redo == true then
			ChangeHistoryService:Redo()
		else
			ChangeHistoryService:Undo()
		end
		frames(3)
		return { done = true }
	end

	probes["probe.info"] = function(): any
		return {
			studio_version = version(),
			is_edit = RunService:IsEdit(),
			place_name = game.Name,
			place_id = game.PlaceId,
			signal_behavior = tostring(workspace.SignalBehavior),
		}
	end

	-- Builds both synthetic rigs and reports their ids, for the vertical-slice demonstration.
	probes["probe.setup"] = function(): any
		ensureRigs()
		local camera = workspace.CurrentCamera
		if camera then
			camera.CFrame = CFrame.lookAt(Vector3.new(0, 7, 22), Vector3.new(0, 4, 0))
		end
		return {
			motor6d_rig_id = rigId(rigs.Motor6D),
			animation_constraint_rig_id = rigId(rigs.AnimationConstraint),
		}
	end

	-- E3: do Motor6D and AnimationConstraint rigs behave alike?
	probes["probe.e3"] = function(): any
		return guarded(function(): any
			local working = ensureClip()
			local result: any = { rigs = {} }

			local descriptions = {}
			for class, model in rigs do
				descriptions[class] = Rig.describe(model, true)
			end
			local a, b = descriptions.Motor6D :: any, descriptions.AnimationConstraint :: any
			local restMismatch = {}
			for index, joint in a.joints do
				local other = b.joints[index]
				if
					not other
					or other.name ~= joint.name
					or other.parent ~= joint.parent
					or HttpService:JSONEncode(other.c0) ~= HttpService:JSONEncode(joint.c0)
					or HttpService:JSONEncode(other.c1) ~= HttpService:JSONEncode(joint.c1)
				then
					table.insert(restMismatch, joint.name)
				end
			end
			result.inspection = {
				motor6d = {
					supported = a.supported,
					reasons = a.reasons,
					joint_count = a.joint_count,
					classes = a.joint_classes,
				},
				animation_constraint = {
					supported = b.supported,
					reasons = b.reasons,
					joint_count = b.joint_count,
					classes = b.joint_classes,
				},
				rest_transform_mismatches = restMismatch,
			}

			local sampled: { [string]: { [string]: { [string]: CFrame } } } = {}
			for class, model in rigs do
				local scan = Rig.scan(model)
				local initial = relatives(model)
				local perTime: { [string]: { [string]: CFrame } } = {}
				local readNeedsFrame = { position = 0, degrees = 0 }
				local transformVsStored = { position = 0, degrees = 0 }
				local handle = Sampler.open(model, scan.joints, working.instance)
				for _, time in TIMES do
					Sampler.seek(handle, time)
					local immediate = relatives(model)
					frames(1)
					local settled = relatives(model)
					perTime[tostring(time)] = settled
					local lag = maxDelta(immediate, settled)
					readNeedsFrame.position = math.max(readNeedsFrame.position, lag.position)
					readNeedsFrame.degrees = math.max(readNeedsFrame.degrees, lag.degrees)

					local keyframe = Clips.findKeyframe(working.instance, time)
					if keyframe then
						for _, joint in CLIP_JOINTS do
							local pose = Clips.findPose(keyframe, joint) :: Pose
							local position, degrees = delta(Rig.getTransform(scan.joints[joint]), pose.CFrame)
							transformVsStored.position = math.max(transformVsStored.position, position)
							transformVsStored.degrees = math.max(transformVsStored.degrees, degrees)
						end
					end
				end
				local moved = maxDelta(initial, perTime["1"])
				Sampler.close(handle)
				frames(2)
				local afterReset = maxDelta(initial, relatives(model))
				local transformsIdentity = true
				for _, joint in scan.joints do
					if not identical(Rig.getTransform(joint), CFrame.identity) then
						transformsIdentity = false
					end
				end
				sampled[class] = perTime
				result.rigs[class] = {
					parts_moved_at_t1 = moved,
					part_read_immediate_vs_next_frame = readNeedsFrame,
					transform_vs_stored_pose_at_keyframes = transformVsStored,
					after_reset_vs_initial = afterReset,
					transforms_identity_after_reset = transformsIdentity,
				}
			end

			local between = {}
			for _, time in TIMES do
				between[tostring(time)] =
					maxDelta(sampled.Motor6D[tostring(time)], sampled.AnimationConstraint[tostring(time)])
			end
			result.motor6d_vs_animation_constraint_part_positions = between

			-- IsKinematic off: does the part still follow the clip in edit mode?
			local model = rigs.AnimationConstraint
			local scan = Rig.scan(model)
			local constraint = scan.joints.RightUpperArm.instance :: AnimationConstraint
			local kinematicReference = sampled.AnimationConstraint["1"]
			constraint.IsKinematic = false
			frames(2)
			local description = Rig.describe(model)
			local handle = Sampler.open(model, scan.joints, working.instance)
			Sampler.seek(handle, 1)
			frames(5)
			local nonKinematic = relatives(model)
			Sampler.close(handle)
			constraint.IsKinematic = true
			frames(2)
			result.is_kinematic_off = {
				reported_non_kinematic_joints = description.non_kinematic_joints,
				right_upper_arm_vs_kinematic_result = (function()
					local position, degrees = delta(nonKinematic.RightUpperArm, kinematicReference.RightUpperArm)
					return { position = position, degrees = degrees }
				end)(),
				worst_part_vs_kinematic_result = maxDelta(nonKinematic, kinematicReference),
			}

			-- A rig created by the engine, to see which joint class Roblox itself produces here.
			local finished, success, engineRig = withTimeout(30, function()
				return Players:CreateHumanoidModelFromDescription(
					Instance.new("HumanoidDescription"),
					Enum.HumanoidRigType.R15
				)
			end)
			local upgradeSetting = select(
				2,
				pcall(function()
					return tostring((game:GetService("StarterPlayer") :: any).AvatarJointUpgrade)
				end)
			)
			if finished and success and typeof(engineRig) == "Instance" and engineRig:IsA("Model") then
				engineRig.Name = "ProbeRigEngine"
				engineRig:PivotTo(CFrame.new(0, 5, -12))
				engineRig.Parent = workspace
				frames(2)
				local engineDescription = Rig.describe(engineRig)
				local engineScan = Rig.scan(engineRig)
				local initial = relatives(engineRig)
				local engineHandle = Sampler.open(engineRig, engineScan.joints, working.instance)
				Sampler.seek(engineHandle, 1)
				frames(1)
				local moved = maxDelta(initial, relatives(engineRig))
				Sampler.close(engineHandle)
				frames(2)
				result.engine_created_rig = {
					avatar_joint_upgrade_setting = upgradeSetting,
					supported = engineDescription.supported,
					reasons = engineDescription.reasons,
					joint_classes = engineDescription.joint_classes,
					extra_joints = #engineDescription.extra_joints,
					parts_moved_at_t1 = moved,
					after_reset_vs_initial = maxDelta(initial, relatives(engineRig)),
				}
			else
				result.engine_created_rig = {
					avatar_joint_upgrade_setting = upgradeSetting,
					created = false,
					reason = if not finished then "timed out" else tostring(engineRig),
				}
			end
			return result
		end)
	end

	-- E4: can the engine evaluate clips for us, exactly and repeatably?
	probes["probe.e4"] = function(): any
		return guarded(function(): any
			local working = ensureClip()
			local sequence = working.instance
			local model = rigs.Motor6D
			local scan = Rig.scan(model)
			local result: any = {}

			-- Route A: ClipEvaluator on a temporarily registered clip.
			local evaluator: any = { registered = false }
			local registered, clipId = pcall(function()
				return AnimationClipProvider:RegisterAnimationClip(sequence)
			end)
			evaluator.registered = registered
			evaluator.content_id = tostring(clipId)
			if registered then
				local finished, success, value = withTimeout(20, function()
					return (AnimationClipProvider :: any):GetClipEvaluatorAsync(clipId)
				end)
				evaluator.finished = finished
				evaluator.success = success
				if finished and success then
					evaluator.type = typeof(value)
					evaluator.description = tostring(value)
					local members = {}
					for _, name in
						{
							"Evaluate",
							"EvaluateAsync",
							"Sample",
							"SampleAsync",
							"GetPose",
							"EvaluatePose",
							"Length",
							"GetLength",
							"ClassName",
						}
					do
						local got, member = pcall(function()
							return value[name]
						end)
						members[name] = if got then typeof(member) else "error: " .. tostring(member)
					end
					evaluator.members = members
					local calls = {}
					for _, name in { "Evaluate", "Sample", "GetPose", "EvaluatePose" } do
						local called, output = pcall(function()
							return value[name](value, 0.5)
						end)
						if called then
							local summary: any = { type = typeof(output) }
							if type(output) == "table" then
								local keys = {}
								for key, item in output do
									if #keys >= 20 then
										break
									end
									table.insert(keys, `{tostring(key)}:{typeof(item)}`)
								end
								summary.keys = keys
							else
								summary.text = tostring(output)
							end
							calls[name] = summary
						else
							calls[name] = "error: " .. tostring(output)
						end
					end
					evaluator.calls = calls
				else
					evaluator.error = tostring(value)
				end
			end
			result.clip_evaluator = evaluator

			-- Route B: an AnimationTrack moved to an exact time, joint transforms read back.
			local strategies = {}
			for _, strategy in { "set_position", "step_delta" } do
				local report: any = {}
				local handle = Sampler.open(model, scan.joints, sequence)
				report.track_length = handle.track.Length

				local atKeyframes = { position = 0, degrees = 0 }
				for _, time in { 0, 0.5, 1 } do
					Sampler.seek(handle, time, strategy :: Sampler.Strategy)
					local keyframe = Clips.findKeyframe(sequence, time) :: Keyframe
					for _, joint in CLIP_JOINTS do
						local pose = Clips.findPose(keyframe, joint) :: Pose
						local position, degrees = delta(Rig.getTransform(scan.joints[joint]), pose.CFrame)
						atKeyframes.position = math.max(atKeyframes.position, position)
						atKeyframes.degrees = math.max(atKeyframes.degrees, degrees)
					end
				end
				report.error_at_keyframe_times = atKeyframes

				-- Linear easing: halfway between two keyframes should equal the halfway blend.
				local midpoint = { position = 0, degrees = 0 }
				for _, pair in { { 0, 0.5 }, { 0.5, 1 } } do
					local first = Clips.findKeyframe(sequence, pair[1]) :: Keyframe
					local second = Clips.findKeyframe(sequence, pair[2]) :: Keyframe
					Sampler.seek(handle, (pair[1] + pair[2]) / 2, strategy :: Sampler.Strategy)
					for _, joint in CLIP_JOINTS do
						local expected = (Clips.findPose(first, joint) :: Pose).CFrame:Lerp(
							(Clips.findPose(second, joint) :: Pose).CFrame,
							0.5
						)
						local position, degrees = delta(Rig.getTransform(scan.joints[joint]), expected)
						midpoint.position = math.max(midpoint.position, position)
						midpoint.degrees = math.max(midpoint.degrees, degrees)
					end
				end
				report.error_at_midpoints_vs_lerp = midpoint

				-- Repeatability: the same time must give the same bits, whatever was sampled before.
				Sampler.seek(handle, 0.37, strategy :: Sampler.Strategy)
				local reference = Sampler.transforms(handle, CLIP_JOINTS)
				local repeatIdentical, historyIdentical = true, true
				for _ = 1, 100 do
					Sampler.seek(handle, 0.37, strategy :: Sampler.Strategy)
					for name, cframe in Sampler.transforms(handle, CLIP_JOINTS) do
						if not identical(cframe, reference[name]) then
							repeatIdentical = false
						end
					end
				end
				for i = 1, 100 do
					Sampler.seek(handle, (i * 0.0731) % 1, strategy :: Sampler.Strategy)
					Sampler.seek(handle, 0.37, strategy :: Sampler.Strategy)
					for name, cframe in Sampler.transforms(handle, CLIP_JOINTS) do
						if not identical(cframe, reference[name]) then
							historyIdentical = false
						end
					end
				end
				report.identical_over_100_repeats = repeatIdentical
				report.identical_after_other_seeks = historyIdentical

				-- Does the joint transform need a rendered frame before it can be read?
				Sampler.seek(handle, 0.8, strategy :: Sampler.Strategy)
				local immediate = Sampler.transforms(handle, CLIP_JOINTS)
				frames(1)
				local settled = Sampler.transforms(handle, CLIP_JOINTS)
				report.transform_read_immediate_vs_next_frame = maxDelta(immediate, settled)

				Sampler.close(handle)
				frames(1)
				strategies[strategy] = report
			end
			result.track_seek = strategies
			return result
		end)
	end

	-- E6: is undo reliable, and are failed edits truly atomic?
	probes["probe.e6"] = function(): any
		return guarded(function(): any
			ensureRigs()
			local model = rigs.Motor6D
			local joints = Rig.scan(model).joints
			local opened = methods.open_animation({ rig_id = rigId(model), name = "UndoProbe" })
			local working = Clips.get(opened.clip_id)
			local sequence = working.instance
			local result: any = {}

			local undone, redone = 0, 0
			local undoSignal = ChangeHistoryService.OnUndo:Connect(function()
				undone += 1
			end)
			local redoSignal = ChangeHistoryService.OnRedo:Connect(function()
				redone += 1
			end)

			local function state(): string
				local parts = {}
				for _, keyframe in Clips.sortedKeyframes(sequence) do
					local poses = {}
					for _, descendant in keyframe:GetDescendants() do
						if descendant:IsA("Pose") and descendant.Weight > 0 then
							table.insert(
								poses,
								`{descendant.Name}={HttpService:JSONEncode(Rig.encode(descendant.CFrame))}`
							)
						end
					end
					table.sort(poses)
					table.insert(parts, `{keyframe.Time}:[{table.concat(poses, ",")}]`)
				end
				return table.concat(parts, ";")
			end

			local empty = state()
			local first = Edit.apply(working, joints, Clips.revisionOf(working), {
				{ type = "set_pose", joint = "Head", time = 0.5, rotation = { 0, 45, 0 } },
				{ type = "set_pose", joint = "LeftUpperArm", time = 0.5, rotation = { 0, 0, -90 } },
				{ type = "set_pose", joint = "LeftLowerArm", time = 0.5, rotation = { 30, 0, 0 } },
			})
			local afterFirst = state()
			local second = Edit.apply(
				working,
				joints,
				first.revision,
				{
					{ type = "set_pose", joint = "Head", time = 1, rotation = { 0, -45, 0 } },
					{ type = "set_pose", joint = "RightFoot", time = 1, position = { 0, 0.1, 0 } },
				} :: { any }
			)
			local afterSecond = state()
			result.batches = { first = first, second = second }

			-- One undo must revert exactly the last batch.
			local revisionBeforeUndo = Clips.revisionOf(working)
			ChangeHistoryService:Undo()
			frames(3)
			result.one_undo_reverts_one_batch = {
				state_equals_after_first_batch = state() == afterFirst,
				on_undo_fired = undone,
				revision_changed_by_undo = Clips.revisionOf(working) ~= revisionBeforeUndo,
				instance_still_parented = sequence.Parent ~= nil,
			}
			ChangeHistoryService:Undo()
			frames(3)
			result.second_undo_reverts_first_batch = { state_is_empty = state() == empty, on_undo_fired = undone }
			ChangeHistoryService:Redo()
			frames(3)
			ChangeHistoryService:Redo()
			frames(3)
			result.redo_restores_both =
				{ state_equals_after_second_batch = state() == afterSecond, on_redo_fired = redone }

			-- A stale revision is rejected and changes nothing.
			local staleOk, staleError = pcall(Edit.apply, working, joints, first.revision, {
				{ type = "set_pose", joint = "Head", time = 2, rotation = { 0, 0, 10 } },
			})
			result.stale_revision = {
				rejected = not staleOk,
				code = if type(staleError) == "table" then staleError.code else tostring(staleError),
				state_unchanged = state() == afterSecond,
			}

			-- A batch that fails part-way must leave no change, no revision bump and no undo entry.
			local revisionBeforeFailure = Clips.revisionOf(working)
			Edit.fault = function(_working: any, index: number)
				if index > 2 then
					error("injected failure", 0)
				end
			end
			local failedOk, failedError = pcall(Edit.apply, working, joints, revisionBeforeFailure, {
				{ type = "set_pose", joint = "Head", time = 3, rotation = { 0, 0, 10 } },
				{ type = "set_pose", joint = "Head", time = 3.5, rotation = { 0, 0, 20 } },
				{ type = "set_pose", joint = "Head", time = 4, rotation = { 0, 0, 30 } },
			})
			Edit.fault = nil
			frames(3)
			local unchangedAfterFailure = state() == afterSecond
			local revisionUnchanged = Clips.revisionOf(working) == revisionBeforeFailure
			-- If the failed batch left an undo entry, this undo would be a no-op instead of reverting batch two.
			ChangeHistoryService:Undo()
			frames(3)
			result.failed_batch = {
				failed = not failedOk,
				error = tostring(failedError),
				state_unchanged = unchangedAfterFailure,
				revision_unchanged = revisionUnchanged,
				next_undo_reverts_previous_batch = state() == afterFirst,
			}
			ChangeHistoryService:Redo()
			frames(3)

			-- Invalid input is rejected before any recording starts.
			local invalidOk, invalidError = pcall(Edit.apply, working, joints, Clips.revisionOf(working), {
				{ type = "set_pose", joint = "Head", time = 0.2, rotation = { 0, 0, 10 } },
				{ type = "set_pose", joint = "Tail", time = 0.2, rotation = { 0, 0, 10 } },
			})
			result.invalid_batch = {
				rejected = not invalidOk,
				code = if type(invalidError) == "table" then invalidError.code else tostring(invalidError),
				state_unchanged = state() == afterSecond,
			}

			-- Preview must add nothing to the undo history.
			ChangeHistoryService:ResetWaypoints()
			frames(2)
			local canUndoBefore = ChangeHistoryService:GetCanUndo()
			methods.preview_animation({ clip_id = working.id, time = 0.5, joints = { "Head" } })
			frames(3)
			local canUndoAfter = ChangeHistoryService:GetCanUndo()
			result.preview_adds_no_undo_entry = { can_undo_before = canUndoBefore, can_undo_after = canUndoAfter }

			-- A recording cannot be started while another is open; this is what a reload would leave behind.
			local open = ChangeHistoryService:TryBeginRecording("KeywrightProbeDangling")
			local nested = ChangeHistoryService:TryBeginRecording("KeywrightProbeNested")
			local inProgress = ChangeHistoryService:IsRecordingInProgress()
			ChangeHistoryService:FinishRecording("", Enum.FinishRecordingOperation.Cancel)
			local afterCancel = ChangeHistoryService:IsRecordingInProgress()
			local recovered = ChangeHistoryService:TryBeginRecording("KeywrightProbeRecovered")
			if recovered then
				ChangeHistoryService:FinishRecording(recovered, Enum.FinishRecordingOperation.Cancel)
			end
			result.dangling_recording = {
				first_started = open ~= nil,
				nested_refused = nested == nil,
				in_progress_while_open = inProgress,
				cancel_without_identifier_clears_it = not afterCancel,
				can_record_again = recovered ~= nil,
			}

			undoSignal:Disconnect()
			redoSignal:Disconnect()
			return result
		end)
	end

	-- E2: does capture behave predictably?
	probes["probe.e2"] = function(params: any): any
		return guarded(function(): any
			local working = ensureClip()
			local result: any = {}

			local exists, studioCapture = pcall(function()
				return game:GetService("StudioCaptureService")
			end)
			result.service_exists = exists and studioCapture ~= nil
			if not result.service_exists then
				result.error = tostring(studioCapture)
				return result
			end

			local canBefore, canBeforeReason = Capture.available()
			result.can_capture_before_permission = { value = canBefore, reason = canBeforeReason }
			local started = os.clock()
			local granted, reason = Capture.requestPermission(params.permission_timeout or 25)
			result.permission = { granted = granted, reason = reason, seconds = os.clock() - started }
			local canAfter, canAfterReason = Capture.available()
			result.can_capture_after_permission = { value = canAfter, reason = canAfterReason }
			if not granted then
				return result
			end

			local camera = workspace.CurrentCamera :: Camera
			result.viewport = { camera.ViewportSize.X, camera.ViewportSize.Y }

			local png = Capture.capture(768)
			result.png = {
				status = png.status,
				reason = png.reason,
				width = png.width,
				height = png.height,
				milliseconds = png.milliseconds,
				bytes = if png.png then buffer.len(png.png) else nil,
				signature_hex = if png.png and buffer.len(png.png) >= 8
					then Codec.toHex(buffer.fromstring(buffer.readstring(png.png, 0, 8)))
					else nil,
			}
			if png.png then
				result.json_encode_of_buffer_prefix =
					string.sub(HttpService:JSONEncode(buffer.fromstring("Keywright")), 1, 120)
			end

			-- How many frames after a seek does the capture show the new pose?
			local model = rigs.Motor6D
			local scan = Rig.scan(model)
			local function shot(): string?
				local captured = Capture.capture(160, Enum.StudioCaptureScreenshotFormat.RGBA8)
				return if captured.png then Codec.toHex(Sha256.digest(captured.png)) else nil
			end
			local handle = Sampler.open(model, scan.joints, working.instance)
			Sampler.seek(handle, 0)
			frames(10)
			local referenceStart = shot()
			Sampler.seek(handle, 1)
			frames(10)
			local referenceEnd = shot()
			local timing: any = { references_differ = referenceStart ~= referenceEnd and referenceStart ~= nil }
			if timing.references_differ then
				local matches = {}
				for wait = 0, 4 do
					Sampler.seek(handle, 0)
					frames(10)
					Sampler.seek(handle, 1)
					frames(wait)
					matches[tostring(wait)] = shot() == referenceEnd
				end
				timing.shows_new_pose_after_frames = matches
			end
			Sampler.close(handle)
			result.frames_after_seek = timing
			return result
		end)
	end

	-- E10: CFrame results from Studio, to compare with the same file run under Lune.
	probes["probe.e10"] = function(): any
		return { vectors = CFrameVectors(CFrame, Vector3) }
	end

	return probes
end

return Probes
