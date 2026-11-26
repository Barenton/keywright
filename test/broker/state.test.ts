import assert from "node:assert/strict";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { loadOrCreateSecret, saveCredentials, stateDir } from "../../src/broker/state.js";

// The directory convention tested here is the one for Linux; the others differ only in
// where the per-user directory is.
const linux = process.platform !== "win32" && process.platform !== "darwin";
const former = ["motion", "bridge"].join("-");

test("a state directory from before the rename is taken over once", { skip: !linux }, () => {
	const config = mkdtempSync(join(tmpdir(), "keywright-state-"));
	try {
		const env = { XDG_CONFIG_HOME: config };
		mkdirSync(join(config, former));
		const secret = loadOrCreateSecret(join(config, former));
		writeFileSync(join(config, former, "credentials.json"), "{}");

		const dir = stateDir(env);
		assert.equal(dir, join(config, "keywright"));
		assert.equal(existsSync(join(config, former)), false);
		// The secret and the credentials came along, so a pairing still works.
		assert.deepEqual(loadOrCreateSecret(dir), secret);
		assert.equal(readFileSync(join(dir, "credentials.json"), "utf8"), "{}");

		// Asking again changes nothing, and a former directory that reappears is left alone.
		mkdirSync(join(config, former));
		assert.equal(stateDir(env), dir);
		assert.equal(existsSync(join(config, former)), true);
		assert.deepEqual(loadOrCreateSecret(dir), secret);
	} finally {
		rmSync(config, { recursive: true, force: true });
	}
});

test("with nothing from before, the new directory is simply named", { skip: !linux }, () => {
	const config = mkdtempSync(join(tmpdir(), "keywright-state-"));
	try {
		assert.equal(stateDir({ XDG_CONFIG_HOME: config }), join(config, "keywright"));
		// Naming it does not create it.
		assert.equal(existsSync(join(config, "keywright")), false);
		assert.equal(stateDir({ KEYWRIGHT_HOME: "/somewhere/else" }), "/somewhere/else");
	} finally {
		rmSync(config, { recursive: true, force: true });
	}
});

test("a secret restored with loose permissions is closed to other users before it is used", { skip: process.platform === "win32" }, () => {
	const home = mkdtempSync(join(tmpdir(), "keywright-state-"));
	try {
		const dir = join(home, "state");
		mkdirSync(dir, { mode: 0o755 });
		chmodSync(dir, 0o755);
		writeFileSync(join(dir, "secret"), "a".repeat(64), { mode: 0o644 });
		chmodSync(join(dir, "secret"), 0o644);
		assert.equal(loadOrCreateSecret(dir).toString("hex"), "a".repeat(64));
		assert.equal(statSync(join(dir, "secret")).mode & 0o777, 0o600);
		assert.equal(statSync(dir).mode & 0o777, 0o700);
	} finally {
		rmSync(home, { recursive: true, force: true });
	}
});

test("a state file is not written through a link left at its temporary path", { skip: process.platform === "win32" }, () => {
	const root = mkdtempSync(join(tmpdir(), "keywright-link-"));
	try {
		const home = join(root, "home");
		const elsewhere = join(root, "elsewhere");
		writeFileSync(elsewhere, "untouched", { mode: 0o644 });
		mkdirSync(home, { mode: 0o700 });
		symlinkSync(elsewhere, join(home, `credentials.json.${process.pid}.tmp`));
		saveCredentials(home, "fingerprint", { abc: { key: "00", createdAt: "now" } });
		assert.equal(readFileSync(elsewhere, "utf8"), "untouched");
		assert.ok(lstatSync(join(home, "credentials.json")).isFile(), "the file itself, not a link");
		assert.equal(statSync(join(home, "credentials.json")).mode & 0o777, 0o600);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});
