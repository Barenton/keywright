--!strict
-- Viewport screenshots through StudioCaptureService, the documented path that Studio
-- gates behind its own permission prompt. Nothing else is ever used to obtain an image.
--
-- Screenshots are off unless an entry point opens the gate; the plugin people install
-- never does. While the gate is closed nothing here asks Studio for permission or for an
-- image. A screenshot is also only ever taken for a caller that supplies a guard, which
-- is how a preview vouches that the image would still be of what it sampled.
--
-- The request to Studio is always the same: a PNG, without interface elements. Every
-- failure is a status with a reason, never an error. Every wait has a deadline, and a
-- result that arrives after its deadline is not a success. An image is returned only if
-- it is a complete PNG of exactly the size that was asked for, within the byte limit,
-- and the gate and the caller's guard still allow it. There is no other way to an image.
--
-- Everything that touches Studio goes through the backend table, so the rules here are
-- tested without Studio. How Studio itself behaves has not been verified.

local Capture = {}

export type Result = {
	status: "ok" | "unavailable",
	reason: string?,
	format: string?,
	width: number?,
	height: number?,
	bytes: number?,
	milliseconds: number?,
	png: buffer?,
}

export type Backend = {
	-- StudioCaptureService, or nil where this Studio does not have it.
	service: () -> any?,
	-- Size of the viewport in pixels, or nil when there is no camera.
	viewport: () -> (number?, number?),
	-- Asks Studio for a PNG of the viewport without interface elements.
	start: (service: any, captureWidth: number, captureHeight: number, width: number, height: number) -> any,
	-- "pending", "ready" or "error".
	status: (capture: any) -> string,
	errors: (capture: any) -> { string },
	read: (capture: any) -> buffer,
	clock: () -> number,
	wait: (seconds: number) -> (),
	spawn: (run: () -> ()) -> any,
	cancel: (thread: any) -> (),
}

-- Returns nil while the screenshot may still be taken and returned, or the reason not to.
export type Guard = () -> string?

-- Returns nil to allow screenshots now, or the reason not to. Asked again every time.
-- `capturing` is true when an image is about to be taken or returned, and false when the
-- question is only whether screenshots are possible.
export type Gate = (capturing: boolean) -> string?

-- Longest edge of a returned image, in pixels.
Capture.MAX_EDGE = 1536
-- Largest image returned. Base64 of this still fits in one message with room to spare.
Capture.MAX_BYTES = 4 * 1024 * 1024
Capture.PERMISSION_TIMEOUT = 20
Capture.BUFFER_TIMEOUT = 15

-- Why nothing is captured while the gate is closed.
Capture.GATE_CLOSED =
	"screenshots of a preview are off: they run only in an armed disposable fixture until their behaviour in Studio has been validated"

local PNG_SIGNATURE = { 137, 80, 78, 71, 13, 10, 26, 10 }
-- The empty chunk every complete PNG ends with, checksum included.
local PNG_END = { 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 }
-- Signature, header chunk, one image data chunk and end chunk: nothing shorter is a PNG.
local PNG_MINIMUM = 8 + 25 + 12 + 12
-- Chunks that make a PNG an animation. A screenshot is one still image.
local PNG_ANIMATION = { acTL = true, fcTL = true, fdAT = true }

-- Why permission can no longer be asked for in this session, once a prompt was abandoned.
Capture.PERMISSION_ABANDONED = "a screenshot permission prompt was abandoned; reload the plugin before asking again"

local gate: Gate? = nil
local revoked: ((reason: string) -> ())? = nil

-- Opens the gate under the given rule, or closes it with nil. The gate starts closed.
-- `onRevoke` is told whenever a screenshot in progress is abandoned, so that whatever
-- approval stands behind the rule can be withdrawn.
function Capture.setGate(rule: Gate?, onRevoke: ((reason: string) -> ())?)
	gate = rule
	revoked = if rule then onRevoke else nil
end

-- Withdraws whatever approval stands behind the gate. Called on cancellation and unload.
function Capture.revoke(reason: string)
	if revoked then
		pcall(revoked, reason)
	end
end

