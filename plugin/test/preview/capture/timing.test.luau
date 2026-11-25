--!strict
-- A screenshot against its deadline and its guard: no image that is late, failed or no longer allowed.
-- Run with: lune run plugin/test/preview/capture/timing.test.luau

local Kit = require("./kit")

local allow = Kit.allow
local Capture = Kit.Capture
local newStudio = Kit.newStudio
local png = Kit.png
local refused = Kit.refused

local check, case, finish = Kit.suite("capture timing")
case("the guard is asked before the screenshot is requested", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	local asked = 0
	refused(
		Capture.capture(768, nil, function()
			asked += 1
			return "the preview has ended"
		end),
		"the preview has ended"
	)
	check("the guard was asked", asked == 1, asked)
	check("no screenshot was requested", #studio.starts == 0)
end)

case("an image that arrives after the guard has changed its answer is not returned", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	local stale = false
	studio.onStart = function()
		stale = true
	end
	refused(
		Capture.capture(768, nil, function()
			return if stale then "the clip changed while the screenshot was being taken" else nil
		end),
		"the clip changed"
	)
	check("the screenshot had been requested", #studio.starts == 1)
end)

case("a capture that Studio reports as failed returns no image", function()
	local studio = newStudio()
	studio.bufferError = true
	studio.data = png(768, 432)
	refused(Capture.capture(768, nil, allow), "forced buffer failure")
	check("the buffer was not read", studio.reads == 0)
end)

case("a capture whose image never arrives is given up on", function()
	local studio = newStudio()
	studio.readyAfter = math.huge
	studio.data = png(768, 432)
	refused(Capture.capture(768, nil, allow), "did not finish in time")
	check("it waited no longer than the limit", studio.now <= Capture.BUFFER_TIMEOUT + 1, studio.now)
	check("the buffer was not read", studio.reads == 0)
end)

case("an image that is ready only after the deadline is not taken", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	studio.readyAfter = 1
	-- One wait carries the clock past the deadline; the very next poll says "ready".
	studio.waitStep = Capture.BUFFER_TIMEOUT + 1
	refused(Capture.capture(768, nil, allow), "did not finish in time")
	check("the late image was not read", studio.reads == 0, studio.reads)
end)

case("a deadline that passes during the last checks still means no image", function()
	local studio = newStudio()
	studio.data = png(768, 432)
	local asked = 0
	refused(
		Capture.capture(768, nil, function()
			asked += 1
			if asked == 2 then
				-- The image is in hand and valid; the final check itself runs out the clock.
				studio.now += Capture.BUFFER_TIMEOUT + 1
			end
			return nil
		end),
		"did not finish in time"
	)
	check("the image had been read", studio.reads == 1, studio.reads)
end)

finish()
