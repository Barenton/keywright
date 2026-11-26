// Whether a newer release of Keywright is out.
//
// The adapter asks npm's registry for the keywright package's latest version at most once
// a day, in the background, and keeps the answer in Keywright's state folder. The request
// is a plain GET of public information and carries nothing about the person or their
// project. It follows no redirect, reads at most a small reply, and accepts only a plain
// release number. KEYWRIGHT_NO_UPDATE_CHECK=1 turns it off. Nothing else in Keywright
// connects out: the broker only listens on loopback.

import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { compareVersions } from "./broker/launcher.js";
import { writeStateFile } from "./broker/state.js";
import { BUNDLED, viaNpx } from "./layout.js";

export const REGISTRY_URL = "https://registry.npmjs.org/keywright/latest";
export const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;
export const CHECK_TIMEOUT_MS = 3000;
/** The most of the registry's reply that is read. Its answer for one version is far smaller. */
export const MAX_REPLY_BYTES = 64 * 1024;
/** An answer older than this is not passed on: it may no longer be true. */
export const NOTICE_MAX_AGE_MS = 7 * CHECK_INTERVAL_MS;
const CACHE = "release-check.json";
const MAX_CACHE_BYTES = 4096;

interface Checked {
	/** When the registry was last asked, whether or not it answered, in ms since 1970. */
	checkedAt: number;
	/** The latest version from the last answer, and when that answer came. */
	latest?: string;
	answeredAt?: number;
}

export function checkDisabled(env: NodeJS.ProcessEnv = process.env): boolean {
	const value = env.KEYWRIGHT_NO_UPDATE_CHECK;
	return value !== undefined && value !== "" && value !== "0";
}

/**
 * A plain release number. npm's latest tag only ever names a release (prereleases go out
 * as next), and nothing else is accepted, so no free text from the registry reaches an agent.
 */
export const isRelease = (value: unknown): value is string => typeof value === "string" && value.length <= 20 && /^\d{1,5}\.\d{1,5}\.\d{1,5}$/.test(value);

/** What the last check left, if anything usable. Only a small, ordinary file is read. */
export function lastChecked(home: string): Checked | undefined {
	try {
		const file = join(home, CACHE);
		const info = statSync(file);
		if (!info.isFile() || info.size > MAX_CACHE_BYTES) return undefined;
		const parsed = JSON.parse(readFileSync(file, "utf8")) as Partial<Checked>;
		if (typeof parsed.checkedAt !== "number" || !Number.isFinite(parsed.checkedAt)) return undefined;
		const answered = isRelease(parsed.latest) && typeof parsed.answeredAt === "number" && Number.isFinite(parsed.answeredAt);
		return answered ? { checkedAt: parsed.checkedAt, latest: parsed.latest, answeredAt: parsed.answeredAt } : { checkedAt: parsed.checkedAt };
	} catch {
		// Never checked, or unreadable: the same as never checked.
		return undefined;
	}
}

/** Reads a reply's body, giving up past `limit` bytes. */
async function readLimited(response: Response, limit: number): Promise<string | undefined> {
	if (!response.body) return undefined;
	const reader = response.body.getReader();
	const chunks: Uint8Array[] = [];
	let size = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		size += value.byteLength;
		if (size > limit) {
			await reader.cancel().catch(() => undefined);
			return undefined;
		}
		chunks.push(value);
	}
	return Buffer.concat(chunks).toString("utf8");
}

export interface Refreshed {
	/** The latest version known afterwards, if any. */
	latest?: string;
	/** Whether the registry answered just now. */
	fresh: boolean;
}

/**
 * Asks the registry for the latest version, unless it was asked in the last day (answered
 * or not) or checks are off, and keeps the answer. The attempt is written down before it is
 * made, so that failures are not retried at every start and adapters starting together ask
 * once. Never throws: offline, or anything unexpected, leaves the last answer as it was.
 */
export async function refreshLatest(
	home: string,
	options: { fetcher?: typeof fetch; now?: number; force?: boolean; env?: NodeJS.ProcessEnv } = {},
): Promise<Refreshed> {
	if (checkDisabled(options.env ?? process.env)) return { fresh: false };
	const now = options.now ?? Date.now();
	const known = lastChecked(home);
	const kept = { latest: known?.latest, fresh: false };
	if (!options.force && known && now - known.checkedAt >= 0 && now - known.checkedAt < CHECK_INTERVAL_MS) return kept;
	const write = (checked: Checked) => {
		try {
			writeStateFile(home, CACHE, JSON.stringify(checked));
		} catch {
			// The state folder can't be written: the check still answers this once.
		}
	};
	write({ ...known, checkedAt: now });
	try {
		const response = await (options.fetcher ?? fetch)(REGISTRY_URL, {
			headers: { accept: "application/json" },
			redirect: "error",
			signal: AbortSignal.timeout(CHECK_TIMEOUT_MS),
		});
		if (!response.ok) return kept;
		const text = await readLimited(response, MAX_REPLY_BYTES);
		if (text === undefined) return kept;
		const version = (JSON.parse(text) as { version?: unknown }).version;
		if (!isRelease(version)) return kept;
		write({ checkedAt: now, latest: version, answeredAt: now });
		return { latest: version, fresh: true };
	} catch {
		return kept;
	}
}

/** How to update, for the way this copy of Keywright is run. */
export function updateSteps(): string {
	if (viaNpx()) return "run npx -y keywright@latest update, then reconnect Keywright in the AI app";
	if (BUNDLED) return "download keywright.mjs and Keywright.rbxm from https://github.com/Barenton/keywright/releases/latest over the old ones, run node keywright.mjs update in their folder, then reconnect Keywright in the AI app";
	return "in the source checkout, git pull, npm install, npm run build and npm run install:plugin, then reconnect Keywright in the AI app";
}

/** A notice for the agent when a recent check found a release newer than this one. */
export function updateAvailable(home: string, current: string, now = Date.now()): { update_available?: string } {
	const known = lastChecked(home);
	if (!known?.latest || known.answeredAt === undefined || now - known.answeredAt > NOTICE_MAX_AGE_MS) return {};
	if (compareVersions(known.latest, current) <= 0) return {};
	return {
		update_available: `Keywright ${known.latest} is out; this is ${current}. Mention it to the person once, when it suits: to update, ${updateSteps()}. It is not urgent: this version keeps working.`,
	};
}
