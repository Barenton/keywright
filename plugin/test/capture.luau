--!strict
-- Offline tests for the screenshot rules. Run with: lune run plugin/test/capture.luau
--
-- StudioCaptureService is modelled by the fake below: a permission call, an availability
-- call, and a capture whose buffer becomes ready, fails, or never arrives. The tests show
-- that nothing is asked of Studio while the gate is closed, that every wait ends and a
-- late result is not a success, that only one permission request is ever outstanding,
-- that nothing but a complete PNG of the requested size is returned, and that the gate
-- and the caller's guard are honoured before the screenshot is requested and before it is
-- returned. What Studio's service actually does is unverified; passing here says nothing
-- about that.

local process = require("@lune/process")

local Capture = require("../src/Capture")

local failures = 0
local count = 0
local current = ""

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL [{current}] {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

local function case(name: string, run: () -> ())
	current = name
	local ok, problem = pcall(run)
	if not ok then
		count += 1
		failures += 1
		print(`FAIL [{name}] raised: {tostring(problem)}`)
	end
	Capture.setGate(nil)
end

local PNG_END = { 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 }

-- Data shaped like a PNG that declares the given size: signature and header at the
-- start, the closing chunk at the end, `length` bytes in all.
local function png(width: number, height: number, length: number?): buffer
	local size = math.max(length or 64, 45)
	local data = buffer.create(size)
	for index, byte in { 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82 } do
		buffer.writeu8(data, index - 1, byte)
	end
	local function big(offset: number, value: number)
		buffer.writeu8(data, offset, bit32.band(bit32.rshift(value, 24), 255))
		buffer.writeu8(data, offset + 1, bit32.band(bit32.rshift(value, 16), 255))
		buffer.writeu8(data, offset + 2, bit32.band(bit32.rshift(value, 8), 255))
		buffer.writeu8(data, offset + 3, bit32.band(value, 255))
	end
	big(16, width)
	big(20, height)
	for index, byte in PNG_END do
		buffer.writeu8(data, size - #PNG_END + index - 1, byte)
	end
	return data
end

local function newStudio()
	local studio = {
		now = 0,
		-- Seconds one wait takes, at least.
		waitStep = 1 / 60,
		hasService = true,
		-- "grant", "deny", "throw" or "never".
		permission = "grant",
		canCapture = true :: any,
		viewportWidth = 1920 :: number?,
		viewportHeight = 1080 :: number?,
		-- Polls of the buffer before it is ready; math.huge for never.
		readyAfter = 2,
		bufferError = false,
		failStart = false,
		failRead = false,
		data = nil :: any,
		starts = {} :: { any },
		workers = {} :: { thread },
		permissionRequests = 0,
		reads = 0,
		onStart = nil :: (() -> ())?,
		onWait = nil :: (() -> ())?,
		gateRefusal = nil :: string?,
		gateCalls = {} :: { boolean },
		revoked = {} :: { string },
	}
	-- The gate is open, as when a person has approved the scene, unless a case closes it.
	Capture.setGate(function(capturing: boolean): string?
		table.insert(studio.gateCalls, capturing)
		return studio.gateRefusal
	end, function(reason: string)
		table.insert(studio.revoked, reason)
	end)
	local service = {}
	function service:RequestScreenshotPermissionAsync()
		studio.permissionRequests += 1
		if studio.permission == "never" then
			-- The prompt stays open until the case answers it by resuming this worker.
			coroutine.yield()
		elseif studio.permission == "throw" then
			error("forced permission failure")
		end
		return studio.permission == "grant"
	end
	function service:CanCaptureScreenshot()
		if studio.canCapture == "throw" then
			error("forced availability failure")
		end
		return studio.canCapture
	end
	Capture.setBackend({
		service = function()
			return if studio.hasService then service else nil
		end,
		viewport = function()
			return studio.viewportWidth, studio.viewportHeight
		end,
		start = function(_, captureWidth: number, captureHeight: number, width: number, height: number, ...: any)
			if studio.failStart then
				error("forced start failure")
			end
			table.insert(studio.starts, {
				captureWidth = captureWidth,
				captureHeight = captureHeight,
				width = width,
				height = height,
				extra = select("#", ...),
			})
			if studio.onStart then
				studio.onStart()
			end
			return { polls = 0 }
		end,
		status = function(capture: any)
			capture.polls += 1
			if studio.bufferError then
				return "error"
			end
			return if capture.polls > studio.readyAfter then "ready" else "pending"
		end,
		errors = function()
			return { "forced buffer failure" }
		end,
		read = function()
			studio.reads += 1
			if studio.failRead then
				error("forced read failure")
			end
			return studio.data
		end,
		clock = function()
			return studio.now
		end,
		wait = function(seconds: number)
			studio.now += math.max(seconds, studio.waitStep)
			if studio.onWait then
				studio.onWait()
			end
		end,
		spawn = function(run: () -> ())
			local thread = coroutine.create(run)
			table.insert(studio.workers, thread)
			coroutine.resume(thread)
			return thread
		end,
	} :: any)
	return studio
end

-- A guard that allows the screenshot, as a preview's does while nothing has changed.
local function allow(): string?
	return nil
end

local function refused(result: any, expected: string)
	check("it is reported unavailable", result.status == "unavailable", result.status)
	check("no image is returned", result.png == nil)
	check(
		"the reason says why",
		type(result.reason) == "string" and string.find(result.reason, expected, 1, true) ~= nil,
		result.reason
	)
end

case("the size a PNG declares is read from its header", function()
	local width, height = Capture.inspectPng(png(768, 432))
	check("width", width == 768, width)
	check("height", height == 432, height)
	local large, tall = Capture.inspectPng(png(70000, 3))
	check("sizes above 65535 are read whole", large == 70000 and tall == 3, large)
end)

case("data that is not a complete PNG is recognised", function()
	check("too short", Capture.inspectPng(buffer.create(10)) == nil)
	check("not a buffer", Capture.inspectPng("PNG") == nil)
	check("nothing", Capture.inspectPng(nil) == nil)
	local wrong = png(4, 4)
	buffer.writeu8(wrong, 1, 0)
	check("wrong signature", Capture.inspectPng(wrong) == nil)
	local headless = png(4, 4)
	buffer.writeu8(headless, 12, 0)
	check("no header chunk", Capture.inspectPng(headless) == nil)
	local cut = png(4, 4)
	buffer.writeu8(cut, buffer.len(cut) - 1, 0)
	local size, reason = Capture.inspectPng(cut)
	check("cut short", size == nil and string.find(reason, "cut short") ~= nil, reason)
	-- A header with nothing after it is exactly what a cut-off transfer looks like.
	local stub = buffer.create(33)
	buffer.copy(stub, 0, png(4, 4), 0, 33)
	check("header only", Capture.inspectPng(stub) == nil)
end)

case("a screenshot is scaled to the requested edge and returned as a checked PNG", function()
	local studio = newStudio()
	studio.data = png(768, 432, 5000)
	local result = Capture.capture(768, nil, allow)
	check("it succeeds", result.status == "ok", result.reason)
	check("the image is the one Studio returned", result.png == studio.data)
	check("the size is the one the PNG declares", result.width == 768 and result.height == 432)
	check("the format is reported", result.format == "png", result.format)
	check("the byte count is the image's own", result.bytes == 5000, result.bytes)
	check("the time taken is reported", type(result.milliseconds) == "number")
	check("exactly one screenshot was requested", #studio.starts == 1, #studio.starts)
	local start = studio.starts[1]
	check("the whole viewport was captured", start.captureWidth == 1920 and start.captureHeight == 1080)
	check("the output was scaled down", start.width == 768 and start.height == 432, `{start.width}x{start.height}`)
	check("no format or other option can be passed to Studio", start.extra == 0, start.extra)
	check("permission was asked for once", studio.permissionRequests == 1)
	check("the gate was asked as for a capture", table.find(studio.gateCalls, true) ~= nil)
end)

case("a requested edge above the limit is brought down to the limit", function()
	local studio = newStudio()
	studio.viewportWidth, studio.viewportHeight = 4000, 2000
	studio.data = png(Capture.MAX_EDGE, Capture.MAX_EDGE / 2)
	local result = Capture.capture(100000, nil, allow)
	check("it succeeds", result.status == "ok", result.reason)
	check("the output edge is the limit", studio.starts[1].width == Capture.MAX_EDGE, studio.starts[1].width)
end)

case("a small viewport is not scaled up", function()
	local studio = newStudio()
	studio.viewportWidth, studio.viewportHeight = 300, 200
	studio.data = png(300, 200)
	local result = Capture.capture(768, nil, allow)
	check("it succeeds", result.status == "ok", result.reason)
	check("the output is the viewport's size", studio.starts[1].width == 300 and studio.starts[1].height == 200)
end)

for label, value in { ["zero"] = 0, ["negative"] = -5, ["not a number"] = "768", ["NaN"] = 0 / 0 } :: { [string]: any } do
	case(`a requested size that is {label} is refused`, function()
		local studio = newStudio()
		studio.data = png(4, 4)
		refused(Capture.capture(value, nil, allow), "not valid")
		check("no permission was asked for", studio.permissionRequests == 0)
		check("no screenshot was requested", #studio.starts == 0)
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

case("an unanswered permission prompt is given up on, and only one is ever outstanding", function()
	local studio = newStudio()
	studio.permission = "never"
	studio.data = png(768, 432)
	refused(Capture.capture(768, nil, allow), "not answered in time")
	check("it waited no longer than the limit", studio.now <= Capture.PERMISSION_TIMEOUT + 1, studio.now)
	check("it did wait for the limit", studio.now >= Capture.PERMISSION_TIMEOUT, studio.now)
	check("no screenshot was requested", #studio.starts == 0)

	-- The prompt is still open. Another screenshot must not open a second one.
	local before = studio.now
	refused(Capture.capture(768, nil, allow), "still unanswered")
	check("Studio was not asked again", studio.permissionRequests == 1, studio.permissionRequests)
	check("no second worker was started", #studio.workers == 1, #studio.workers)
	check("the second request did not wait", studio.now == before, studio.now - before)
	check("no screenshot was requested", #studio.starts == 0)

	-- The person finally answers "allow". That late answer authorises nothing by itself.
	studio.permission = "grant"
	coroutine.resume(studio.workers[1])
	check("the late answer requested no screenshot", #studio.starts == 0, #studio.starts)

	-- The next screenshot asks Studio again, and only then goes ahead.
	local result = Capture.capture(768, nil, allow)
	check("the next screenshot asks again", studio.permissionRequests == 2, studio.permissionRequests)
	check("and then succeeds", result.status == "ok", result.reason)
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
end)

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

case("an image exactly at the byte limit is returned", function()
	local studio = newStudio()
	studio.data = png(768, 432, Capture.MAX_BYTES)
	local result = Capture.capture(768, nil, allow)
	check("it succeeds", result.status == "ok", result.reason)
end)

case("only PNG is ever asked for", function()
	local studio = newStudio()
	studio.data = png(160, 90)
	refused(Capture.capture(160, "rgba8", allow), "only PNG")
	refused(Capture.capture(160, false, allow), "only PNG")
	check("Studio was never asked for permission", studio.permissionRequests == 0, studio.permissionRequests)
	check("no screenshot was requested", #studio.starts == 0)
end)

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

Capture.setBackend(nil)
Capture.setGate(nil)
print(`{count - failures}/{count} capture checks passed`)
if failures > 0 then
	process.exit(1)
end
