--!strict
-- Headless tests for the modules that only compute. Run with: lune run plugin/test/run.luau
-- The vectors match test/auth.test.ts, so both implementations are held to the same answers.

local process = require("@lune/process")

local Auth = require("../src/Auth")
local FixtureGuard = require("../probe/FixtureGuard")
local Codec = require("../src/Codec")
local Sha256 = require("../src/Sha256")

local failures = 0
local count = 0

local function check(name: string, actual: any, expected: any)
	count += 1
	if actual ~= expected then
		failures += 1
		print(`FAIL {name}\n  expected: {expected}\n  actual:   {actual}`)
	end
end

local function sha(text: string): string
	return Codec.toHex(Sha256.digest(buffer.fromstring(text)))
end

-- FIPS 180-4 examples.
check("sha256 empty", sha(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("sha256 abc", sha("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check(
	"sha256 two blocks",
	sha("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
	"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
)
check("sha256 55 bytes", sha(string.rep("a", 55)), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
check("sha256 56 bytes", sha(string.rep("a", 56)), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
check("sha256 64 bytes", sha(string.rep("a", 64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
check(
	"sha256 1000 bytes",
	sha(string.rep("a", 1000)),
	"41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
)

-- RFC 4231 test cases 1, 2 and 6 (key longer than one block).
check(
	"hmac rfc4231 case 1",
	Codec.toHex(Sha256.hmac(buffer.fromstring(string.rep("\x0b", 20)), buffer.fromstring("Hi There"))),
	"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
)
check(
	"hmac rfc4231 case 2",
	Auth.hmacHex(buffer.fromstring("Jefe"), "what do ya want for nothing?"),
	"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
)
check(
	"hmac rfc4231 case 6",
	Auth.hmacHex(buffer.fromstring(string.rep("\xaa", 131)), "Test Using Larger Than Block-Size Key - Hash Key First"),
	"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
)

-- Handshake strings.
check("proof input", Auth.proofInput("broker", "plugin", "aa", "bb"), "mb1|broker|plugin|aa|bb")
check("pairing key", buffer.tostring(Auth.pairingKey("abcd-efgh-23")), "mbpair:ABCDEFGH23")
check(
	"credential key",
	Auth.deriveCredentialKeyHex(
		Auth.pairingKey("abcd-efgh-23"),
		"00112233445566778899aabbccddeeff",
		"ffeeddccbbaa99887766554433221100"
	),
	Auth.hmacHex(
		buffer.fromstring("mbpair:ABCDEFGH23"),
		"mb1|cred|00112233445566778899aabbccddeeff|ffeeddccbbaa99887766554433221100"
	)
)
check(
	"nonce from guid",
	Auth.nonceFromGuid("{0F8FAD5B-D9CB-469F-A165-70867728950E}"),
	"0f8fad5bd9cb469fa16570867728950e"
)
check("equalHex same", Auth.equalHex("abcd", "abcd"), true)
check("equalHex differs", Auth.equalHex("abcd", "abce"), false)
check("equalHex length", Auth.equalHex("abcd", "abc"), false)

-- Codec: RFC 4648 vectors.
for input, expected in
	{
		[""] = "",
		f = "Zg==",
		fo = "Zm8=",
		foo = "Zm9v",
		foob = "Zm9vYg==",
		fooba = "Zm9vYmE=",
		foobar = "Zm9vYmFy",
	}
do
	check(`base64 "{input}"`, Codec.toBase64(buffer.fromstring(input)), expected)
end
local allBytes = buffer.create(256)
for i = 0, 255 do
	buffer.writeu8(allBytes, i, i)
end
check("hex round trip", buffer.tostring(Codec.fromHex(Codec.toHex(allBytes))), buffer.tostring(allBytes))
check("hex encoding", Codec.toHex(buffer.fromstring("\x00\x0f\xa0\xff")), "000fa0ff")

-- Fixture guard: probes may act only in an unpublished fixture, in edit mode, with a valid marker.
local FIXTURE_ID = "0123456789abcdef0123456789abcdef"
local function guard(overrides: { [string]: any }): (boolean, string)
	local observation = {
		markerClass = "StringValue" :: string?,
		markerValue = (FixtureGuard.MARKER_PREFIX .. FIXTURE_ID) :: string?,
		placeId = 0,
		gameId = 0,
		isEdit = true,
	}
	for key, value in overrides do
		(observation :: any)[key] = if value == "<nil>" then nil else value
	end
	return FixtureGuard.check(observation)
end
local accepted, acceptedId = guard({})
check("guard accepts a valid fixture", accepted, true)
check("guard returns the fixture id", acceptedId, FIXTURE_ID)
for name, overrides in
	{
		["published place"] = { placeId = 123 },
		["published experience"] = { gameId = 456 },
		["playtest"] = { isEdit = false },
		["no marker"] = { markerClass = "<nil>", markerValue = "<nil>" },
		["marker of another class"] = { markerClass = "Folder", markerValue = "<nil>" },
		["empty marker"] = { markerValue = "" },
		["old probe marker"] = { markerValue = '{"port":47419,"code":"ABCDEFGH23"}' },
		["wrong prefix"] = { markerValue = "keywright-fixture/2/" .. FIXTURE_ID },
		["short id"] = { markerValue = FixtureGuard.MARKER_PREFIX .. "0123" },
		["uppercase id"] = { markerValue = FixtureGuard.MARKER_PREFIX .. string.upper(FIXTURE_ID) },
		["trailing text"] = { markerValue = FixtureGuard.MARKER_PREFIX .. FIXTURE_ID .. "x" },
	} :: { [string]: { [string]: any } }
do
	local allowed, reason = guard(overrides)
	check(`guard rejects: {name}`, allowed, false)
	check(`guard gives a reason: {name}`, type(reason) == "string" and #reason > 0, true)
end

-- Screenshots: only in the fixture the probe was started in, armed with that fixture's own id.
local OTHER_ID = "fedcba9876543210fedcba9876543210"
local function shots(overrides: { [string]: any }, armed: any, pinned: any): (boolean, string)
	local observation = {
		markerClass = "StringValue" :: string?,
		markerValue = (FixtureGuard.MARKER_PREFIX .. FIXTURE_ID) :: string?,
		placeId = 0,
		gameId = 0,
		isEdit = true,
	}
	for key, value in overrides do
		(observation :: any)[key] = if value == "<nil>" then nil else value
	end
	return FixtureGuard.screenshots(observation, armed, pinned)
end
local armedOk, armedId = shots({}, FIXTURE_ID, FIXTURE_ID)
check("screenshots allowed when armed with the pinned fixture's id", armedOk, true)
check("armed fixture returns its id", armedId, FIXTURE_ID)
for name, value in
	{
		["true"] = true,
		["false"] = false,
		["the text true"] = "true",
		["a number"] = 1,
		["a table"] = {},
		["another fixture's id"] = OTHER_ID,
		["the id in capitals"] = string.upper(FIXTURE_ID),
		["the id with a trailing space"] = FIXTURE_ID .. " ",
		["the whole marker value"] = FixtureGuard.MARKER_PREFIX .. FIXTURE_ID,
		["an empty string"] = "",
	} :: { [string]: any }
do
	local allowed, reason = shots({}, value, FIXTURE_ID)
	check(`screenshots refused when the arm attribute is {name}`, allowed, false)
	check(`a reason is given when the arm attribute is {name}`, type(reason) == "string" and #reason > 0, true)
end
check("screenshots refused when the arm attribute is absent", (shots({}, nil, FIXTURE_ID)), false)
-- A marker of the right form is not enough: it must be the fixture the probe started in.
local otherMarker = { markerValue = FixtureGuard.MARKER_PREFIX .. OTHER_ID }
check(
	"another fixture's marker is refused even when armed with its own id",
	(shots(otherMarker, OTHER_ID, FIXTURE_ID)),
	false
)
check(
	"another fixture's marker is refused when armed with the pinned id",
	(shots(otherMarker, FIXTURE_ID, FIXTURE_ID)),
	false
)
check("the pinned fixture is refused when armed for another", (shots({}, OTHER_ID, OTHER_ID)), false)
for name, pinned in { ["nothing"] = "<nil>", ["a short id"] = "0123", ["true"] = true } :: { [string]: any } do
	check(
		`screenshots refused when the pinned id is {name}`,
		(shots({}, FIXTURE_ID, if pinned == "<nil>" then nil else pinned)),
		false
	)
end
for name, overrides in
	{
		["a published place"] = { placeId = 123 },
		["a published experience"] = { gameId = 456 },
		["a playtest"] = { isEdit = false },
		["no marker"] = { markerClass = "<nil>", markerValue = "<nil>" },
		["a malformed marker"] = { markerValue = "keywright-fixture/1/xyz" },
	} :: { [string]: { [string]: any } }
do
	check(`armed screenshots still refused in {name}`, (shots(overrides, FIXTURE_ID, FIXTURE_ID)), false)
end

print(`{count - failures}/{count} checks passed`)
if failures > 0 then
	process.exit(1)
end
