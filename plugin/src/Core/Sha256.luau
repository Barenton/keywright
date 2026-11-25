--!strict
-- SHA-256 and HMAC-SHA256 over buffers. Used only for the broker handshake.

local Sha256 = {}

local band, bxor, bnot = bit32.band, bit32.bxor, bit32.bnot
local rrotate, rshift, byteswap = bit32.rrotate, bit32.rshift, bit32.byteswap

-- stylua: ignore
local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local MOD = 4294967296
local BLOCK = 64

function Sha256.digest(message: buffer): buffer
	local length = buffer.len(message)
	local paddedLength = (length + 9 + 63) // BLOCK * BLOCK
	local data = buffer.create(paddedLength)
	buffer.copy(data, 0, message)
	buffer.writeu8(data, length, 0x80)
	local bits = length * 8
	buffer.writeu32(data, paddedLength - 8, byteswap(bits // MOD))
	buffer.writeu32(data, paddedLength - 4, byteswap(bits % MOD))

	local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
	local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
	local w = table.create(64, 0)

	for chunk = 0, paddedLength - BLOCK, BLOCK do
		for i = 0, 15 do
			w[i + 1] = byteswap(buffer.readu32(data, chunk + i * 4))
		end
		for i = 17, 64 do
			local x, y = w[i - 15], w[i - 2]
			local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
			local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
		end

		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for i = 1, 64 do
			local s1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = (h + s1 + ch + K[i] + w[i]) % MOD
			local s0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			local t2 = (s0 + maj) % MOD
			h, g, f, e = g, f, e, (d + t1) % MOD
			d, c, b, a = c, b, a, (t1 + t2) % MOD
		end

		h0, h1, h2, h3 = (h0 + a) % MOD, (h1 + b) % MOD, (h2 + c) % MOD, (h3 + d) % MOD
		h4, h5, h6, h7 = (h4 + e) % MOD, (h5 + f) % MOD, (h6 + g) % MOD, (h7 + h) % MOD
	end

	local out = buffer.create(32)
	for index, value in { h0, h1, h2, h3, h4, h5, h6, h7 } do
		buffer.writeu32(out, (index - 1) * 4, byteswap(value))
	end
	return out
end

function Sha256.hmac(key: buffer, message: buffer): buffer
	if buffer.len(key) > BLOCK then
		key = Sha256.digest(key)
	end
	local keyLength = buffer.len(key)
	local messageLength = buffer.len(message)

	local inner = buffer.create(BLOCK + messageLength)
	local outer = buffer.create(BLOCK + 32)
	for i = 0, BLOCK - 1 do
		local byte = if i < keyLength then buffer.readu8(key, i) else 0
		buffer.writeu8(inner, i, bxor(byte, 0x36))
		buffer.writeu8(outer, i, bxor(byte, 0x5c))
	end
	buffer.copy(inner, BLOCK, message)
	buffer.copy(outer, BLOCK, Sha256.digest(inner))
	return Sha256.digest(outer)
end

return Sha256
