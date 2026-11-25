--!strict
-- The gate in front of screenshots: closed means nothing is asked of Studio, and closing stops what is under way.
-- Run with: lune run plugin/test/preview/capture/gate.test.luau

local Kit = require("./kit")

local allow = Kit.allow
local build = Kit.build
local Capture = Kit.Capture
local newStudio = Kit.newStudio
local png = Kit.png
local refused = Kit.refused

local check, case, finish = Kit.suite("capture gate")
-- An approval is good for attempts that succeed. Once Studio has been asked for anything
-- and the attempt fails, the approval is withdrawn, so the next attempt needs a person.
for label, configure in
	{
		["permission is not answered in time"] = function(studio: any)
			studio.permission = "never"
			return true
		end,
		["permission is denied"] = function(studio: any)
			studio.permission = "deny"
			return true
		end,
		["the image does not arrive in time"] = function(studio: any)
			studio.readyAfter = math.huge
			return true
		end,
		["the image is ready only after the deadline"] = function(studio: any)
			studio.readyAfter = 1
			studio.waitStep = Capture.BUFFER_TIMEOUT + 1
			return true
		end,
		["Studio reports the capture failed"] = function(studio: any)
			studio.bufferError = true
			return true
		end,
		["the image is not what was asked for"] = function(studio: any)
			studio.data = png(100, 100)
			return true
		end,
		["the image is not a PNG"] = function(studio: any)
			studio.data = buffer.create(2048)
			return true
		end,
		-- Nothing was asked of Studio in these, so there is nothing to withdraw.
		["the requested size is not valid"] = function(studio: any)
			studio.badSize = true
			return false
		end,
		["the caller has no guard"] = function(studio: any)
			studio.noGuard = true
			return false
		end,
	} :: { [string]: (studio: any) -> boolean }
