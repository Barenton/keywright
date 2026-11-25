import assert from "node:assert/strict";
import { test } from "node:test";
import { boundRead } from "../src/adapter.js";

const pose = (index: number) => ({ joint: "Head", time: index / 10, position: [0, 0, 0], rotation: [0, index, 0], easing_style: "Linear", easing_direction: "In" });
const clip = (poses: number, extra: Record<string, unknown> = {}) => ({
	clip_id: "clip_1",
	revision: "r7",
	keyframe_times: [0, 1, 2],
	markers: [],
	poses: Array.from({ length: poses }, (_, index) => pose(index)),
	poses_total: poses,
	...extra,
});
const bytes = (value: unknown) => Buffer.byteLength(JSON.stringify(value));

test("a read that fits is passed on whole, with no cursor", () => {
	const bounded = boundRead(clip(5), 0, 16384);
	assert.equal((bounded.poses as unknown[]).length, 5);
	assert.equal(bounded.next_cursor, undefined);
});

test("a read that is too long is cut to the budget and says where to carry on", () => {
	const bounded = boundRead(clip(400), 0, 4096);
	const kept = (bounded.poses as unknown[]).length;
	assert.ok(kept > 0 && kept < 400);
	assert.ok(bytes(bounded) <= 4096);
	assert.equal(bounded.next_cursor, `r7:${kept}`);
	// It is the most that fits: one more pose would not.
	assert.ok(bytes({ ...bounded, poses: clip(400).poses.slice(0, kept + 1) }) > 4096);
});

test("a later page counts on from where the cursor was", () => {
	// Studio returned poses 100 to 149 of 300.
	const page = { clip_id: "clip_1", revision: "r7", poses: clip(50).poses, poses_total: 300, next_offset: 150 };
	const bounded = boundRead(page, 100, 16384);
	assert.equal(bounded.next_cursor, "r7:150");
	assert.equal(bounded.next_offset, undefined);
	const last = boundRead({ ...page, poses_total: 150 }, 100, 16384);
	assert.equal(last.next_cursor, undefined);
});

test("at least one pose is returned, so that a read always moves on", () => {
	const bounded = boundRead(clip(10), 0, 64);
	assert.equal((bounded.poses as unknown[]).length, 1);
	assert.equal(bounded.next_cursor, "r7:1");
});

test("a summary that is too long has its lists shortened and marked", () => {
	const markers = Array.from({ length: 500 }, (_, index) => ({ name: `Marker ${index}`, value: "x".repeat(150), time: index }));
	const times = Array.from({ length: 500 }, (_, index) => index / 10);
	const { poses: _poses, poses_total: _total, ...summary } = clip(0, { markers, keyframe_times: times });
	const bounded = boundRead(summary, 0, 16384);
	assert.ok(bytes(bounded) <= 16384);
	assert.equal(bounded.markers_truncated, true);
	assert.ok((bounded.markers as unknown[]).length < 500);
	// The times fitted once the markers were shortened, so they are left whole.
	assert.equal((bounded.keyframe_times as unknown[]).length, 500);
	assert.equal(bounded.keyframe_times_truncated, undefined);
	assert.equal(bounded.poses, undefined);
});

test("a curve clip's keys are cut to the budget the same way as poses", () => {
	const key = (index: number) => ({ joint: "Head", channel: "rotation.y", time: index / 10, value: index, interpolation: "Cubic", in: 0, out: 0 });
	const result = { clip_id: "clip_1", revision: "r4", format: "curves", keys: Array.from({ length: 300 }, (_, index) => key(index)), keys_total: 300 };
	const bounded = boundRead(result, 0, 4096);
	const kept = (bounded.keys as unknown[]).length;
	assert.ok(kept > 0 && kept < 300);
	assert.ok(bytes(bounded) <= 4096);
	assert.equal(bounded.next_cursor, `r4:${kept}`);
	assert.equal(bounded.poses, undefined);
});
