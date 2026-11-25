--!strict
-- Shared by the capture suites in this folder: what they are run against, and the
-- helpers they use. Not a suite.
--
--
-- StudioCaptureService is modelled by the fake below: a permission call, an availability
-- call, and a capture whose buffer becomes ready, fails, or never arrives. The tests show
-- that nothing is asked of Studio while the gate is closed, that every wait ends and a
-- late result is not a success, that only one permission request is ever outstanding,
-- that nothing but a complete PNG of the requested size is returned, and that the gate
-- and the caller's guard are honoured before the screenshot is requested and before it is
-- returned. What Studio's service actually does is unverified; passing here says nothing
-- about that.

-- The suite that is running, for helpers here that record checks as they go.
local active: ((name: string, condition: any, detail: any?) -> ())? = nil
local function check(name: string, condition: any, detail: any?)
	(active :: any)(name, condition, detail)
end

local process = require("@lune/process")

local Capture = require("../../../src/Preview/Capture")

-- Builds data shaped like a PNG from a list of chunks, each { type, length } with an
-- optional width and height for the header. Checksums are left empty except on the end
-- chunk: the plugin does not verify them, the relay does.
local function build(chunks: { { any } }): buffer
	local size = 8
	for _, chunk in chunks do
		size += 12 + chunk[2]
	end
	local data = buffer.create(size)
	for index, byte in { 137, 80, 78, 71, 13, 10, 26, 10 } do
		buffer.writeu8(data, index - 1, byte)
	end
	local function big(offset: number, value: number)
		buffer.writeu8(data, offset, bit32.band(bit32.rshift(value, 24), 255))
		buffer.writeu8(data, offset + 1, bit32.band(bit32.rshift(value, 16), 255))
		buffer.writeu8(data, offset + 2, bit32.band(bit32.rshift(value, 8), 255))
		buffer.writeu8(data, offset + 3, bit32.band(value, 255))
	end
	local offset = 8
	for _, chunk in chunks do
		local kind, length = chunk[1], chunk[2]
		big(offset, length)
		buffer.writestring(data, offset + 4, kind)
		if kind == "IHDR" then
			big(offset + 8, chunk[3])
			big(offset + 12, chunk[4])
		elseif kind == "IEND" then
			for index, byte in { 174, 66, 96, 130 } do
				buffer.writeu8(data, offset + 8 + length + index - 1, byte)
			end
		end
		offset += 12 + length
	end
	return data
end

-- A PNG-shaped buffer that declares the given size: header, one chunk of image data and
-- the closing chunk, `length` bytes in all.
local function png(width: number, height: number, length: number?): buffer
	local size = math.max(length or 64, 58)
	return build({ { "IHDR", 13, width, height }, { "IDAT", size - 57 }, { "IEND", 0 } })
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
		cancelled = {} :: { thread },
		-- Whether cancelling a worker really stops it.
		cancelWorks = true,
		-- Seconds Studio takes inside the permission call before it first waits.
		permissionDelay = 0,
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
		studio.now += studio.permissionDelay
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
		cancel = function(thread: thread)
			table.insert(studio.cancelled, thread)
			if studio.cancelWorks and coroutine.status(thread) == "suspended" then
				coroutine.close(thread)
			end
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

local Kit = {}

-- A suite's own count of checks: `check` records one, `case` runs a group of them and
-- counts one that raises, `finish` prints the tally and fails the run if any failed.
function Kit.suite(
	label: string
): ((name: string, condition: any, detail: any?) -> (), (name: string, run: () -> ()) -> (), () -> ())
	local failures, count, current = 0, 0, ""
	local function suiteCheck(name: string, condition: any, detail: any?)
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
			print(
				`FAIL [{name}] raised: {if type(problem) == "table" then (problem :: any).message else tostring(problem)}`
			)
		end
	end
	local function finish()
		print(`{count - failures}/{count} {label} checks passed`)
		if failures > 0 then
			process.exit(1)
		end
	end
	active = suiteCheck
	return suiteCheck, case, finish
end

Capture.setBackend(nil)
Capture.setGate(nil)

Kit.build = build
Kit.png = png
Kit.newStudio = newStudio
Kit.allow = allow
Kit.refused = refused
Kit.process = process
Kit.Capture = Capture

return Kit
