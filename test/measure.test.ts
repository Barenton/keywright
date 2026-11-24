import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

interface Sampled {
	rotation: number[];
	position: number[];
}
interface MeasureModule {
	percentile(values: number[], share: number): number;
	angleBetween(a: number, b: number): number;
	largestDifference(first: Record<string, Sampled>, second: Record<string, Sampled>): { degrees: number; studs: number; compared: number };
	largestPartDifference(first: Placed[], second: Placed[]): { degrees: number; studs: number; compared: number };
	largeRotation(keyframe: number, joint: number): number[];
	referenceOperations(keyframes: number): Array<{ type: string; joint: string; time: number; rotation: number[] }>;
	nineDigits(value: number): string;
	eulerRotation(degrees: number[]): number[];
	composedRotation(rotations: number[][]): number[];
	headPoseFingerprint(numbers: string[]): string;
	recoverPose(fingerprint: string, position: number[], rotation: number[], reach?: number): number[] | undefined;
	VECTORS: Array<{ name: string; steps: Array<{ rotation: number[]; position?: number[] }> }>;
	judge(id: string, question: string, measured: unknown, limit: number, unit: string): { verdict: string; measured: unknown };
}

type Placed = { name: string; cframe: number[] };
const SCRIPT = fileURLToPath(new URL("../../scripts/measure.mjs", import.meta.url));
const measure = (await import(new URL("../../scripts/measure.mjs", import.meta.url).href)) as MeasureModule;

test("a percentile is the value the given share of the numbers fall below", () => {
	const values = Array.from({ length: 100 }, (_, index) => index + 1);
	assert.equal(measure.percentile(values, 0.95), 95);
	assert.equal(measure.percentile(values, 0.5), 50);
	assert.equal(measure.percentile(values, 1), 100);
	assert.equal(measure.percentile([7], 0.95), 7);
	assert.equal(measure.percentile([3, 1, 2], 0.95), 3);
	assert.ok(Number.isNaN(measure.percentile([], 0.95)));
});

test("angles are compared by the smallest turn between them", () => {
	assert.equal(measure.angleBetween(10, 12), 2);
	assert.equal(measure.angleBetween(179, -179), 2);
	assert.equal(measure.angleBetween(-180, 180), 0);
	assert.equal(measure.angleBetween(0, 360), 0);
	assert.equal(measure.angleBetween(350, 10), 20);
});

test("the largest difference is found across every joint and axis", () => {
	const first = {
		Head: { rotation: [0, 35, 0], position: [0, 0, 0] },
		UpperTorso: { rotation: [10, 0, 0], position: [0, 0.125, 0] },
	};
	const same = structuredClone(first);
	assert.deepEqual(measure.largestDifference(first, same), { degrees: 0, studs: 0, compared: 2 });
	const moved = structuredClone(first);
	(moved.Head.rotation as number[])[1] = 35.004;
	(moved.UpperTorso.position as number[])[1] = 0.1255;
	const difference = measure.largestDifference(first, moved);
	assert.ok(Math.abs(difference.degrees - 0.004) < 1e-9);
	assert.ok(Math.abs(difference.studs - 0.0005) < 1e-9);
	// A joint that did not come back is not silently counted as agreeing.
	assert.equal(measure.largestDifference(first, { Head: first.Head }).compared, 1);
});

test("a result passes only on a finite number within its limit", () => {
	assert.equal(measure.judge("E4", "q", 0.001, 0.01, "degrees").verdict, "pass");
	assert.equal(measure.judge("E4", "q", 0.01, 0.01, "degrees").verdict, "pass");
	assert.equal(measure.judge("E4", "q", 0.02, 0.01, "degrees").verdict, "fail");
	assert.equal(measure.judge("E4", "q", Number.NaN, 0.01, "degrees").verdict, "fail");
	assert.equal(measure.judge("E4", "q", undefined, 0.01, "degrees").verdict, "fail");
	assert.equal(measure.judge("E4", "q", Number.POSITIVE_INFINITY, 0.01, "degrees").verdict, "fail");
});

