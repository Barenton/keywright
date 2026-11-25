--!strict
-- Hex and base64 encoding for buffers.

local Codec = {}

local HEX = "0123456789abcdef"
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local b64Bytes = table.create(64, 0)
for i = 1, 64 do
	b64Bytes[i] = string.byte(B64, i)
end

function Codec.toHex(data: buffer): string
	local length = buffer.len(data)
	local out = buffer.create(length * 2)
	for i = 0, length - 1 do
		local byte = buffer.readu8(data, i)
		buffer.writeu8(out, i * 2, string.byte(HEX, byte // 16 + 1))
		buffer.writeu8(out, i * 2 + 1, string.byte(HEX, byte % 16 + 1))
	end
	return buffer.tostring(out)
end

function Codec.fromHex(text: string): buffer
	assert(#text % 2 == 0 and string.match(text, "^%x*$") ~= nil, "malformed hex")
	local out = buffer.create(#text // 2)
	for i = 0, #text // 2 - 1 do
		buffer.writeu8(out, i, tonumber(string.sub(text, i * 2 + 1, i * 2 + 2), 16) :: number)
	end
	return out
end

function Codec.toBase64(data: buffer): string
	local length = buffer.len(data)
	local out = buffer.create((length + 2) // 3 * 4)
	local position = 0
	for i = 0, length - 3, 3 do
		local n = buffer.readu8(data, i) * 65536 + buffer.readu8(data, i + 1) * 256 + buffer.readu8(data, i + 2)
		buffer.writeu8(out, position, b64Bytes[n // 262144 + 1])
		buffer.writeu8(out, position + 1, b64Bytes[n // 4096 % 64 + 1])
		buffer.writeu8(out, position + 2, b64Bytes[n // 64 % 64 + 1])
		buffer.writeu8(out, position + 3, b64Bytes[n % 64 + 1])
		position += 4
	end
	local rest = length % 3
	if rest > 0 then
		local i = length - rest
		local n = buffer.readu8(data, i) * 65536
		if rest == 2 then
			n += buffer.readu8(data, i + 1) * 256
		end
		buffer.writeu8(out, position, b64Bytes[n // 262144 + 1])
		buffer.writeu8(out, position + 1, b64Bytes[n // 4096 % 64 + 1])
		buffer.writeu8(out, position + 2, if rest == 2 then b64Bytes[n // 64 % 64 + 1] else 61)
		buffer.writeu8(out, position + 3, 61)
	end
	return buffer.tostring(out)
end

return Codec
