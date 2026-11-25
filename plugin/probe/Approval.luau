--!strict
-- A person's approval of one scene, seen through one camera, for screenshots.
--
-- Approval comes from outside the place. A person types the fixture's id, which they
-- know from the files the fixture was prepared with, into the probe's own panel and
-- presses its button. Nothing stored in the place can give approval or stand in for
-- that: the place's marker only has to agree with what the person typed.
--
-- At that moment the scene, the camera and the viewport are examined and recorded. A
-- screenshot is allowed only while everything still is what was recorded: the same
-- marker, the same rig the probe built for this session, the same scene, the same
-- camera in the same position with the same field of view and viewport size, the 3D
-- viewport still the active tab, nothing selected, and the preview's copy of the rig,
-- as posed, provably whole in the picture above the baseplate. The camera is never moved
-- to make this true.
--
-- Approval is withdrawn for good when a screenshot is cancelled or runs out of time, the
-- camera or tab is switched, the person withdraws it, the plugin unloads, or any check
-- fails while an image is being taken. Only a person can give it again. This module
-- only computes from what it is handed.

local FixtureGuard = require("./FixtureGuard")
local Stage = require("../src/Preview/Stage")

local Approval = {}

export type Observation = {
	-- The place and marker facts the fixture guard rules on.
	guard: FixtureGuard.Observation,
	-- The marker instance found in the place now.
	marker: any,
	-- The current camera and what it shows, or nil where either cannot be read.
	camera: any,
	view: Stage.View?,
	-- True only when the 3D viewport is known to be the active tab.
	viewportActive: boolean?,
	-- True only when nothing is known to be selected.
	selectionEmpty: boolean?,
	terrainCells: number?,
	-- True only when camera and tab switches are being watched for.
	watching: boolean?,
	-- The approved scene as it is now, or the reason the place is not that scene.
	scene: {
		rig: any,
		fingerprint: string,
		subject: Stage.Subject,
		floor: number,
		posed: { Stage.Subject }?,
	}?,
	sceneProblem: string?,
	-- The rig a screenshot in progress is of, and its copy once that exists.
	subject: { model: any, clone: any }?,
}

type Snapshot = {
	camera: any,
	view: Stage.View,
	fingerprint: string,
}

export type State = {
	-- The marker and fixture id found when the probe started, and the rig it built.
	marker: any,
	id: string,
	rig: any,
	-- The fixture id the person typed when approving, held here and nowhere else.
	selected: string?,
	approved: Snapshot?,
	-- Why there is no approval.
	withdrawn: string,
}

Approval.NEVER_GIVEN = "no one has approved screenshots since the probe started"
-- How far above the baseplate the camera must be, in studs.
Approval.CAMERA_CLEARANCE = 0.25

-- Pins approval to the marker instance and fixture id the probe was started with, and to
-- the synthetic rig it built for this session.
function Approval.new(marker: any, id: string, rig: any): State
	return { marker = marker, id = id, rig = rig, selected = nil, approved = nil, withdrawn = Approval.NEVER_GIVEN }
end

-- Everything that must hold both when approval is given and whenever it is used.
local function problem(state: State, observation: Observation, selected: any): string?
	local allowed, why = FixtureGuard.screenshots(observation.guard, selected, state.id)
	if not allowed then
		return why
	elseif state.marker == nil or observation.marker ~= state.marker then
		return "the fixture marker is not the one the probe was started with"
	elseif state.rig == nil then
		return "the probe has no synthetic rig of its own in this session"
	elseif observation.watching ~= true then
		return "camera and tab switches are not being watched for"
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
	elseif observation.scene.rig ~= state.rig then
		return "the rig in the scene is not the one the probe built"
	end
	local view, scene = observation.view, observation.scene
	local framing = Stage.framed(view, scene.subject)
	if framing then
		return `the camera is not framed on the synthetic rig: {framing}`
	end
	-- Above the baseplate, looking at something above the baseplate, nothing in this
	-- scene can stand in between.
	if not (view.cframe.Position.Y > scene.floor + Approval.CAMERA_CLEARANCE) then
		return "the camera is at or below the baseplate"
	end
	return nil
end

function Approval.disarm(state: State, reason: string)
	state.approved = nil
	state.selected = nil
	state.withdrawn = reason
end

-- Records the scene and camera as approved. Call only when a person has just typed a
-- fixture id into the probe's panel and pressed its button; `typed` is what they typed.
-- Returns whether approval was given, and why not.
function Approval.arm(state: State, observation: Observation, typed: any): (boolean, string)
	Approval.disarm(state, Approval.NEVER_GIVEN)
	local refusal = problem(state, observation, typed)
	if not refusal and observation.subject ~= nil then
		refusal = "a preview is in progress"
	end
	if refusal then
		state.withdrawn = refusal
		return false, refusal
	end
	local scene = observation.scene :: any
	local view = observation.view :: Stage.View
	state.selected = typed
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
	}
	state.withdrawn = ""
	return true, state.id
end

-- Nil when a screenshot is allowed now, otherwise the reason. With `capturing`, a
-- failure also withdraws the approval, the subject of the screenshot must be the probe's
-- rig, and its copy, once shown, must be wholly in the picture as posed. Without it the
-- question is only whether screenshots are possible.
function Approval.refusal(state: State, observation: Observation, capturing: boolean): string?
	local approved = state.approved
	if not approved then
		return `screenshots are off: {state.withdrawn}`
	end
	local refusal = problem(state, observation, state.selected)
	if not refusal then
		local scene = observation.scene :: any
		local view = observation.view :: Stage.View
		if observation.camera ~= approved.camera then
			refusal = "the camera is not the one that was approved"
		elseif not Stage.same(view, approved.view) then
			refusal = "the camera or the viewport changed after it was approved"
		elseif scene.fingerprint ~= approved.fingerprint then
			refusal = "the scene changed after it was approved"
		elseif capturing then
			local subject = observation.subject
			if not subject or subject.model ~= state.rig then
				refusal = "the preview is not of the probe's synthetic rig"
			elseif subject.clone ~= nil then
				local outside = if scene.posed then Stage.holds(view, scene.posed) else "its position could not be read"
				if outside then
					refusal = `the posed preview is not wholly in the picture: {outside}`
				end
			end
		elseif observation.subject ~= nil and observation.subject.model ~= state.rig then
			refusal = "a preview of something else is in progress"
		end
	end
	if not refusal then
		return nil
	end
	if capturing then
		Approval.disarm(state, `{refusal}; approve again in the probe's panel`)
	end
	return `screenshots are off: {refusal}`
end

return Approval