-- Nil when a screenshot may be taken now, otherwise the reason it may not.
function Capture.refusal(capturing: boolean?): string?
	if not gate then
		return Capture.GATE_CLOSED
	end
	local ok, refusal = pcall(gate, capturing == true)
	if not ok then
		return "the capture gate could not be evaluated"
	elseif refusal ~= nil then
		return if type(refusal) == "string" and refusal ~= "" then refusal else Capture.GATE_CLOSED
	end
	return nil
end

local function robloxBackend(): Backend
	return {
		service = function()
			local ok, result = pcall(function()
				return game:GetService("StudioCaptureService")
			end)
			return if ok then result else nil
		end,
		viewport = function()
			local camera = workspace.CurrentCamera
			if not camera then
				return nil, nil
			end
			return camera.ViewportSize.X, camera.ViewportSize.Y
		end,
		start = function(service, captureWidth, captureHeight, width, height)
			-- Both are stated because Studio's defaults are raw pixels and all interface.
			return service:CaptureScreenshot({
				CaptureSize = Vector2.new(captureWidth, captureHeight),
				OutputSize = Vector2.new(width, height),
				ResampleMode = Enum.ResamplerMode.Default,
				Format = Enum.StudioCaptureScreenshotFormat.PNG,
				UICaptureMode = Enum.UICaptureMode.None,
			})
		end,
		status = function(capture)
			local status = capture.BufferStatus
			if status == Enum.StudioCaptureBufferStatus.Ready then
				return "ready"
			elseif status == Enum.StudioCaptureBufferStatus.Error then
				return "error"
			end
			return "pending"
		end,
		errors = function(capture)
			return capture:GetErrors()
		end,
		read = function(capture)
			return capture:GetBuffer()
		end,
		clock = os.clock,
		wait = function(seconds)
			task.wait(seconds)
		end,
		spawn = function(run)
			return task.spawn(run)
		end,
		cancel = function(thread)
			task.cancel(thread)
		end,
	}
end

local current: Backend? = nil

-- The one request to Studio for permission that is waiting for an answer, if any.
local permissionRequest: { thread: any, abandoned: boolean }? = nil
-- Set when such a request was given up on. Its worker is cancelled, and because the
-- prompt it opened may still be on screen, permission is not asked for again.
local permissionAbandoned = false

local function backend(): Backend
	if not current then
		current = robloxBackend()
	end
	return current :: Backend
end

-- Replaces the backend. For tests.
function Capture.setBackend(replacement: Backend?)
	current = replacement
	permissionRequest = nil
	permissionAbandoned = false
end

-- Gives up on a permission request that is still waiting: its worker is cancelled, so
-- nothing is left running, and no further request is made in this session. Called when
-- a screenshot is cancelled or runs out of time. Does nothing when none is waiting.
function Capture.abandon()
	local request = permissionRequest
	if not request then
		return
	end
	-- Marked first, so that even if the worker cannot be cancelled its answer is ignored.
	request.abandoned = true
	permissionRequest = nil
	permissionAbandoned = true
	pcall(backend().cancel, request.thread)
end

