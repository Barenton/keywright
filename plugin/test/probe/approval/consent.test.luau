--!strict
-- Approval by a person: nothing until they approve, only for the probe's rig, withdrawn and given again only by them.
-- Run with: lune run plugin/test/probe/approval/consent.test.luau

local Kit = require("./kit")

local Approval = Kit.Approval
local approved = Kit.approved
local arm = Kit.arm
local CFrame = Kit.CFrame
local endPreview = Kit.endPreview
local FIXTURE_ID = Kit.FIXTURE_ID
local FixtureGuard = Kit.FixtureGuard
local inspect = Kit.inspect
local Instance = Kit.Instance
local newSession = Kit.newSession
local observe = Kit.observe
local OTHER_ID = Kit.OTHER_ID
local startPreview = Kit.startPreview
local Vector3 = Kit.Vector3
local viewOf = Kit.viewOf

local check, case, finish = Kit.suite("approval consent")
case("nothing is approved until a person approves in the panel", function()
	local session = newSession()
	local reason = Approval.refusal(session.state, observe(session), false)
	check("refused", reason ~= nil and string.find(reason, Approval.NEVER_GIVEN, 1, true) ~= nil, reason)
	startPreview(session)
	check("refused for a capture too", Approval.refusal(session.state, observe(session), true) ~= nil)
end)

case("an approved scene and camera allow a screenshot of the probe's rig", function()
	local session = approved(newSession())
	check("screenshots are possible", Approval.refusal(session.state, observe(session), false) == nil)
	-- Before the copy exists, Preview asks whether this rig may be shown at all.
	session.subject = { model = session.place.rig, clone = nil }
	check("the rig may be shown", Approval.refusal(session.state, observe(session), true) == nil)
	startPreview(session)
	local reason = Approval.refusal(session.state, observe(session), true)
	check("a screenshot of its copy is allowed", reason == nil, reason)
	check("and again, while nothing changes", Approval.refusal(session.state, observe(session), true) == nil)
end)

case("another rig may not even be shown", function()
	local session = approved(newSession())
	local other = Instance.new("Model")
	session.subject = { model = other, clone = nil }
	local reason = Approval.refusal(session.state, observe(session), true)
	check(
		"refused before any copy exists",
		reason ~= nil and string.find(reason, "not of the probe's synthetic rig") ~= nil,
		reason
	)
	session.subject = nil
	check("and the approval is withdrawn", Approval.refusal(session.state, observe(session), false) ~= nil)
end)

for label, value in
	{
		["true"] = true,
		["the text 'true'"] = "true",
		["another fixture's id"] = OTHER_ID,
		["this id in capitals"] = string.upper(FIXTURE_ID),
		["this id with a space"] = FIXTURE_ID .. " ",
		["the whole marker value"] = FixtureGuard.MARKER_PREFIX .. FIXTURE_ID,
		["a number"] = 1,
		["nothing"] = "<nil>",
		["an empty box"] = "",
	} :: { [string]: any }
do
	case(`typing {label} gives no approval`, function()
		local session = newSession()
		session.typed = if value == "<nil>" then nil else value
		local ok, why = arm(session)
		check("no approval", ok == false, why)
		check("a reason is given", type(why) == "string" and why ~= "")
		startPreview(session)
		check("no screenshot", Approval.refusal(session.state, observe(session), true) ~= nil)
	end)
end

case("the place cannot approve itself", function()
	-- A different, perfectly well-formed fixture: the probe started in it, so its marker
	-- and id are the pinned ones. The person types the id of the fixture they prepared.
	local copied = newSession()
	copied.marker.Value = FixtureGuard.MARKER_PREFIX .. OTHER_ID
	copied.state = Approval.new(copied.marker, OTHER_ID, copied.place.rig)
	local ok, why = arm(copied)
	check("a copied fixture is refused when the person types their own id", ok == false, why)
	check("the reason is the id", string.find(why, "not this fixture's") ~= nil, why)

	-- The marker is swapped after the probe started.
	local swapped = newSession()
	local other = Instance.new("StringValue")
	other.Name = FixtureGuard.MARKER_NAME
	other.Value = FixtureGuard.MARKER_PREFIX .. OTHER_ID
	swapped.foundMarker = other
	swapped.typed = OTHER_ID
	local again, reason = arm(swapped)
	check("a swapped marker is refused", again == false, reason)
	check("the reason names the fixture", string.find(reason, "not the one the probe was started in") ~= nil, reason)

	-- The same id on a new marker instance: the value is right, the marker is not the one.
	local replaced = newSession()
	local copy = Instance.new("StringValue")
	copy.Name = FixtureGuard.MARKER_NAME
	copy.Value = replaced.marker.Value
	replaced.foundMarker = copy
	local third, last = arm(replaced)
	check("a replaced marker is refused", third == false, last)
	check("the reason names the marker", string.find(last, "not the one the probe was started with") ~= nil, last)

	-- Nothing an observation carries can stand in for what the person typed.
	local silent = newSession()
	silent.typed = nil
	local observation = observe(silent)
	observation.armValue = FIXTURE_ID
	observation.selected = FIXTURE_ID
	observation.guard.armed = FIXTURE_ID
	check("values offered by the place are ignored", (Approval.arm(silent.state, observation, nil)) == false)

	-- A scene read around some other rig is not the probe's scene, whatever it looks like.
	local foreign = newSession()
	local reading = observe(foreign)
	reading.scene.rig = foreign.place.rig:Clone()
	local fourth, final = Approval.arm(foreign.state, reading, FIXTURE_ID)
	check("a scene built around another rig is refused", fourth == false, final)
	check("the reason names the rig", string.find(final, "not the one the probe built") ~= nil, final)
end)

