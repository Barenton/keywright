import assert from "node:assert/strict";
import { test } from "node:test";
import { Broker } from "../../src/broker/broker.js";
import { compareVersions, ensureBroker } from "../../src/broker/launcher.js";
import { readBrokerState } from "../../src/broker/state.js";
import { VERSION } from "../../src/version.js";
import { freePort, isAlive, tempHome, waitFor } from "../helpers.js";

test("versions are ordered by their numbers", () => {
	assert.equal(compareVersions("0.1.0", "0.1.0"), 0);
	assert.equal(compareVersions("0.2.0", "0.10.0"), -1);
	assert.equal(compareVersions("1.0.0", "0.99.99"), 1);
	assert.equal(compareVersions("0.2.0-beta.1", "0.2.0"), -1);
	assert.equal(compareVersions("0.2.0-beta.2", "0.2.0-beta.1"), 1);
	// Pre-release fields compare as semantic versioning says: numbers by value, below words.
	assert.equal(compareVersions("0.2.0-beta.10", "0.2.0-beta.2"), 1);
	assert.equal(compareVersions("0.2.0-beta.2", "0.2.0-beta.10"), -1);
	assert.equal(compareVersions("0.2.0-1", "0.2.0-alpha"), -1);
	assert.equal(compareVersions("0.2.0-alpha", "0.2.0-alpha.1"), -1);
	assert.equal(compareVersions("0.2.0-rc.1", "0.2.0-rc.1"), 0);
	assert.equal(compareVersions("", "0.0.1"), -1, "a broker from before releases is older than any");
	assert.equal(compareVersions("", ""), 0);
});

async function status(client: Awaited<ReturnType<typeof ensureBroker>>): Promise<{ pid: number; version: string }> {
	return (await client.request("broker.status")) as { pid: number; version: string };
}

test("a broker from an older release is replaced by one of this release", async () => {
	const temp = tempHome();
	const port = await freePort();
	const old = new Broker({ home: temp.home, port, version: "0.0.1" });
	await old.start();
	let spawned: number | undefined;
	try {
		const client = await ensureBroker({ home: temp.home, port });
		const now = await status(client);
		client.close();
		spawned = now.pid;
		assert.equal(now.version, VERSION);
		assert.notEqual(now.pid, process.pid, "the old broker, in this process, has stopped");
		assert.equal(readBrokerState(temp.home)?.version, VERSION);
	} finally {
		await old.stop();
		if (spawned !== undefined && isAlive(spawned)) {
			process.kill(spawned, "SIGTERM");
			await waitFor(() => !isAlive(spawned as number));
		}
		temp.cleanup();
	}
});

test("a broker of a newer release, or one only asked about, is kept", async () => {
	const temp = tempHome();
	const port = await freePort();
	const newer = new Broker({ home: temp.home, port, version: "999.0.0" });
	await newer.start();
	try {
		const client = await ensureBroker({ home: temp.home, port });
		const kept = await status(client);
		client.close();
		assert.deepEqual([kept.pid, kept.version], [process.pid, "999.0.0"]);
	} finally {
		await newer.stop();
	}
	const older = new Broker({ home: temp.home, port, version: "0.0.1" });
	await older.start();
	try {
		const client = await ensureBroker({ home: temp.home, port, autoStart: false });
		assert.equal((await status(client)).version, "0.0.1");
		client.close();
	} finally {
		await older.stop();
		temp.cleanup();
	}
});