do
	case(`approval after a failed attempt: {label}`, function()
		local studio = newStudio()
		studio.data = png(768, 432)
		local expectWithdrawn = configure(studio)
		local result = Capture.capture(
			if (studio :: any).badSize then -1 else 768,
			nil,
			if (studio :: any).noGuard then nil else allow
		)
		check("no image", result.status == "unavailable" and result.png == nil, result.status)
		if expectWithdrawn then
			check("the approval was withdrawn", #studio.revoked == 1, #studio.revoked)
			check("with the reason the attempt failed", studio.revoked[1] == result.reason, studio.revoked[1])
		else
			check("the approval stands", #studio.revoked == 0, table.concat(studio.revoked, "; "))
		end
	end)
end

for label, configure in
	{
		["StudioCaptureService is missing"] = function(studio: any)
			studio.hasService = false
			return "not available"
		end,
		["permission is denied"] = function(studio: any)
			studio.permission = "deny"
			return "denied"
		end,
		["asking for permission fails"] = function(studio: any)
			studio.permission = "throw"
			return "forced permission failure"
		end,
		["Studio says it cannot capture now"] = function(studio: any)
			studio.canCapture = false
			return "cannot be captured now"
		end,
		["the availability check fails"] = function(studio: any)
			studio.canCapture = "throw"
			return "forced availability failure"
		end,
		["there is no camera"] = function(studio: any)
			studio.viewportWidth = nil
			return "no current camera"
		end,
		["the viewport has no size"] = function(studio: any)
			studio.viewportHeight = 0
			return "no size"
		end,
	} :: { [string]: (studio: any) -> string }
do
	case(`no screenshot is requested when {label}`, function()
		local studio = newStudio()
		studio.data = png(768, 432)
		local expected = configure(studio)
		refused(Capture.capture(768, nil, allow), expected)
		check("no screenshot was requested", #studio.starts == 0, #studio.starts)
	end)
end

for label, configure in
	{
		["requesting the screenshot fails"] = function(studio: any)
			studio.failStart = true
			return "forced start failure"
		end,
		["reading the image fails"] = function(studio: any)
			studio.failRead = true
			return "forced read failure"
		end,
		["no image data comes back"] = function(studio: any)
			studio.data = nil
			return "no image data"
		end,
		["the image is over the byte limit"] = function(studio: any)
			studio.data = png(768, 432, Capture.MAX_BYTES + 1)
			return "byte limit"
		end,
		["the data is not a PNG"] = function(studio: any)
			studio.data = buffer.create(4096)
			return "not a PNG"
		end,
		["the PNG is cut short"] = function(studio: any)
			local whole = png(768, 432, 4096)
			local cut = buffer.create(4000)
			buffer.copy(cut, 0, whole, 0, 4000)
			studio.data = cut
			return "cut short"
		end,
		["the PNG has no image data"] = function(studio: any)
			studio.data = build({ { "IHDR", 13, 768, 432 }, { "gAMA", 64 }, { "IEND", 0 } })
			return "no image data"
		end,
		["the PNG is an animation"] = function(studio: any)
			studio.data = build({ { "IHDR", 13, 768, 432 }, { "acTL", 8 }, { "IDAT", 64 }, { "IEND", 0 } })
			return "animated"
		end,
		["the PNG is wider than was asked for"] = function(studio: any)
			studio.data = png(1920, 432)
			return "that was asked for"
		end,
		["the PNG is taller than was asked for"] = function(studio: any)
			studio.data = png(768, 1080)
			return "that was asked for"
		end,
		["the PNG is smaller than was asked for"] = function(studio: any)
			studio.data = png(767, 432)
			return "that was asked for"
		end,
		["the PNG declares no size"] = function(studio: any)
			studio.data = png(0, 432)
			return "that was asked for"
		end,
	} :: { [string]: (studio: any) -> string }
do
	case(`no image is returned when {label}`, function()
		local studio = newStudio()
		studio.data = png(768, 432)
		local expected = configure(studio)
		refused(Capture.capture(768, nil, allow), expected)
	end)
end

case("with the gate closed nothing is asked of Studio", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	Capture.setGate(nil)
	check("the reason is the closed gate", Capture.refusal() == Capture.GATE_CLOSED)
	refused(Capture.capture(768, nil, allow), "screenshots of a preview are off")
	local granted, reason = Capture.requestPermission()
	check("permission is not requested", granted == false and reason == Capture.GATE_CLOSED, reason)
	local available, why = Capture.available()
	check("screenshots are reported unavailable", available == false and why == Capture.GATE_CLOSED, why)
	check("Studio was never asked for permission", studio.permissionRequests == 0, studio.permissionRequests)
	check("no screenshot was requested", #studio.starts == 0)
end)

case("a gate that refuses or fails keeps everything off", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	studio.gateRefusal = "screenshots are off: the fixture is not armed for screenshots"
	refused(Capture.capture(768, nil, allow), "not armed")
	Capture.setGate(function(): string?
		error("forced gate failure")
	end)
	refused(Capture.capture(768, nil, allow), "could not be evaluated")
	Capture.setGate(function(): any
		return false
	end)
	refused(Capture.capture(768, nil, allow), "screenshots of a preview are off")
	check("Studio was never asked for permission", studio.permissionRequests == 0, studio.permissionRequests)
	check("no screenshot was requested", #studio.starts == 0)
end)

case("the gate is told whether an image is about to be taken", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	Capture.available()
	check(
		"asking whether screenshots are possible is not a capture",
		#studio.gateCalls == 1 and studio.gateCalls[1] == false
	)
	table.clear(studio.gateCalls)
	Capture.capture(768, nil, allow)
	check("a capture asks the gate as a capture first", studio.gateCalls[1] == true)
	check("and as a capture last", studio.gateCalls[#studio.gateCalls] == true)
end)

case("a gate that closes while permission is pending stops the screenshot", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	Capture.setGate(function(): string?
		-- Open until Studio has been asked for permission, closed from then on.
		return if studio.permissionRequests > 0 then "screenshots are off: the scene changed" else nil
	end)
	refused(Capture.capture(768, nil, allow), "the scene changed")
	check("no screenshot was requested", #studio.starts == 0, #studio.starts)
end)

case("a gate that closes while the image is being made keeps it from being returned", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	studio.onStart = function()
		studio.gateRefusal = "screenshots are off: the camera or the viewport changed after it was approved"
	end
	refused(Capture.capture(768, nil, allow), "camera or the viewport changed")
	check("the screenshot had been requested", #studio.starts == 1)
end)

case("the viewport is never captured for a caller without a guard", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	refused(Capture.capture(768), "only of a preview")
	refused(Capture.capture(768, nil, "guard" :: any), "only of a preview")
	check("Studio was never asked for permission", studio.permissionRequests == 0, studio.permissionRequests)
	check("no screenshot was requested", #studio.starts == 0)
end)

case("an approval behind the gate can be withdrawn through it", function()
	local studio = newStudio()
	Capture.revoke("the preview was cancelled")
	check(
		"the reason reaches whoever opened the gate",
		studio.revoked[1] == "the preview was cancelled",
		studio.revoked[1]
	)
	Capture.setGate(nil)
	Capture.revoke("again")
	check("nothing is told once the gate is closed", #studio.revoked == 1, #studio.revoked)
	Capture.setGate(function(): string?
		return nil
	end, function()
		error("forced revoke failure")
	end)
	check("a failing listener does not raise", pcall(Capture.revoke, "third"))
end)

finish()
