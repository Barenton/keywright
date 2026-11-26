import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { CHECK_INTERVAL_MS, lastChecked, MAX_REPLY_BYTES, NOTICE_MAX_AGE_MS, REGISTRY_URL, refreshLatest, updateAvailable } from "../src/updates.js";

function home(): string {
	return mkdtempSync(join(tmpdir(), "keywright-updates-"));
}

/** A registry answering with `body`, recording each request and the options it came with. */
function registry(body: unknown, status = 200) {
	const asked: Array<{ url: string; init?: RequestInit }> = [];
	const fetcher = (async (url: string | URL | Request, init?: RequestInit) => {
		asked.push({ url: String(url), init });
		return new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
	}) as typeof fetch;
	return { asked, fetcher };
}

const enabled = {} as NodeJS.ProcessEnv;
const withDir = async (run: (dir: string) => Promise<void> | void) => {
	const dir = home();
	try {
		await run(dir);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
};

test("the registry is asked at most once a day, refusing redirects, and its answer kept", () =>
	withDir(async (dir) => {
		const npm = registry({ version: "9.1.0" });
		assert.deepEqual(await refreshLatest(dir, { fetcher: npm.fetcher, now: 1_000, env: enabled }), { latest: "9.1.0", fresh: true });
		assert.equal(npm.asked[0]?.url, REGISTRY_URL);
		assert.equal(npm.asked[0]?.init?.redirect, "error", "a redirect elsewhere is not followed");
		assert.deepEqual(lastChecked(dir), { checkedAt: 1_000, latest: "9.1.0", answeredAt: 1_000 });
		assert.deepEqual(await refreshLatest(dir, { fetcher: npm.fetcher, now: 1_000 + CHECK_INTERVAL_MS - 1, env: enabled }), { latest: "9.1.0", fresh: false });
		assert.equal(npm.asked.length, 1, "not again within the day");
		await refreshLatest(dir, { fetcher: npm.fetcher, now: 1_000 + CHECK_INTERVAL_MS, env: enabled });
		assert.equal(npm.asked.length, 2, "again after it");
		await refreshLatest(dir, { fetcher: npm.fetcher, now: 1_000 + CHECK_INTERVAL_MS, env: enabled, force: true });
		assert.equal(npm.asked.length, 3, "and whenever asked to");
	}));

test("a check that fails counts as the day's check too", () =>
	withDir(async (dir) => {
		const down = registry({}, 503);
		assert.deepEqual(await refreshLatest(dir, { fetcher: down.fetcher, now: 0, env: enabled }), { latest: undefined, fresh: false });
		await refreshLatest(dir, { fetcher: down.fetcher, now: 60_000, env: enabled });
		assert.equal(down.asked.length, 1, "not retried at the next start");
	}));

test("with checks turned off, nothing is asked", () =>
	withDir(async (dir) => {
		const npm = registry({ version: "9.1.0" });
		assert.deepEqual(await refreshLatest(dir, { fetcher: npm.fetcher, env: { KEYWRIGHT_NO_UPDATE_CHECK: "1" }, force: true }), { fresh: false });
		assert.equal(npm.asked.length, 0);
	}));

test("an answer that fails, is too big, or is not a plain release leaves the last one", () =>
	withDir(async (dir) => {
		await refreshLatest(dir, { fetcher: registry({ version: "1.2.3" }).fetcher, now: 0, env: enabled });
		const huge = JSON.stringify({ version: "2.0.0", readme: "x".repeat(MAX_REPLY_BYTES) });
		for (const npm of [registry({ version: "not a version" }), registry({ version: "2.0.0" }, 500), registry({ version: { evil: true } }), registry({ version: "9.0.0-Run.install.sh.now" }), registry(huge), registry("{ not json")]) {
			assert.deepEqual(await refreshLatest(dir, { fetcher: npm.fetcher, now: 0, env: enabled, force: true }), { latest: "1.2.3", fresh: false });
		}
		const offline = (async () => {
			throw new Error("offline");
		}) as typeof fetch;
		assert.deepEqual(await refreshLatest(dir, { fetcher: offline, now: 0, env: enabled, force: true }), { latest: "1.2.3", fresh: false });
		assert.equal(lastChecked(dir)?.latest, "1.2.3");
	}));

test("only a small, ordinary file is read as the last check", () =>
	withDir((dir) => {
		writeFileSync(join(dir, "release-check.json"), JSON.stringify({ checkedAt: 0, latest: "1.0.0", answeredAt: 0, padding: "x".repeat(5000) }));
		assert.equal(lastChecked(dir), undefined, "too big");
		if (process.platform !== "win32") {
			rmSync(join(dir, "release-check.json"));
			// A pipe with no writer would block a read for ever.
			execFileSync("mkfifo", [join(dir, "release-check.json")]);
			assert.equal(lastChecked(dir), undefined, "not a file");
		}
	}));

test("the agent is told only of a recently seen release newer than this one", () =>
	withDir((dir) => {
		const now = 10 * NOTICE_MAX_AGE_MS;
		const seen = (latest: string, answeredAt = now) => writeFileSync(join(dir, "release-check.json"), JSON.stringify({ checkedAt: answeredAt, latest, answeredAt }));
		assert.deepEqual(updateAvailable(dir, "0.6.0", now), {}, "never checked");
		seen("0.6.0");
		assert.deepEqual(updateAvailable(dir, "0.6.0", now), {});
		assert.deepEqual(updateAvailable(dir, "0.7.0", now), {}, "an older release is not news");
		seen("0.7.0");
		assert.match(updateAvailable(dir, "0.6.0", now).update_available ?? "", /Keywright 0\.7\.0 is out; this is 0\.6\.0\. Mention it to the person once.*not urgent/);
		seen("0.7.0", now - NOTICE_MAX_AGE_MS - 1);
		assert.deepEqual(updateAvailable(dir, "0.6.0", now), {}, "an answer too old to trust is not passed on");
	}));
