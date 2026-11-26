import assert from "node:assert/strict";
import { test } from "node:test";
import { measureAll, measureResult, momentsOf, trackFor } from "../../src/render/measure.js";

test("the parts measured are tracked as well as those named, keeping the default parts with samples", () => {
	const measures = [{ part: "RightHand", relative_to: "Head", along: "forward" as const }];
	assert.deepEqual(trackFor(measures, ["LeftFoot"], false), ["LeftFoot", "RightHand", "Head"]);
	assert.deepEqual(trackFor(measures, undefined, false), ["RightHand", "Head"]);
	const sampled = trackFor(measures, undefined, true);
	assert.ok(sampled.includes("LowerTorso") && sampled.includes("LeftHand"), "the plugin's default parts stay");
	assert.equal(sampled.filter((name) => name === "Head").length, 1, "no part twice");
});

test("forward is the rig's negative Z, measured from another part or from the root", () => {
	const moments = [
		{ time: 0, positions: { RightHand: [1, 1, -0.5] as [number, number, number], Head: [0, 2, 0.25] as [number, number, number] } },
		{ time: 0.1, positions: { RightHand: [1, 1.5, -2] as [number, number, number], Head: [0, 2, 0] as [number, number, number] } },
	];
	const [reach, height, apart] = measureAll(
		[
			{ part: "RightHand", relative_to: "Head", along: "forward" },
			{ part: "RightHand", along: "up" },
			{ part: "RightHand", relative_to: "Head", along: "distance" },
		],
		moments,
	) as Array<Record<string, unknown>>;
	assert.deepEqual(reach?.values, [[0, 0.75], [0.1, 2]]);
	assert.deepEqual(reach?.greatest, { value: 2, time: 0.1 });
	assert.deepEqual(reach?.least, { value: 0.75, time: 0 });
	assert.equal(reach?.change, 1.25);
	assert.equal(height?.relative_to, "root");
	assert.deepEqual(height?.values, [[0, 1], [0.1, 1.5]]);
	assert.equal((apart?.values as number[][])[1]?.[1], Math.round(Math.hypot(1, 0.5, 2) * 1000) / 1000);
});

test("positions are read from sampled motion, from frames and from a single pose", () => {
	const fromMotion = momentsOf({ motion: { times: [0, 0.5], parts: { LowerTorso: [[0, -1, 0], [0, -1.2, 0]] } } });
	assert.deepEqual(fromMotion.map((moment) => moment.positions.LowerTorso?.[1]), [-1, -1.2]);
	const fromFrames = momentsOf({ frames: [{ time: 0.2, parts: { LeftFoot: { position: [0, -3, 1] } } }] });
	assert.deepEqual(fromFrames, [{ time: 0.2, positions: { LeftFoot: [0, -3, 1] } }]);
	const single = momentsOf({ time: 0.3, parts: { Head: { position: [0, 2, 0] } } });
	assert.equal(single[0]?.time, 0.3);
});

test("a preview's result gains measured only when measurements were asked for, and says when parts are missing", () => {
	const payload = { frames: [{ time: 0, parts: { LeftFoot: { position: [0, -3, 0] } } }] };
	assert.equal(measureResult({}, payload), payload);
	const result = measureResult({ measure: [{ part: "RightFoot", along: "up" }] }, payload) as { measured: Array<Record<string, unknown>> };
	assert.equal(result.measured[0]?.status, "unavailable");
});
