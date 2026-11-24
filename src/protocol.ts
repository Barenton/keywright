import { z } from "zod";

export const PROTOCOL_VERSION = 1;
export const DEFAULT_PORT = 47318;
export const HANDSHAKE_TIMEOUT_MS = 5_000;
export const REQUEST_TIMEOUT_MS = 30_000;
export const MAX_REQUEST_TIMEOUT_MS = 120_000;
export const MAX_MESSAGE_BYTES = 8 * 1024 * 1024;
export const PAIRING_TTL_MS = 5 * 60_000;
export const PAIRING_MAX_FAILURES = 5;
export const IDLE_EXIT_MS = 10 * 60_000;

export type Role = "adapter" | "plugin";

export const ERROR_CODES = [
	"REVISION_CONFLICT",
	"SOURCE_CHANGED",
	"UNSUPPORTED_RIG",
	"UNSUPPORTED_CLIP_FORMAT",
	"SESSION_NOT_FOUND",
	"STUDIO_NOT_IN_EDIT_MODE",
	"CAPTURE_UNAVAILABLE",
	"PREVIEW_UNAVAILABLE",
	"CANCELLED",
	"LIMIT_EXCEEDED",
	"INVALID_ARGUMENT",
	"TIMEOUT",
	"BROKER_UNAVAILABLE",
	"BROKER_PORT_CONFLICT",
	"NOT_FOUND",
	"INTERNAL",
] as const;
export type ErrorCode = (typeof ERROR_CODES)[number];

export interface WireError {
	code: string;
	message: string;
	hint?: string;
}

export class BridgeError extends Error {
	readonly code: string;
	readonly hint?: string;
	constructor(code: string, message: string, hint?: string) {
		super(message);
		this.name = "BridgeError";
		this.code = code;
		this.hint = hint;
	}
	toWire(): WireError {
		return this.hint === undefined
			? { code: this.code, message: this.message }
			: { code: this.code, message: this.message, hint: this.hint };
	}
}

const hex = z.string().regex(/^[0-9a-f]+$/);
const nonce = hex.length(32);
const proof = hex.length(64);

/** `user`, `pair`, or `cred:<id>`: which key the client will prove knowledge of. */
export const KeyName = z.string().regex(/^(user|pair|cred:[0-9a-f]{16})$/);

export const HelloMessage = z.object({
	t: z.literal("hello"),
	v: z.number().int(),
	role: z.enum(["adapter", "plugin"]),
	key: KeyName,
	nonce,
});

export const ChallengeMessage = z.object({
	t: z.literal("challenge"),
	v: z.number().int(),
	nonce,
	proof,
});

export const AuthMessage = z.object({ t: z.literal("auth"), proof });

export const ReadyMessage = z.object({
	t: z.literal("ready"),
	/** Present after pairing: the id of the credential both sides derived. */
	credential: z.string().optional(),
});

export const DeniedMessage = z.object({ t: z.literal("denied"), code: z.string() });

export const RequestMessage = z.object({
	t: z.literal("req"),
	id: z.string().min(1).max(64),
	method: z.string().min(1).max(64),
	session: z.string().max(64).optional(),
	params: z.unknown().optional(),
	timeoutMs: z.number().int().positive().max(MAX_REQUEST_TIMEOUT_MS).optional(),
});

/** Sent by a caller that has given up on a request, and by the broker to the Studio session working on it. */
export const CancelMessage = z.object({ t: z.literal("cancel"), id: z.string().min(1).max(64) });

export const ResponseMessage = z.object({
	t: z.literal("res"),
	id: z.string().min(1).max(64),
	ok: z.boolean(),
	result: z.unknown().optional(),
	error: z
		.object({ code: z.string(), message: z.string(), hint: z.string().optional() })
		.optional(),
});

export const SessionInfo = z.object({
	id: z.string().regex(/^[0-9a-f]{16,64}$/),
	placeName: z.string().max(200),
	placeId: z.number(),
	pluginVersion: z.string().max(40),
});
export type SessionInfo = z.infer<typeof SessionInfo>;

export const SessionMessage = z.object({ t: z.literal("session"), session: SessionInfo });

/** Methods the broker answers itself. Everything else is routed to a Studio session. */
export const BROKER_METHODS = ["broker.status", "broker.sessions", "broker.pair_register"] as const;
