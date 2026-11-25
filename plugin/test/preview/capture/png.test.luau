--!strict
-- Screenshot images: PNG headers read and checked, scaled to the edge asked, held to the byte limit, PNG only.
-- Run with: lune run plugin/test/preview/capture/png.test.luau

local Kit = require("./kit")

local allow = Kit.allow
local build = Kit.build
local Capture = Kit.Capture
local newStudio = Kit.newStudio
local png = Kit.png
local refused = Kit.refused

local check, case, finish = Kit.suite("capture png")
case("the size a PNG declares is read from its header", function()
	local width, height = Capture.inspectPng(png(768, 432))
	check("width", width == 768, width)
	check("height", height == 432, height)
	local large, tall = Capture.inspectPng(png(70000, 3))
	check("sizes above 65535 are read whole", large == 70000 and tall == 3, large)
end)

case("data that is not one complete still PNG is recognised", function()
	local function refused(data: any, expected: string)
		local size, reason = Capture.inspectPng(data)
		check(
			expected,
			size == nil and type(reason) == "string" and string.find(reason, expected, 1, true) ~= nil,
			reason
		)
	end
	refused(buffer.create(10), "too short")
	refused("PNG", "no image data")
	refused(nil, "no image data")
	local wrong = png(4, 4)
	buffer.writeu8(wrong, 1, 0)
	refused(wrong, "not a PNG")
	local headless = png(4, 4)
	buffer.writeu8(headless, 12, 0)
	refused(headless, "without a header")
	local cut = png(4, 4)
	buffer.writeu8(cut, buffer.len(cut) - 1, 0)
	refused(cut, "cut short")
	-- A header with nothing after it is exactly what a cut-off transfer looks like.
	local stub = buffer.create(33)
	buffer.copy(stub, 0, png(4, 4), 0, 33)
	refused(stub, "too short")

	local header = { "IHDR", 13, 4, 4 }
	refused(build({ header, { "gAMA", 20 }, { "IEND", 0 } }), "no image data")
	refused(build({ header, { "IDAT", 0 }, { "gAMA", 1 }, { "IEND", 0 } }), "empty image data")
	refused(build({ header, { "acTL", 8 }, { "IDAT", 20 }, { "IEND", 0 } }), "animated")
	refused(build({ header, { "IDAT", 20 }, { "fdAT", 20 }, { "IEND", 0 } }), "animated")
	refused(build({ header, header, { "IDAT", 20 }, { "IEND", 0 } }), "two headers")
	refused(build({ header, { "IDAT", 20 }, { "IEND", 0 }, { "IDAT", 8 }, { "IEND", 0 } }), "after its end")
	local overrun = build({ header, { "IDAT", 20 }, { "IEND", 0 } })
	buffer.writeu8(overrun, 35, 200)
	refused(overrun, "cut short")

	local several = build({ header, { "gAMA", 4 }, { "IDAT", 10 }, { "IDAT", 10 }, { "IEND", 0 } })
	local width, height = Capture.inspectPng(several)
	check("ordinary extra chunks and split image data are fine", width == 4 and height == 4, height)
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
	check(
		"a screenshot that succeeds leaves the approval standing",
		#studio.revoked == 0,
		table.concat(studio.revoked, "; ")
	)
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

finish()
