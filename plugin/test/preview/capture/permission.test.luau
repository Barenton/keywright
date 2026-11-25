--!strict
-- Studio's permission prompt for screenshots: given up on in time, and no worker left behind.
-- Run with: lune run plugin/test/preview/capture/permission.test.luau

local Kit = require("./kit")

local allow = Kit.allow
local Capture = Kit.Capture
local newStudio = Kit.newStudio
local png = Kit.png
local refused = Kit.refused

local check, case, finish = Kit.suite("capture permission")
case("an unanswered permission prompt is given up on and leaves no worker behind", function()
	local studio = newStudio()
	studio.permission = "never"
	studio.data = png(768, 432)
	refused(Capture.capture(768, nil, allow), "not answered in time")
	check("it waited no longer than the limit", studio.now <= Capture.PERMISSION_TIMEOUT + 1, studio.now)
	check("it did wait for the limit", studio.now >= Capture.PERMISSION_TIMEOUT, studio.now)
	check("no screenshot was requested", #studio.starts == 0)
	check("the waiting worker was cancelled", #studio.cancelled == 1 and studio.cancelled[1] == studio.workers[1])
	check(
		"the worker is no longer running",
		coroutine.status(studio.workers[1]) == "dead",
		coroutine.status(studio.workers[1])
	)

	-- The prompt may still be on screen, so Studio is not asked again in this session.
	local before = studio.now
	refused(Capture.capture(768, nil, allow), "abandoned")
	check("Studio was not asked again", studio.permissionRequests == 1, studio.permissionRequests)
	check("no second worker was started", #studio.workers == 1, #studio.workers)
	check("the second request did not wait", studio.now == before, studio.now - before)
	local granted, reason = Capture.requestPermission()
	check("asking directly is refused too", granted == false and reason == Capture.PERMISSION_ABANDONED, reason)
	check("no screenshot was requested", #studio.starts == 0)
end)

case("a worker that cannot be cancelled still counts for nothing when it answers", function()
	local studio = newStudio()
	studio.permission = "never"
	studio.cancelWorks = false
	studio.data = png(768, 432)
	refused(Capture.capture(768, nil, allow), "not answered in time")
	check("cancelling was attempted", #studio.cancelled == 1)
	check("the worker survived", coroutine.status(studio.workers[1]) == "suspended")
	-- The person answers "allow" long afterwards.
	studio.permission = "grant"
	coroutine.resume(studio.workers[1])
	check("the late answer requested no screenshot", #studio.starts == 0, #studio.starts)
	refused(Capture.capture(768, nil, allow), "abandoned")
	check("Studio was not asked again", studio.permissionRequests == 1, studio.permissionRequests)
end)

case("a permission answer that comes after the deadline is not accepted", function()
	local studio = newStudio()
	studio.permission = "never"
	studio.data = png(768, 432)
	studio.onWait = function()
		-- Answered "allow", but only once the time allowed has passed.
		if studio.now > Capture.PERMISSION_TIMEOUT and coroutine.status(studio.workers[1]) == "suspended" then
			studio.permission = "grant"
			coroutine.resume(studio.workers[1])
		end
	end
	studio.waitStep = Capture.PERMISSION_TIMEOUT + 1
	refused(Capture.capture(768, nil, allow), "not answered in time")
	check("no screenshot was requested", #studio.starts == 0, #studio.starts)
	check("nothing was left waiting to cancel", #studio.cancelled == 0, #studio.cancelled)

	-- Studio did answer, so nothing is abandoned: the next screenshot simply asks again.
	studio.onWait = nil
	studio.waitStep = 1 / 60
	local result = Capture.capture(768, nil, allow)
	check("the next screenshot asks again", studio.permissionRequests == 2, studio.permissionRequests)
	check("and then succeeds", result.status == "ok", result.reason)
end)

case("time Studio takes before it first waits counts against the permission deadline", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	-- The call returns "allow" without ever waiting, but only after too long.
	studio.permissionDelay = Capture.PERMISSION_TIMEOUT + 1
	refused(Capture.capture(768, nil, allow), "not answered in time")
	check("no screenshot was requested", #studio.starts == 0, #studio.starts)
end)

case("a screenshot given up on from outside leaves no permission worker running", function()
	local studio = newStudio()
	studio.permission = "never"
	studio.data = png(768, 432)
	local abandoned = false
	studio.onWait = function()
		-- As a preview does when it is cancelled or runs out of time.
		if not abandoned then
			abandoned = true
			Capture.abandon()
		end
	end
	refused(Capture.capture(768, nil, allow), "not answered in time")
	check("the worker was cancelled as soon as it was given up on", #studio.cancelled == 1)
	check("the worker is no longer running", coroutine.status(studio.workers[1]) == "dead")
	studio.onWait = nil
	refused(Capture.capture(768, nil, allow), "abandoned")
	check("giving up again does nothing", pcall(Capture.abandon) and #studio.cancelled == 1, #studio.cancelled)
	check("Studio was asked only once", studio.permissionRequests == 1, studio.permissionRequests)
end)

case("giving up when nothing is waiting changes nothing", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	Capture.abandon()
	local result = Capture.capture(768, nil, allow)
	check("a screenshot still works", result.status == "ok", result.reason)
	check("nothing was cancelled", #studio.cancelled == 0)
end)

finish()