for label, alter in
	{
		["the place is published"] = function(session: any)
			session.placeId = 123
		end,
		["a playtest is running"] = function(session: any)
			session.isEdit = false
		end,
		["the marker is gone"] = function(session: any)
			session.foundMarker = nil
		end,
		["the probe has no rig of its own"] = function(session: any)
			session.state = Approval.new(session.marker, FIXTURE_ID, nil)
		end,
		["camera and tab switches are not being watched"] = function(session: any)
			session.watching = false
		end,
		["whether switches are watched is unknown"] = function(session: any)
			session.watching = nil
		end,
		["a script tab is active"] = function(session: any)
			session.viewportActive = false
		end,
		["the active tab is unknown"] = function(session: any)
			session.viewportActive = nil
		end,
		["something is selected"] = function(session: any)
			session.selectionEmpty = false
		end,
		["the selection is unknown"] = function(session: any)
			session.selectionEmpty = nil
		end,
		["the place has terrain"] = function(session: any)
			session.terrainCells = 40
		end,
		["the terrain is unknown"] = function(session: any)
			session.terrainCells = nil
		end,
		["there is no camera"] = function(session: any)
			session.camera = nil
		end,
		["the camera cannot be read"] = function(session: any)
			session.view = nil
		end,
		["the camera is not framed on the rig"] = function(session: any)
			session.view.cframe = session.view.cframe * CFrame.Angles(0, math.rad(60), 0)
		end,
		["the camera is tilted"] = function(session: any)
			session.view.cframe = session.view.cframe * CFrame.Angles(0, 0, math.rad(8))
		end,
		["the camera is upside down"] = function(session: any)
			session.view.cframe = session.view.cframe * CFrame.Angles(0, 0, math.pi)
		end,
		["the camera looks up from under the baseplate"] = function(session: any)
			local subject = (inspect(session.place) :: any).subject
			-- Straight below the rig, far enough to frame it, looking up through the baseplate.
			local below = subject.centre + Vector3.new(0, -subject.radius * 2.6, 0)
			session.view.cframe = CFrame.new(below) * CFrame.Angles(math.rad(90), 0, 0)
		end,
		["the field of view is extreme"] = function(session: any)
			session.view.fieldOfView = 110
		end,
		["the viewport is tiny"] = function(session: any)
			session.view.width, session.view.height = 40, 30
		end,
		["the place holds something else"] = function(session: any)
			local part = Instance.new("Part")
			part.Name = "Private"
			part.Parent = session.place.root
		end,
		["the place has a sky of its own"] = function(session: any)
			Instance.new("Sky").Parent = session.place.lighting
		end,
		["the rig is a visible one"] = function(session: any)
			session.place.parts.Head.Transparency = 0
		end,
		["a preview is already in progress"] = function(session: any)
			startPreview(session)
		end,
	} :: { [string]: (session: any) -> () }
do
	case(`no approval is given when {label}`, function()
		local session = newSession()
		alter(session)
		local ok, why = arm(session)
		check("no approval", ok == false, why)
		check("a reason is given", type(why) == "string" and why ~= "")
		check("screenshots stay off", Approval.refusal(session.state, observe(session), false) ~= nil)
	end)
end

