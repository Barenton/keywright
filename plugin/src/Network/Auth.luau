--!strict
-- Handshake mathematics shared with src/broker/auth.ts. Both sides must produce identical strings.

local Codec = require("../Core/Codec")
local Sha256 = require("../Core/Sha256")

local Auth = {}

Auth.PROTOCOL_VERSION = 1

function Auth.hmacHex(key: buffer, text: string): string
	return Codec.toHex(Sha256.hmac(key, buffer.fromstring(text)))
end

function Auth.proofInput(side: "broker" | "client", role: string, clientNonce: string, serverNonce: string): string
	return `mb1|{side}|{role}|{clientNonce}|{serverNonce}`
end

function Auth.normalizeCode(code: string): string
	return (string.gsub(string.upper(code), "[^A-Z0-9]", ""))
end

function Auth.pairingKey(code: string): buffer
	return buffer.fromstring("mbpair:" .. Auth.normalizeCode(code))
end

function Auth.deriveCredentialKeyHex(codeKey: buffer, clientNonce: string, serverNonce: string): string
	return Auth.hmacHex(codeKey, `mb1|cred|{clientNonce}|{serverNonce}`)
end

-- Turns a GUID into the 32 lowercase hex characters the protocol uses for nonces.
function Auth.nonceFromGuid(guid: string): string
	local hex = string.lower((string.gsub(guid, "[^%x]", "")))
	assert(#hex == 32, "GUID did not contain 32 hex digits")
	return hex
end

-- Constant-time comparison of two hex strings.
function Auth.equalHex(a: string, b: string): boolean
	if #a ~= #b then
		return false
	end
	local difference = 0
	for i = 1, #a do
		difference = bit32.bor(difference, bit32.bxor(string.byte(a, i), string.byte(b, i)))
	end
	return difference == 0
end

return Auth