-- Reads the size a PNG declares, after walking its chunks: a header first, at least one
-- chunk of image data, no animation, and the closing chunk exactly at the end. Returns
-- nil and the reason otherwise. Checksums and the pixel data itself are checked by the
-- relay, which can decompress them.
function Capture.inspectPng(data: any): (number?, any)
	if type(data) ~= "buffer" then
		return nil, "the capture returned no image data"
	end
	local length = buffer.len(data)
	if length < PNG_MINIMUM then
		return nil, "the capture returned data too short to be a PNG"
	end
	for index, byte in PNG_SIGNATURE do
		if buffer.readu8(data, index - 1) ~= byte then
			return nil, "the capture returned data that is not a PNG"
		end
	end
	for index, byte in PNG_END do
		if buffer.readu8(data, length - #PNG_END + index - 1) ~= byte then
			return nil, "the capture returned a PNG that is cut short"
		end
	end
	local function big(offset: number): number
		return buffer.readu8(data, offset) * 16777216
			+ buffer.readu8(data, offset + 1) * 65536
			+ buffer.readu8(data, offset + 2) * 256
			+ buffer.readu8(data, offset + 3)
	end

	local offset = 8
	local width, height = nil :: number?, nil :: number?
	local imageData = false
	while true do
		if offset + 12 > length then
			return nil, "the capture returned a PNG that is cut short"
		end
		local size = big(offset)
		local kind = buffer.readstring(data, offset + 4, 4)
		local finish = offset + 12 + size
		if finish > length then
			return nil, "the capture returned a PNG that is cut short"
		end
		if width == nil then
			if kind ~= "IHDR" or size ~= 13 then
				return nil, "the capture returned a PNG without a header"
			end
			width, height = big(offset + 8), big(offset + 12)
		elseif kind == "IHDR" then
			return nil, "the capture returned a PNG with two headers"
		elseif PNG_ANIMATION[kind] then
			return nil, "the capture returned an animated PNG"
		elseif kind == "IDAT" then
			if size == 0 then
				return nil, "the capture returned a PNG with empty image data"
			end
			imageData = true
		elseif kind == "IEND" then
			if finish ~= length then
				return nil, "the capture returned a PNG with data after its end"
			elseif not imageData then
				return nil, "the capture returned a PNG with no image data"
			end
			return width, height
		end
		offset = finish
	end
end

-- Asks for permission without blocking forever on an unanswered prompt. At most one
-- request is ever outstanding. If it is not answered in time its worker is cancelled, so
-- no late answer can arrive, and permission is not asked for again in this session.
function Capture.requestPermission(timeoutSeconds: number?): (boolean, string?)
	-- With the gate closed, Studio is not even asked to show its prompt.
	local closed = Capture.refusal(false)
	if closed then
		return false, closed
	end
	local engine = backend()
	local studioCapture = engine.service()
	if not studioCapture then
		return false, "StudioCaptureService is not available in this Studio version"
	end
	if permissionAbandoned then
		return false, Capture.PERMISSION_ABANDONED
	elseif permissionRequest then
		return false, "an earlier screenshot permission prompt is still unanswered"
	end
	local done, granted, problem = false, false, nil :: string?
	-- Set before the request starts, so that time it spends before yielding counts.
	local deadline = engine.clock() + (timeoutSeconds or Capture.PERMISSION_TIMEOUT)
	local request = { thread = nil :: any, abandoned = false }
	permissionRequest = request
	request.thread = engine.spawn(function()
		local ok, result = pcall(function()
			return studioCapture:RequestScreenshotPermissionAsync()
		end)
		if permissionRequest == request then
			permissionRequest = nil
		end
		if request.abandoned then
			-- Given up on; whatever the answer is, it counts for nothing.
			return
		end
		if ok then
			granted = result == true
		else
			problem = tostring(result)
		end
		done = true
	end)
	while not done and engine.clock() < deadline do
		engine.wait(0.1)
	end
	if not done then
		Capture.abandon()
		return false, "the screenshot permission prompt was not answered in time"
	elseif engine.clock() > deadline then
		return false, "the screenshot permission prompt was not answered in time"
	end
	if problem then
		return false, problem
	end
	if not granted then
		return false, "screenshot permission was denied or screenshots are disabled in Studio settings"
	end
	return true, nil
end

function Capture.available(): (boolean, string?)
	local closed = Capture.refusal(false)
	if closed then
		return false, closed
	end
	local studioCapture = backend().service()
	if not studioCapture then
		return false, "StudioCaptureService is not available in this Studio version"
	end
	local ok, result = pcall(function()
		return studioCapture:CanCaptureScreenshot()
	end)
	if not ok then
		return false, tostring(result)
	end
	if result ~= true then
		return false, "Studio reports that a screenshot cannot be captured now"
	end
	return true, nil
end

local function unavailable(reason: string?): Result
	return { status = "unavailable", reason = reason }
end

-- One attempt at a screenshot. `progress.asked` is set once Studio has been asked for
-- anything, permission included.
local function take(progress: { asked: boolean }, maxEdge: number, format: any?, guard: Guard?): Result
	local closed = Capture.refusal(true)
	if closed then
		return unavailable(closed)
	end
	if type(guard) ~= "function" then
		-- The viewport on its own is never captured.
		return unavailable("screenshots are taken only of a preview")
	end
	if format ~= nil then
		return unavailable("only PNG screenshots are taken")
	end
	local engine = backend()
	if type(maxEdge) ~= "number" or maxEdge ~= maxEdge or maxEdge < 1 then
		return unavailable("the requested image size is not valid")
	end
	maxEdge = math.min(math.floor(maxEdge), Capture.MAX_EDGE)

	progress.asked = true
	local granted, reason = Capture.requestPermission()
	if not granted then
		return unavailable(reason)
	end
	local available, whyNot = Capture.available()
	if not available then
		return unavailable(whyNot)
	end
	local studioCapture = engine.service()
	local viewportWidth, viewportHeight = engine.viewport()
	if not studioCapture or not viewportWidth or not viewportHeight then
		return unavailable("there is no current camera")
	end
	if viewportWidth < 1 or viewportHeight < 1 then
		return unavailable("the viewport has no size")
	end

	local scale = math.min(1, maxEdge / math.max(viewportWidth, viewportHeight))
	local width = math.max(1, math.floor(viewportWidth * scale))
	local height = math.max(1, math.floor(viewportHeight * scale))

	-- The permission prompt may have taken a while; the caller may no longer want this.
	local refused = Capture.refusal(true) or guard()
	if refused then
		return unavailable(refused)
	end

	local started = engine.clock()
	local deadline = started + Capture.BUFFER_TIMEOUT
	local ok, capture = pcall(engine.start, studioCapture, viewportWidth, viewportHeight, width, height)
	if not ok or capture == nil then
		return unavailable(if ok then "Studio returned no capture" else tostring(capture))
	end

	while true do
		local read, status = pcall(engine.status, capture)
		-- Checked before the status is believed: an image that is ready late is not taken.
		if engine.clock() > deadline then
			return unavailable("the capture did not finish in time")
		end
		if not read then
			return unavailable(tostring(status))
		end
		if status == "ready" then
			break
		elseif status == "error" then
			local listed, errors = pcall(engine.errors, capture)
			return unavailable("capture failed: " .. (if listed then table.concat(errors, "; ") else "unknown error"))
		end
		engine.wait(0)
	end

	local read, data = pcall(engine.read, capture)
	if not read then
		return unavailable(tostring(data))
	end
	if engine.clock() > deadline then
		return unavailable("the capture did not finish in time")
	end
	if type(data) ~= "buffer" then
		return unavailable("the capture returned no image data")
	end
	local bytes = buffer.len(data)
	if bytes > Capture.MAX_BYTES then
		return unavailable(`the image is larger than the {Capture.MAX_BYTES} byte limit`)
	end
	local pngWidth, pngHeight = Capture.inspectPng(data)
	if not pngWidth then
		return unavailable(pngHeight)
	end
	if pngWidth ~= width or pngHeight ~= height then
		return unavailable(
			`the image is {pngWidth} by {pngHeight} pixels, not the {width} by {height} that was asked for`
		)
	end

	-- The screenshot took time; make sure it is still the one the caller asked for.
	local stale = Capture.refusal(true) or guard()
	if stale then
		return unavailable(stale)
	end
	-- Checked last, after every other check has had its turn: late is not a success.
	if engine.clock() > deadline then
		return unavailable("the capture did not finish in time")
	end
	-- Everything reported here was read from the image itself.
	return {
		status = "ok",
		format = "png",
		width = pngWidth,
		height = pngHeight,
		bytes = bytes,
		milliseconds = math.round((engine.clock() - started) * 1000),
		png = data,
	}
end

-- Takes one PNG screenshot of the viewport, scaled so its longest edge is at most
-- `maxEdge`. `format` exists only so that older callers fail closed: anything but nil is
-- refused. `guard` is asked immediately before the screenshot is requested and again
-- before the image is returned; if it gives a reason either time, no image is returned.
--
-- An approval behind the gate is good for attempts that succeed. If an attempt fails
-- after Studio was asked for anything (a prompt left unanswered, an image that came late
-- or was not what was asked for), the approval is withdrawn, so the next attempt needs a
-- person again.
function Capture.capture(maxEdge: number, format: any?, guard: Guard?): Result
	local progress = { asked = false }
	local result = take(progress, maxEdge, format, guard)
	if result.status ~= "ok" and progress.asked then
		Capture.revoke(result.reason or "the capture failed")
	end
	return result
end

return Capture