-- Each of these happens after approval, while a screenshot is pending. The screenshot
-- must be refused, and the approval must stay withdrawn even if the change is undone.
for label, change in
	{
		["the camera is moved"] = function(session: any)
			local original = session.view.cframe
			session.view.cframe = original + Vector3.new(0.5, 0, 0)
			return function()
				session.view.cframe = original
			end
		end,
		["the camera is turned"] = function(session: any)
			local original = session.view.cframe
			session.view.cframe = original * CFrame.Angles(0, math.rad(2), 0)
			return function()
				session.view.cframe = original
			end
		end,
		["the camera is rolled slightly"] = function(session: any)
			local original = session.view.cframe
			session.view.cframe = original * CFrame.Angles(0, 0, math.rad(0.5))
			return function()
				session.view.cframe = original
			end
		end,
		["the field of view changes"] = function(session: any)
			session.view.fieldOfView = 60
			return function()
				session.view.fieldOfView = 70
			end
		end,
		["the viewport is resized"] = function(session: any)
			session.view.width = 1600
			return function()
				session.view.width = 1920
			end
		end,
		["the camera is switched for another"] = function(session: any)
			local original = session.camera
			session.camera = Instance.new("Camera")
			return function()
				session.camera = original
			end
		end,
		["the camera is replaced by another in the same position"] = function(session: any)
			-- Everything about the view and the scene is identical; only the instance differs.
			local original = session.camera
			local replacement = Instance.new("Camera")
			original.Parent = nil
			replacement.Parent = session.place.root
			session.camera = replacement
			return function()
				replacement.Parent = nil
				original.Parent = session.place.root
				session.camera = original
			end
		end,
		["a script tab becomes active"] = function(session: any)
			session.viewportActive = false
			return function()
				session.viewportActive = true
			end
		end,
		["switches stop being watched"] = function(session: any)
			session.watching = false
			return function()
				session.watching = true
			end
		end,
		["something is selected"] = function(session: any)
			session.selectionEmpty = false
			return function()
				session.selectionEmpty = true
			end
		end,
		["the marker is replaced"] = function(session: any)
			local original = session.foundMarker
			local copy = Instance.new("StringValue")
			copy.Name = original.Name
			copy.Value = original.Value
			session.foundMarker = copy
			return function()
				session.foundMarker = original
			end
		end,
		["the marker's id is rewritten"] = function(session: any)
			local original = session.marker.Value
			session.marker.Value = FixtureGuard.MARKER_PREFIX .. OTHER_ID
			return function()
				session.marker.Value = original
			end
		end,
		["the place is published"] = function(session: any)
			session.placeId = 99
			return function()
				session.placeId = 0
			end
		end,
		["a playtest starts"] = function(session: any)
			session.isEdit = false
			return function()
				session.isEdit = true
			end
		end,
		["something is added to the place"] = function(session: any)
			local part = Instance.new("Part")
			part.Name = "Intruder"
			part.Parent = session.place.root
			return function()
				part.Parent = nil
			end
		end,
		["a sky is added"] = function(session: any)
			local sky = Instance.new("Sky")
			sky.Parent = session.place.lighting
			return function()
				sky.Parent = nil
			end
		end,
		["something is attached to the camera"] = function(session: any)
			local part = Instance.new("Part")
			part.Parent = session.camera
			return function()
				part.Parent = nil
			end
		end,
		["a rig part is moved"] = function(session: any)
			local head = session.place.parts.Head
			local original = head.CFrame
			head.CFrame = original + Vector3.new(0, 0.25, 0)
			return function()
				head.CFrame = original
			end
		end,
		["the baseplate's look changes"] = function(session: any)
			session.place.baseplate.Reflectance = 0.4
			return function()
				session.place.baseplate.Reflectance = 0
			end
		end,
		["the rig is made visible"] = function(session: any)
			session.place.parts.UpperTorso.Transparency = 0
			return function()
				session.place.parts.UpperTorso.Transparency = 1
			end
		end,
		["the rig is swapped for an identical one"] = function(session: any)
			local original = session.place.rig
			local twin = original:Clone()
			original.Parent = nil
			twin.Parent = session.place.root
			session.subject.model = twin
			return function()
				twin.Parent = nil
				original.Parent = session.place.root
				session.subject.model = original
			end
		end,
		["terrain appears"] = function(session: any)
			session.terrainCells = 3
			return function()
				session.terrainCells = 0
			end
		end,
		["the preview is of a different model"] = function(session: any)
			local original = session.subject.model
			session.subject.model = Instance.new("Model")
			return function()
				session.subject.model = original
			end
		end,
		["there is no preview at all"] = function(session: any)
			local subject = session.subject
			subject.clone.Parent = nil
			session.subject = nil
			return function()
				subject.clone.Parent = session.place.root
				session.subject = subject
			end
		end,
		["the pose throws a limb out of the picture"] = function(session: any)
			local hand = session.subject.clone.RightHand
			local original = hand.CFrame
			hand.CFrame = original + Vector3.new(300, 0, 0)
			return function()
				hand.CFrame = original
			end
		end,
		["the pose puts a limb across the edge of the picture"] = function(session: any)
			local head = session.subject.clone.Head
			local original = head.CFrame
			local subject = (inspect(session.place, session.subject.clone) :: any).subject
			head.CFrame = CFrame.new(subject.centre + Vector3.new(0, subject.radius * 1.55, 0))
			return function()
				head.CFrame = original
			end
		end,
		["the pose sinks a limb into the baseplate"] = function(session: any)
			local foot = session.subject.clone.LeftFoot
			local original = foot.CFrame
			foot.CFrame = CFrame.new(0, 0.1, 0)
			return function()
				foot.CFrame = original
			end
		end,
		["something is added beneath the preview's copy"] = function(session: any)
			local sign = Instance.new("Part")
			sign.Name = "Sign"
			sign.Parent = session.subject.clone
			return function()
				sign.Parent = nil
			end
		end,
		["the preview's copy is hidden again"] = function(session: any)
			session.subject.clone.Head.Transparency = 1
			return function()
				session.subject.clone.Head.Transparency = 0
			end
		end,
	} :: { [string]: (session: any) -> () -> () }
