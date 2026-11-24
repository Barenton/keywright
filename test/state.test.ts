import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { loadOrCreateSecret, stateDir } from "../src/state.js";

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
