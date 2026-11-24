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
	judge(id: string, question: string, measured: unknown, limit: number, unit: string): { verdict: string; measured: unknown };
}

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
	assert.deepEqual(imports, ["node:fs", "node:path", "node:url"]);
	// It loads only this project's own compiled relay code.
	const loaded = [...source.matchAll(/import\(pathToFileURL\(join\(ROOT, "([^"]+)"\)\)\.href\)/g)].map((match) => match[1]).sort();
	assert.deepEqual(loaded, ["dist/src/client.js", "dist/src/render.js", "dist/src/state.js"]);
	assert.equal(source.split("import(").length - 1, loaded.length);
	assert.doesNotMatch(source, /child_process|\bexec|spawn|RobloxStudio|taskkill|fetch\(|https?:\/\//);
	// It writes one kind of file, under build/.
	assert.deepEqual([...source.matchAll(/writeFileSync\(([^,]+),/g)].map((match) => match[1]), ["file"]);
	assert.match(source, /join\(ROOT, "build", "measurements"\)/);
	// It will not run without being told which place, and refuses any other.
	assert.match(source, /candidate\.placeId === options\.placeId/);
	assert.match(source, /Give the id of the place to measure in/);
});