do
	case(`a pending screenshot is refused and approval withdrawn when {label}`, function()
		local session = approved(newSession())
		startPreview(session)
		check("allowed before the change", Approval.refusal(session.state, observe(session), true) == nil)
		local undo = change(session)
		local reason = Approval.refusal(session.state, observe(session), true)
		check("refused once it has changed", reason ~= nil)
		check(
			"a reason is given",
			type(reason) == "string" and string.find(reason, "screenshots are off", 1, true) ~= nil,
			reason
		)
		undo()
		local after = Approval.refusal(session.state, observe(session), true)
		check("still refused after the change is undone", after ~= nil)
		check(
			"the refusal says how to re-approve",
			after ~= nil and string.find(after, "approve again", 1, true) ~= nil,
			after
		)
		check("screenshots are reported as off", Approval.refusal(session.state, observe(session), false) ~= nil)
	end)
end

case("asking whether screenshots are possible does not by itself withdraw approval", function()
	local session = approved(newSession())
	session.selectionEmpty = false
	check("reported as not possible right now", Approval.refusal(session.state, observe(session), false) ~= nil)
	session.selectionEmpty = true
	check("possible again once the cause is gone", Approval.refusal(session.state, observe(session), false) == nil)
	startPreview(session)
	check("and a screenshot is still allowed", Approval.refusal(session.state, observe(session), true) == nil)
end)

case("a withdrawn approval comes back only when a person approves again", function()
	local session = approved(newSession())
	Approval.disarm(session.state, "the preview was cancelled")
	local reason = Approval.refusal(session.state, observe(session), false)
	check(
		"refused after withdrawal",
		reason ~= nil and string.find(reason, "the preview was cancelled", 1, true) ~= nil,
		reason
	)
	check("what was typed is forgotten", session.state.selected == nil)
	startPreview(session)
	check("refused for a capture", Approval.refusal(session.state, observe(session), true) ~= nil)
	check("approving during the preview is refused", (arm(session)) == false)
	endPreview(session)
	session.typed = nil
	check("approving without typing the id again is refused", (arm(session)) == false)
	session.typed = FIXTURE_ID
	check("typing the id and approving again works", (arm(session)) == true)
	check("screenshots are possible again", Approval.refusal(session.state, observe(session), false) == nil)
end)

case("a failed attempt to approve cancels an approval that stood", function()
	local session = approved(newSession())
	session.typed = OTHER_ID
	check("the wrong id is refused", (arm(session)) == false)
	session.typed = FIXTURE_ID
	check("and the earlier approval no longer stands", Approval.refusal(session.state, observe(session), false) ~= nil)
end)

case("approving again records the camera as it is then, not as it was", function()
	local session = approved(newSession())
	session.view = viewOf((inspect(session.place) :: any).subject, 1.6)
	startPreview(session)
	check(
		"the moved camera is refused under the old approval",
		Approval.refusal(session.state, observe(session), true) ~= nil
	)
	endPreview(session)
	check("a person approves the new framing", (arm(session)) == true)
	startPreview(session)
	check("the new framing is now the approved one", Approval.refusal(session.state, observe(session), true) == nil)
end)

finish()
