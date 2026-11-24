--!strict
-- A person's approval of one scene, seen through one camera, for screenshots.
--
-- Approval is given by typing the fixture's own id into the arm attribute of the marker
-- the probe was started with. At that moment the scene, the camera and the viewport are
-- examined and recorded. A screenshot is allowed only while everything still is what was
-- recorded: the same marker, still armed with the same id, the same scene, the same
-- camera in the same position with the same field of view and viewport size, the 3D
-- viewport still the active tab, nothing selected, and the picture provably showing the
-- synthetic rig's place whole. The camera is never moved to make this true.
--
-- Approval is withdrawn for good when a screenshot is cancelled, the camera or tab is
-- switched, the marker is unarmed, the plugin unloads, or any check fails while an image
-- is being taken. Only a person can give it again, by clearing the attribute and typing
-- the id once more. This module only computes from what it is handed.

local FixtureGuard = require("./FixtureGuard")
local Stage = require("../src/Stage")

local Approval = {}

export type Observation = {
	-- The place and marker facts the fixture guard rules on.
	guard: FixtureGuard.Observation,
	-- The marker instance found in the place now.
	marker: any,
	-- The arm attribute's value now.
	armValue: any,
	-- The current camera and what it shows, or nil where either cannot be read.
	camera: any,
	view: Stage.View?,
	-- True only when the 3D viewport is known to be the active tab.
	viewportActive: boolean?,
	-- True only when nothing is known to be selected.
	selectionEmpty: boolean?,
	terrainCells: number?,
	-- The approved scene as it is now, or the reason the place is not that scene.
	scene: { rig: any, fingerprint: string, subject: Stage.Subject }?,
	sceneProblem: string?,
	-- The rig a screenshot in progress is of, and its clone.
	subject: { model: any, clone: any }?,
}

type Snapshot = {
	camera: any,
	view: Stage.View,
	fingerprint: string,
	rig: any,
}

export type State = {
	marker: any,
	id: string,
	approved: Snapshot?,
	-- Why there is no approval.
	withdrawn: string,
}

Approval.NEVER_GIVEN = "the fixture has not been armed since the probe started"

-- Pins approval to the marker instance and fixture id the probe was started with.
function Approval.new(marker: any, id: string): State
	return { marker = marker, id = id, approved = nil, withdrawn = Approval.NEVER_GIVEN }
end

-- Everything that must hold both when approval is given and whenever it is used.
local function problem(state: State, observation: Observation): string?
	local allowed, why = FixtureGuard.screenshots(observation.guard, observation.armValue, state.id)
	if not allowed then
		return why
	elseif state.marker == nil or observation.marker ~= state.marker then
		return "the fixture marker is not the one the probe was started with"
	elseif observation.viewportActive ~= true then
		return "the 3D viewport is not known to be the active tab"
	elseif observation.selectionEmpty ~= true then
		return "something is selected, and its outline could be in the picture"
	elseif observation.terrainCells ~= 0 then
		return "the place has terrain, or its terrain could not be checked"
	elseif observation.camera == nil or observation.view == nil then
		return "the camera could not be read"
	elseif observation.scene == nil then
		return observation.sceneProblem or "the scene could not be read"
	end
	local framing = Stage.framed(observation.view, observation.scene.subject)
	if framing then
		return `the camera is not framed on the synthetic rig: {framing}`
	end
	return nil
end

function Approval.disarm(state: State, reason: string)
	state.approved = nil
	state.withdrawn = reason
end

-- Records the scene and camera as approved. Call only when a person has just typed the
-- fixture id into the arm attribute. Returns whether approval was given, and why not.
function Approval.arm(state: State, observation: Observation): (boolean, string)
	state.approved = nil
	local refusal = problem(state, observation)
	if not refusal and observation.subject ~= nil then
		refusal = "a preview is in progress"
	end
	if refusal then
		state.withdrawn = refusal
		return false, refusal
	end
	local scene = observation.scene :: any
	local view = observation.view :: Stage.View
	state.approved = {
		camera = observation.camera,
		-- Copied, so that nothing the caller does to its table later alters the record.
		view = {
			cframe = view.cframe,
			fieldOfView = view.fieldOfView,
			width = view.width,
			height = view.height,
		},
		fingerprint = scene.fingerprint,
		rig = scene.rig,
	}
	state.withdrawn = ""
	return true, state.id
end

-- Nil when a screenshot is allowed now, otherwise the reason. With `capturing`, a
-- failure also withdraws the approval, and the subject of the screenshot must be the
-- approved rig; without it the question is only whether screenshots are possible.
function Approval.refusal(state: State, observation: Observation, capturing: boolean): string?
	local approved = state.approved
	if not approved then
		return `screenshots are off: {state.withdrawn}`
	end
	local refusal = problem(state, observation)
	if not refusal then
		local scene = observation.scene :: any
		if observation.camera ~= approved.camera then
			refusal = "the camera is not the one that was approved"
		elseif not Stage.same(observation.view :: Stage.View, approved.view) then
			refusal = "the camera or the viewport changed after it was approved"
		elseif scene.rig ~= approved.rig or scene.fingerprint ~= approved.fingerprint then
			refusal = "the scene changed after it was approved"
		elseif capturing then
			local subject = observation.subject
			if not subject or subject.model ~= approved.rig or subject.clone == nil then
				refusal = "the preview is not of the approved synthetic rig"
			end
		end
	end
	if not refusal then
		return nil
	end
	if capturing then
		Approval.disarm(state, `{refusal}; clear the arm attribute and set it again to re-approve`)
	end
	return `screenshots are off: {refusal}`
end

return Approval