test("the measuring script reaches Studio only through the local broker", () => {
	const source = readFileSync(SCRIPT, "utf8");
	const imports = [...source.matchAll(/^import .* from "([^"]+)";$/gm)].map((match) => match[1]).sort();
	// node:crypto is for hashing only: the script works out fingerprints itself.
	assert.deepEqual(imports, ["node:crypto", "node:fs", "node:path", "node:url"]);
	assert.deepEqual([...source.matchAll(/import \{ ([^}]+) \} from "node:crypto";/g)].map((match) => match[1]), ["createHash"]);
	// It loads only this project's own compiled relay code.
	const loaded = [...source.matchAll(/import\(pathToFileURL\(join\(ROOT, "([^"]+)"\)\)\.href\)/g)].map((match) => match[1]).sort();
	assert.deepEqual(loaded, ["dist/src/client.js", "dist/src/render.js", "dist/src/state.js"]);
	assert.equal(source.split("import(").length - 1, loaded.length);
	assert.doesNotMatch(source, /child_process|\bexec|spawn|RobloxStudio|taskkill|fetch\(|https?:\/\//);
	// It writes two files, both under build/measurements.
	assert.deepEqual([...source.matchAll(/writeFileSync\(([^,]+),/g)].map((match) => match[1]), ["file", "vectorsFile"]);
	assert.match(source, /const directory = join\(ROOT, "build", "measurements"\)/);
	assert.match(source, /const file = join\(directory, /);
	assert.match(source, /const vectorsFile = join\(directory, /);
	// It will not run without being told which place, and refuses any other.
	assert.match(source, /candidate\.placeId === options\.placeId/);
	assert.match(source, /Give the id of the place to measure in/);
});

test("parts are compared by distance and by the turn between their rotations", () => {
	const upright = [1, 2, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1];
	// A quarter turn about the vertical axis, moved 3 and 4 studs sideways: 5 studs away.
	const turned = [4, 2, 7, 0, 0, 1, 0, 1, 0, -1, 0, 0];
	const first = [
		{ name: "Head", cframe: upright },
		{ name: "LeftHand", cframe: upright },
	];
	assert.deepEqual(measure.largestPartDifference(first, first), { degrees: 0, studs: 0, compared: 2 });

	const difference = measure.largestPartDifference(first, [{ name: "Head", cframe: turned }]);
	assert.equal(difference.compared, 1);
	assert.ok(Math.abs(difference.studs - 5) < 1e-9);
	assert.ok(Math.abs(difference.degrees - 90) < 1e-9);

	// Numbers rounded to four places, as the plugin sends them, must not turn a
	// difference of a few thousandths of a degree into a large one.
	const about = (degrees: number) => {
		const angle = (degrees * Math.PI) / 180;
		const round = (value: number) => Math.round(value * 10000) / 10000;
		return [0, 0, 0, round(Math.cos(angle)), round(-Math.sin(angle)), 0, round(Math.sin(angle)), round(Math.cos(angle)), 0, 0, 0, 1];
	};
	const near = measure.largestPartDifference([{ name: "Head", cframe: about(60.003) }], [{ name: "Head", cframe: about(60) }]);
	assert.ok(near.degrees < 0.01, String(near.degrees));
	const half = measure.largestPartDifference([{ name: "Head", cframe: about(60.5) }], [{ name: "Head", cframe: about(60) }]);
	assert.ok(Math.abs(half.degrees - 0.5) < 0.01, String(half.degrees));
});

test("the large clip's rotations are one axis each, inside a quarter turn, and vary", () => {
	const seen = new Set<string>();
	for (let keyframe = 0; keyframe < 714; keyframe += 1) {
		for (let joint = 0; joint < 15; joint += 1) {
			const rotation = measure.largeRotation(keyframe, joint);
			assert.equal(rotation.filter((angle) => angle !== 0).length, 1);
			assert.ok(rotation.every((angle) => Math.abs(angle) < 85));
			assert.notEqual(rotation[joint % 3], 0);
			seen.add(rotation.join());
		}
	}
	assert.ok(seen.size > 100);
});

test("numbers are written to nine digits the way Luau writes them", () => {
	assert.equal(measure.nineDigits(0), "0");
	assert.equal(measure.nineDigits(-0), "-0");
	assert.equal(measure.nineDigits(1), "1");
	assert.equal(measure.nineDigits(-0.5), "-0.5");
	assert.equal(measure.nineDigits(Math.fround(Math.cos(Math.PI / 6))), "0.866025388");
	assert.equal(measure.nineDigits(-4.371138828673793e-8), "-4.37113883e-08");
	assert.equal(measure.nineDigits(1.5e-5), "1.5e-05");
	assert.equal(measure.nineDigits(0.0001), "0.0001");
	assert.equal(measure.nineDigits(123456789012), "1.23456789e+11");
});

// What Studio reported on 2026-11-24 for a blank working copy given one pose: the head
// turned 30 degrees about Y at one second.
const HEAD_30 = "5f101e90990c3f061d6eee2d1a353ddbc8477999e56122384806795cd3b7d220";

test("Studio's numbers for a pose are recovered from its fingerprint", () => {
	const recovered = measure.recoverPose(HEAD_30, [0, 0, 0], measure.eulerRotation([0, 30, 0]));
	assert.deepEqual(recovered?.map(measure.nineDigits), ["0", "0", "0", "0.866025388", "0", "0.5", "0", "1", "0", "-0.5", "0", "0.866025388"]);
	// A fingerprint that belongs to no nearby numbers is not explained away.
	assert.equal(measure.recoverPose("0".repeat(64), [0, 0, 0], measure.eulerRotation([0, 30, 0])), undefined);
	// Lune's less exact value for the same pose has a different fingerprint.
	const lune = ["0", "0", "0", "0.866027832", "0", "0.5", "0", "1", "0", "-0.5", "0", "0.866027832"];
	assert.notEqual(measure.headPoseFingerprint(lune), HEAD_30);
});

test("every recorded Studio vector hashes to the fingerprint Studio gave", () => {
	const recorded = JSON.parse(readFileSync(fileURLToPath(new URL("../../plugin/test/studio-vectors.json", import.meta.url)), "utf8")) as {
		vectors: Array<{ name: string; steps: Array<{ rotation: number[]; position?: number[] }>; fingerprint: string; studio: number[] }>;
	};
	assert.deepEqual(
		recorded.vectors.map(({ name, steps }) => ({ name, steps })),
		measure.VECTORS,
	);
	for (const vector of recorded.vectors) {
		assert.equal(vector.studio.length, 12, vector.name);
		assert.equal(measure.headPoseFingerprint(vector.studio.map(measure.nineDigits)), vector.fingerprint, vector.name);
		// And each is within a few single-precision steps of the true rotation.
		const exact = measure.composedRotation(vector.steps.map((step) => step.rotation));
		vector.studio.slice(3).forEach((value, index) => assert.ok(Math.abs(value - (exact[index] as number)) < 1e-6, vector.name));
	}
});

test("the reference clips have the sizes the requirements give them", () => {
	const small = measure.referenceOperations(31);
	const long = measure.referenceOperations(301);
	assert.equal(small.length, 465);
	assert.equal(long.length, 4515);
	assert.equal(new Set(small.map((operation) => operation.joint)).size, 15);
	assert.equal(Math.max(...small.map((operation) => operation.time)), 3);
	assert.equal(Math.max(...long.map((operation) => operation.time)), 30);
	// The same every time: a fixture, not a random clip.
	assert.deepEqual(measure.referenceOperations(31), small);
});
