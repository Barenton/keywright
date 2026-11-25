--!strict
-- Screenshots of a preview: off unless the gate allows, and never an image that is late, unapproved or cancelled.
-- Run with: lune run plugin/test/preview/preview/screenshot.test.luau

local Kit = require("./kit")

local arm = Kit.arm
local buildRig = Kit.buildRig
local Capture = Kit.Capture
local checkUntouched = Kit.checkUntouched
local expectError = Kit.expectError
local newWorld = Kit.newWorld
local Preview = Kit.Preview
local request = Kit.request
local SHIPPED_REFUSAL = Kit.SHIPPED_REFUSAL
local shot = Kit.shot
local snapshot = Kit.snapshot

local check, case, finish = Kit.suite("preview screenshot")
case("screenshots stay off unless an entry point opens the gate", function()
	check(
		"the module ships with the capture gate closed",
		SHIPPED_REFUSAL == Preview.CAPTURE_GATE_CLOSED,
		SHIPPED_REFUSAL
	)
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local called = false
	local shown = false
	world.onStep = function(model: any)
		for _, descendant in model:GetDescendants() do
			shown = shown or (descendant:IsA("BasePart") and descendant.Transparency == 0)
		end
	end
	local result = Preview.run(request(rig, {
		capture = function()
			called = true
			return { status = "ok" }
		end,
	}))
	check("the capture function was not called", not called)
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check("the reason is stated", result.capture.reason == Preview.CAPTURE_GATE_CLOSED, result.capture.reason)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	check("the clone was never shown", not shown)
	checkUntouched(world, rig, before)
end)

for label, rule in
	{
		["refuses"] = function(): string?
			return "not armed"
		end,
		["fails"] = function(): string?
			error("forced gate failure")
		end,
		["answers with something that is not a reason"] = function(): any
			return false
		end,
	} :: { [string]: () -> any }
do
	case(`a gate that {label} keeps screenshots off`, function()
		local world = newWorld()
		local rig = buildRig(world)
		local before = snapshot(rig.model)
		Preview.setCaptureGate(rule)
		local called = false
		local result = Preview.run(request(rig, {
			capture = function()
				called = true
				return { status = "ok" }
			end,
		}))
		check("the capture function was not called", not called)
		check("the capture is reported unavailable", result.capture.status == "unavailable")
		check("a reason is given", type(result.capture.reason) == "string" and result.capture.reason ~= "")
		checkUntouched(world, rig, before)
	end)
end

