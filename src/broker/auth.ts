import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import type { Role } from "./protocol.js";

const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789";
export const PAIRING_CODE_LENGTH = 10;

export function hmacHex(key: Buffer, text: string): string {
	return createHmac("sha256", key).update(text, "utf8").digest("hex");
}

export function newNonce(): string {
	return randomBytes(16).toString("hex");
}

/** The text each side signs. Binding role and both nonces prevents replay and reflection. */
export function proofInput(side: "broker" | "client", role: Role, clientNonce: string, serverNonce: string): string {
	return `mb1|${side}|${role}|${clientNonce}|${serverNonce}`;
}

export function safeEqualHex(a: string, b: string): boolean {
	if (a.length !== b.length) return false;
	return timingSafeEqual(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

export function normalizePairingCode(code: string): string {
	return code.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export function isValidPairingCode(code: string): boolean {
	const normalized = normalizePairingCode(code);
	return normalized.length >= 8 && normalized.length <= 32;
}

export function newPairingCode(): string {
	const bytes = randomBytes(PAIRING_CODE_LENGTH);
	let out = "";
	for (const byte of bytes) out += CODE_ALPHABET[byte % CODE_ALPHABET.length];
	return out;
}

export function pairingKey(code: string): Buffer {
	return Buffer.from(`mbpair:${normalizePairingCode(code)}`, "utf8");
}

/** Both sides derive the long-lived credential key, so it never crosses the wire. */
export function deriveCredentialKeyHex(codeKey: Buffer, clientNonce: string, serverNonce: string): string {
	return hmacHex(codeKey, `mb1|cred|${clientNonce}|${serverNonce}`);
}

export function newCredentialId(): string {
	return randomBytes(8).toString("hex");
}
