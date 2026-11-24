--!strict
-- Atomic edit batches on a working copy.
--
-- A batch is checked, then tried on a scratch copy of the clip, and only then applied to
-- the clip itself, inside one undo recording. So a batch that cannot be done in full is
-- refused before anything is written, whatever the reason: a malformed operation, or one
-- that does not fit the clip as the operations before it leave it. Should the real
-- application fail all the same, its recording is cancelled, which Studio was seen to
-- revert (the experiment on undo, E6).
--
-- What each operation does is in Operations.

local RunService = game:GetService("RunService")

local Clips = require("./Clips")
local Errors = require("./Errors")
local Operations = require("./Operations")
local Recording = require("./Recording")
local Rig = require("./Rig")

local Edit = {}

Edit.MAX_OPERATIONS = Operations.MAX_OPERATIONS
Edit.MAX_TIME = Operations.MAX_TIME
Edit.MAX_POSITION = Operations.MAX_POSITION
Edit.MAX_KEYFRAMES = Operations.MAX_KEYFRAMES

-- Test hook: when set, called inside the undo recording before each operation is applied,
-- with the number of that operation. Nothing in the plugin sets it; a test build does, to
-- make a batch fail or stop partway.
Edit.fault = nil :: ((working: Clips.Working, index: number) -> ())?

function Edit.apply(
	working: Clips.Working,
	joints: { [string]: Rig.Joint },
	expectedRevision: any,
	operations: any
): any
	if not RunService:IsEdit() then
		Errors.throw("STUDIO_NOT_IN_EDIT_MODE", "Studio is running a playtest.", "Stop the playtest and try again.")
	end
	local current = Clips.revisionOf(working)
	if expectedRevision ~= current then
		Errors.throw(
			"REVISION_CONFLICT",
			`Expected revision {tostring(expectedRevision)}, but the clip is at {current}.`,
			"Read the clip again and reapply the change to the current revision."
		)
	end
	Operations.check(operations, joints)
	local context: Operations.Context = { joints = joints, source = working.source }

	-- The whole batch, on a copy nobody else can see. Anything that would fail fails here.
	local trial = working.instance:Clone()
	local tried, problem = pcall(Operations.run, trial, operations, context)
	trial:Destroy()
	if not tried then
		error(problem, 0)
	end

	local recording = Recording.begin("MotionBridgeEdit", "Motion Bridge edit")
	local changed: Operations.Changed = {}
	Clips.mutate(working, function()
		changed = Operations.run(working.instance, operations, context, function(index)
			if Edit.fault then
				Edit.fault(working, index)
			end
		end)
	end, function(ok)
		Recording.finish(recording, ok)
	end)

	return { revision = Clips.revisionOf(working), changed = changed }
end

return Edit
