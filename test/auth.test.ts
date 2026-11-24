import assert from "node:assert/strict";
import { test } from "node:test";
import {
	deriveCredentialKeyHex,
	hmacHex,
	isValidPairingCode,
	newPairingCode,
	normalizePairingCode,
	pairingKey,
	proofInput,
	safeEqualHex,
} from "../src/auth.js";

// The same vectors are checked against the Luau implementation in plugin/test.
test("HMAC-SHA256 matches RFC 4231 test case 2", () => {
	assert.equal(
		hmacHex(Buffer.from("Jefe", "utf8"), "what do ya want for nothing?"),
		"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
	);
});

test("proof input binds side, role and both nonces", () => {
	const a = proofInput("broker", "plugin", "aa", "bb");
	assert.equal(a, "mb1|broker|plugin|aa|bb");
	assert.notEqual(a, proofInput("client", "plugin", "aa", "bb"));
	assert.notEqual(a, proofInput("broker", "adapter", "aa", "bb"));
	assert.notEqual(a, proofInput("broker", "plugin", "bb", "aa"));
});

test("credential key vector shared with the Luau implementation", () => {
	const key = pairingKey("abcd-efgh-23");
	assert.equal(key.toString("utf8"), "mbpair:ABCDEFGH23");
	assert.equal(
		deriveCredentialKeyHex(key, "00112233445566778899aabbccddeeff", "ffeeddccbbaa99887766554433221100"),
		hmacHex(key, "mb1|cred|00112233445566778899aabbccddeeff|ffeeddccbbaa99887766554433221100"),
	);
});

test("pairing codes are normalised and validated", () => {
	assert.equal(normalizePairingCode(" ab-cd 12 "), "ABCD12");
	assert.equal(isValidPairingCode("abc"), false);
	assert.equal(isValidPairingCode(newPairingCode()), true);
	assert.notEqual(newPairingCode(), newPairingCode());
});

test("safeEqualHex rejects different lengths without throwing", () => {
	assert.equal(safeEqualHex("abcd", "abcd"), true);
	assert.equal(safeEqualHex("abcd", "abce"), false);
	assert.equal(safeEqualHex("abcd", "abc"), false);
});