case("a successful screenshot shows the clone where the rig stands and moves nothing", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local seen: any = {}
	local result = Preview.run(shot(world, rig, function(guard)
		local clone = rig.place:FindFirstChild(Preview.CLONE_NAME)
		seen.clone = clone ~= nil
		seen.visible, seen.inert = 0, 0
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("BasePart") then
				if descendant.Transparency == 0 then
					seen.visible += 1
				end
				if
					not descendant.CanCollide
					and not descendant.CanQuery
					and not descendant.CanTouch
					and descendant.Locked
				then
					seen.inert += 1
				end
			end
		end
		seen.rootHidden = clone.HumanoidRootPart.Transparency == 1
		seen.samePlace = clone.HumanoidRootPart.CFrame == rig.model.HumanoidRootPart.CFrame
		seen.subject = Preview.subject()
		seen.guard = guard()
		return { status = "ok", width = 4, height = 3 }
	end))
	check("the clone existed during the capture", seen.clone)
	check("the clone's body was visible", seen.visible == 3, seen.visible)
	check("the clone's root part stayed hidden", seen.rootHidden)
	check("the clone could not be hit, touched, queried or selected", seen.inert == 4, seen.inert)
	check("the clone stood exactly where the rig stands", seen.samePlace)
	check(
		"the screenshot's subject is the rig being previewed",
		seen.subject ~= nil and seen.subject.model == rig.model
	)
	check(
		"the subject names the clone",
		seen.subject ~= nil and seen.subject.clone ~= nil and seen.subject.clone ~= rig.model
	)
	check("the guard allowed the screenshot", seen.guard == nil, seen.guard)
	check("the gate was asked as for a capture", table.find(world.gateCalls, true) ~= nil)
	check("the capture result is passed through", result.capture.status == "ok" and result.capture.width == 4)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	check("no screenshot is in progress afterwards", Preview.subject() == nil)
	check("no approval was withdrawn", #world.revoked == 0, table.concat(world.revoked, "; "))
	checkUntouched(world, rig, before)
end)

case("a preview without a screenshot has no screenshot subject", function()
	local world = newWorld()
	local rig = buildRig(world)
	arm(world)
	local steps, withSubject = 0, 0
	world.onStep = function()
		steps += 1
		if Preview.subject() ~= nil then
			withSubject += 1
		end
	end
	Preview.run(request(rig))
	check("the clip was sampled", steps > 0, steps)
	check("no subject at any point while sampling", withSubject == 0, withSubject)
end)

case("a failing capture leaves no clone", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(shot(world, rig, function()
		error("forced capture failure")
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check("the reason carries the failure", string.find(result.capture.reason, "forced capture failure") ~= nil)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	checkUntouched(world, rig, before)
end)

case("a capture that returns nothing usable is reported unavailable", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(shot(world, rig, function()
		return nil
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	checkUntouched(world, rig, before)
end)

case("a capture that never returns is abandoned, and its late result is refused", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local resumed = false
	local lateGuard: any = nil
	local result = Preview.run(shot(world, rig, function(guard)
		lateGuard = guard
		coroutine.yield()
		resumed = true
		return { status = "ok" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check("the reason names the budget", string.find(result.capture.reason, "time budget") ~= nil)
	check("the capture budget elapsed", world.now >= Preview.CAPTURE_BUDGET, world.now)
	check("the abandoned capture never continued", not resumed)
	check("the abandoned capture may no longer take an image", lateGuard() == "the preview has ended", lateGuard())
	check(
		"the approval it ran under was withdrawn",
		table.find(world.revoked, "the capture exceeded its time budget") ~= nil,
		table.concat(world.revoked, "; ")
	)
	checkUntouched(world, rig, before)

	-- A later preview has its own clone; the old capture still may not shoot.
	local duringNext: any = "unset"
	local nextResult = Preview.run(shot(world, rig, function()
		duringNext = lateGuard()
		return { status = "ok", width = 2, height = 2 }
	end))
	check("the old capture is refused during a later preview", duringNext == "the preview has ended", duringNext)
	check("the later preview gets its own image", nextResult.capture.status == "ok")
	checkUntouched(world, rig, before)
end)

case("a capture that runs out of time leaves no permission request waiting", function()
	local world = newWorld()
	local rig = buildRig(world)
	local abandons = 0
	local original = Capture.abandon
	Capture.abandon = function()
		abandons += 1
	end
	local ok, problem = pcall(function()
		Preview.run(shot(world, rig, function()
			coroutine.yield()
			return { status = "ok" }
		end))
		check("the waiting permission request was given up on", abandons == 1, abandons)
		Preview.run(shot(world, rig, function()
			return { status = "ok", width = 2, height = 2 }
		end))
		check("a capture that finishes gives up on nothing", abandons == 1, abandons)
		-- Withdrawing approval, switching tab or camera, and unloading all cancel.
		Preview.cancel("approval was withdrawn in the panel")
		check("cancelling gives up on a waiting permission request at once", abandons == 2, abandons)
		Preview.sweep()
		check("so does an unload", abandons == 3, abandons)
	end)
	Capture.abandon = original
	check("the case ran", ok, problem)
end)

case("a rig the gate has not approved is never shown, even for a moment", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local asked: { any } = {}
	-- Screenshots are possible in general, but not of this rig.
	Preview.setCaptureGate(function(capturing: boolean): string?
		local subject = Preview.subject()
		table.insert(
			asked,
			{ capturing = capturing, model = subject and subject.model, clone = subject and subject.clone }
		)
		return if capturing then "screenshots are off: the preview is not of the probe's synthetic rig" else nil
	end)
	local shown, called = false, false
	world.onStep = function(model: any)
		for _, descendant in model:GetDescendants() do
			shown = shown or (descendant:IsA("BasePart") and descendant.Transparency == 0)
		end
	end
	local result = Preview.run(request(rig, {
		capture = function()
			called = true
			return { status = "ok", png = "image" }
		end,
	}))
	check(
		"the gate was asked before any clone existed",
		asked[1] ~= nil and asked[1].capturing == true and asked[1].clone == nil
	)
	check("the gate was told which rig", asked[1] ~= nil and asked[1].model == rig.model)
	check("the clone was never shown", not shown)
	check("the capture function was not called", not called)
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check(
		"the reason is the gate's",
		string.find(result.capture.reason, "not of the probe's synthetic rig") ~= nil,
		result.capture.reason
	)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	checkUntouched(world, rig, before)
end)

case("an image is not handed on if approval is lost while the preview cleans up", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local taken = false
	world.onStep = function()
		-- The sampler's last step happens during cleanup, after the image is in hand.
		if taken then
			world.gateRefusal = "screenshots are off: the active tab changed"
		end
	end
	local result = Preview.run(shot(world, rig, function()
		taken = true
		return { status = "ok", width = 4, height = 3, png = "image" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
	check("no image is passed on", result.capture.png == nil)
	check(
		"the reason is the lost approval",
		string.find(result.capture.reason, "the active tab changed") ~= nil,
		result.capture.reason
	)
	check("the sample is still returned", result.transforms.Head.X == 0.5)
	checkUntouched(world, rig, before)
end)

case("a capture that finishes only after its deadline is not a success", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(shot(world, rig, function()
		-- Ready, but late: the image exists and must still not be passed on.
		world.now += Preview.CAPTURE_BUDGET + 1
		return { status = "ok", width = 4, height = 3, png = "image" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
	check("no image is passed on", result.capture.png == nil)
	check(
		"the reason names the budget",
		string.find(result.capture.reason, "time budget") ~= nil,
		result.capture.reason
	)
	checkUntouched(world, rig, before)
end)

-- The gate stands for the approval of a scene and camera. When the scene, the camera or
-- the active tab changes, the approval is withdrawn and the gate answers with the reason.
for label, disturb in
	{
		["the clip changes"] = function(_world: any, state: any)
			state.current = false
		end,
		["the scene changes"] = function(world: any)
			world.gateRefusal = "screenshots are off: the scene changed after it was approved"
		end,
		["the camera is moved or switched"] = function(world: any)
			world.gateRefusal = "screenshots are off: the camera or the viewport changed after it was approved"
		end,
		["the fixture is unarmed"] = function(world: any)
			world.gateRefusal = "screenshots are off: the fixture was unarmed"
		end,
		["the gate is closed outright"] = function()
			Preview.setCaptureGate(nil)
		end,
		["the clone is removed"] = function(_world: any, _state: any, rig: any)
			rig.place:FindFirstChild(Preview.CLONE_NAME).Parent = nil
		end,
	} :: { [string]: (world: any, state: any, rig: any) -> () }
do
	case(`an image taken while {label} is not returned`, function()
		local world = newWorld()
		local rig = buildRig(world)
		local before = snapshot(rig.model)
		local state = { current = true }
		local result = Preview.run(shot(world, rig, function()
			disturb(world, state, rig)
			return { status = "ok", width = 4, height = 3, png = "image" }
		end, {
			current = function()
				return state.current
			end,
		}))
		check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
		check("no image is passed on", result.capture.png == nil)
		check("a reason is given", type(result.capture.reason) == "string" and result.capture.reason ~= "")
		check("the sample is still returned", result.transforms.Head.X == 0.5)
		checkUntouched(world, rig, before)
	end)

	case(`no image is requested once {label} before the screenshot`, function()
		local world = newWorld()
		local rig = buildRig(world)
		local before = snapshot(rig.model)
		local state = { current = true }
		local called = false
		-- The change happens while the clone is being drawn, before the capture is called.
		world.onWait = function()
			if Preview.subject() ~= nil and not called then
				disturb(world, state, rig)
			end
		end
		local result = Preview.run(shot(world, rig, function()
			called = true
			return { status = "ok", png = "image" }
		end, {
			current = function()
				return state.current
			end,
		}))
		check("the capture function was not called", not called)
		check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
		checkUntouched(world, rig, before)
	end)
end

case("cancelling abandons the screenshot and withdraws the approval", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local resumed = false
	local result = Preview.run(shot(world, rig, function()
		Preview.cancel("agent access was turned off")
		coroutine.yield()
		resumed = true
		return { status = "ok" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable")
	check(
		"the reason is the cancellation",
		result.capture.reason == "agent access was turned off",
		result.capture.reason
	)
	check("it did not wait out the capture budget", world.now < 5, world.now)
	check("the abandoned capture never continued", not resumed)
	check("the approval was withdrawn", table.find(world.revoked, "agent access was turned off") ~= nil)
	checkUntouched(world, rig, before)
end)

case("an image that arrives after a cancellation is not returned", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local result = Preview.run(shot(world, rig, function()
		Preview.cancel("agent access was turned off")
		return { status = "ok", png = "image" }
	end))
	check("the capture is reported unavailable", result.capture.status == "unavailable", result.capture.status)
	check("no image is passed on", result.capture.png == nil)
	check(
		"the reason is the cancellation",
		result.capture.reason == "agent access was turned off",
		result.capture.reason
	)
	checkUntouched(world, rig, before)
	check("a later preview is not affected", Preview.run(request(rig)).transforms.Head.X == 0.5)
end)

case("a preview interrupted mid-screenshot is undone by one sweep, as on unload", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local frozen = false
	world.onWait = function()
		-- Stop the preview dead while its clone is shown, as an unload would.
		if Preview.subject() ~= nil and not frozen then
			frozen = true
			coroutine.yield()
		end
	end
	local thread = coroutine.create(function()
		return pcall(
			Preview.run,
			shot(world, rig, function()
				return { status = "ok", png = "image" }
			end)
		)
	end)
	coroutine.resume(thread)
	check("the preview stopped with its clone shown", frozen and rig.place:FindFirstChild(Preview.CLONE_NAME) ~= nil)

	local problems = Preview.sweep()
	check("the sweep reports no problem", #problems == 0, table.concat(problems, "; "))
	check("the clone is gone at once", rig.place:FindFirstChild(Preview.CLONE_NAME) == nil)
	check("nothing is owned any more", Preview.ownedCount() == 0)
	check("the approval was withdrawn", table.find(world.revoked, "the preview was interrupted") ~= nil)
	check("the original rig is unchanged", snapshot(rig.model) == before)

	-- Were the stopped preview ever to continue, it takes no image and changes nothing more.
	world.onWait = nil
	local _, finished, outcome = coroutine.resume(thread)
	local image = finished and type(outcome) == "table" and outcome.capture and outcome.capture.status == "ok"
	check("the interrupted preview returns no image", not image)
	check("the original rig is still unchanged", snapshot(rig.model) == before)
	check("previews work again", Preview.run(request(rig)).transforms.Head.X == 0.5)
end)

case("a second preview cannot start, or take an image, while a screenshot is in progress", function()
	local world = newWorld()
	local rig = buildRig(world)
	local before = snapshot(rig.model)
	local inner: any = nil
	local innerShot = false
	local budget = Preview.SAMPLE_BUDGET
	local result = Preview.run(shot(world, rig, function()
		Preview.SAMPLE_BUDGET = 1
		inner = expectError(function()
			return Preview.run(request(rig, {
				capture = function()
					innerShot = true
					return { status = "ok", png = "other image" }
				end,
			}))
		end)
		Preview.SAMPLE_BUDGET = budget
		return { status = "ok", width = 4, height = 3, png = "image" }
	end))
	Preview.SAMPLE_BUDGET = budget
	check("the second preview was refused", inner ~= nil and inner.code == "PREVIEW_UNAVAILABLE", inner and inner.code)
	check("the second preview took no image", not innerShot)
	check("the first preview kept its own image", result.capture.status == "ok" and result.capture.png == "image")
	checkUntouched(world, rig, before)
end)

finish()
