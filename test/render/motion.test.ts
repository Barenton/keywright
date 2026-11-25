import assert from "node:assert/strict";
import { test } from "node:test";
import { inspectPng } from "../../src/render/image.js";
import { type PosePart, parseMotion, renderMotion, renderResult, summariseMotion, trackColours } from "../../src/render/render.js";

type Summary = Record<string, { path: number; net: number; peak_speed: number; peak_time: number; starts: number; stops: number; holds: number[][]; largest_speed_jump: number; bow: number; still?: boolean }>;

const times = Array.from({ length: 21 }, (_, index) => index / 20);
const path = (at: (time: number) => [number, number, number]) => times.map(at);
const motionOf = (parts: Record<string, [number, number, number][]>, keyframes = [0, 0.5, 1]) => parseMotion({ times, keyframes, parts });
const pose: PosePart[] = [{ name: "UpperTorso", size: [2, 2, 1], cframe: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1] }];

test("a part's travel, top speed and when it moves are measured", () => {
	// Still until 0.2, then 4 studs forward at a steady 10 studs a second, then still.
	const straight = path((time) => [0, 0, -Math.min(4, Math.max(0, (time - 0.2) * 10))]);
	const summary = summariseMotion(motionOf({ RightHand: straight })) as Summary;
	const hand = summary.RightHand as Summary[string];
	assert.equal(hand.path, 4);
	assert.equal(hand.net, 4);
	assert.equal(hand.peak_speed, 10);
	assert.equal(hand.starts, 0.2);
	assert.equal(hand.stops, 0.6);
	assert.deepEqual(hand.holds, []);
	assert.equal(hand.bow, 0);
	// It goes from nothing to full speed between one sample and the next: a corner.
	assert.equal(hand.largest_speed_jump, 10);
});

test("where each part comes lowest, and when, is given when the plugin sends it", () => {
	// A foot that dips to its lowest at 0.3 seconds.
	const swing = path((time) => [0, -2.8 + Math.abs(time - 0.3), 0]);
	const lowest = times.map((time) => -3 + Math.abs(time - 0.3));
	const summary = summariseMotion(parseMotion({ times, keyframes: [0, 1], parts: { LeftFoot: swing }, lowest: { LeftFoot: lowest } })) as Record<
		string,
		{ lowest?: number; lowest_time?: number }
	>;
	assert.equal(summary.LeftFoot?.lowest, -3);
	assert.equal(summary.LeftFoot?.lowest_time, 0.3);
	// From a plugin that does not send it, there is none.
	const without = summariseMotion(motionOf({ LeftFoot: swing })) as Record<string, { lowest?: number }>;
	assert.equal(without.LeftFoot?.lowest, undefined);
});

test("a hold in the middle of a move is found, and a curved path is told from a straight one", () => {
	// Out for 0.25 s, still for 0.5 s, back for 0.25 s.
	const held = path((time) => [0, 0, -(time < 0.25 ? time * 8 : time < 0.75 ? 2 : (1 - time) * 8)]);
	const hand = (summariseMotion(motionOf({ RightHand: held })) as Summary).RightHand as Summary[string];
	assert.deepEqual(hand.holds, [[0.25, 0.75]]);
	assert.equal(hand.path, 4);
	assert.equal(hand.net, 0);

	// A half circle of radius 1 bows a full stud from the line between its ends.
	const arc = path((time) => [Math.cos(Math.PI * time), Math.sin(Math.PI * time), 0]);
	const foot = (summariseMotion(motionOf({ LeftFoot: arc })) as Summary).LeftFoot as Summary[string];
	assert.ok(Math.abs(foot.bow - 1) < 0.02, String(foot.bow));
	assert.ok(Math.abs(foot.path - Math.PI) < 0.02);
	assert.equal(foot.net, 2);
	// Its speed is steady, so there is no corner to speak of.
	assert.ok(foot.largest_speed_jump < 0.05, String(foot.largest_speed_jump));
});

test("an eased move has a smaller speed jump than the same move at constant speed", () => {
	const ease = (t: number) => (t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t));
	const linear = (summariseMotion(motionOf({ Head: path((time) => [0, 0, -4 * time]) })) as Summary).Head as Summary[string];
	const eased = (summariseMotion(motionOf({ Head: path((time) => [0, 0, -4 * ease(time)]) })) as Summary).Head as Summary[string];
	assert.equal(linear.path, eased.path);
	assert.ok(eased.peak_speed > linear.peak_speed);
	assert.ok(Math.abs(eased.peak_time - 0.5) < 0.06);
	// Steady speed has no jumps once under way; easing changes speed a little at every step.
	assert.ok(eased.largest_speed_jump > 0 && eased.largest_speed_jump < eased.peak_speed / 4);
});

test("a part that never moves is reported as still", () => {
	const summary = summariseMotion(motionOf({ LowerTorso: path(() => [0, -1, 0]) })) as Summary;
	assert.deepEqual(summary.LowerTorso, { path: 0, still: true });
});

test("motion from a plugin is checked before it is used", () => {
	const good = { times: [0, 0.5, 1], keyframes: [0, 1], parts: { Head: [[0, 0, 0], [0, 1, 0], [0, 2, 0]] } };
	assert.equal(parseMotion(good).parts.length, 1);
	assert.throws(() => parseMotion({ ...good, times: [0, 1, 0.5] }), /order of time/);
	assert.throws(() => parseMotion({ ...good, times: [0] }), /number of samples/);
	assert.throws(() => parseMotion({ ...good, parts: { Head: [[0, 0, 0]] } }), /not usable/);
	assert.throws(() => parseMotion({ ...good, parts: { Head: [[0, 0, 0], [0, Number.NaN, 0], [0, 2, 0]] } }), /not usable/);
	assert.throws(() => parseMotion({ ...good, parts: {} }), /number of parts/);
	assert.throws(() => parseMotion({ ...good, parts: Object.fromEntries(Array.from({ length: 9 }, (_, index) => [`P${index}`, good.parts.Head])) }), /number of parts/);
	assert.throws(() => parseMotion(null), /no motion/);
});

test("the motion is drawn as a path over the rig beside a chart of speeds", () => {
	const motion = motionOf({ LeftHand: path((time) => [-1.5, time * 2, 0]), RightHand: path(() => [1.5, 0, 0]) });
	const drawn = renderMotion(motion, pose, "front", 256);
	assert.deepEqual([drawn.width, drawn.height], [256 * 3, 256]);
	assert.deepEqual(inspectPng(drawn.png), { width: 768, height: 256 });
	assert.deepEqual(trackColours(motion), [
		{ part: "LeftHand", colour: "red" },
		{ part: "RightHand", colour: "blue" },
	]);
	// The same motion always gives the same picture, and a different one a different picture.
	assert.deepEqual(renderMotion(motion, pose, "front", 256).png, drawn.png);
	const other = motionOf({ LeftHand: path((time) => [-1.5, time, 0]), RightHand: path(() => [1.5, 0, 0]) });
	assert.notDeepEqual(renderMotion(other, pose, "front", 256).png, drawn.png);
});

test("a preview's motion is summarised in its text and its raw positions are never passed on", () => {
	const raw = { times, keyframes: [0, 1], parts: { RightHand: path((time) => [0, 0, -4 * time]) } };
	const plain = renderResult({ samples: 21 }, { clip_id: "clip_1", motion: raw, pose: { parts: pose } });
	const text = plain.payload as { motion: { samples: number; parts: Summary }; pose?: unknown };
	assert.equal(plain.image, undefined);
	assert.equal(text.pose, undefined);
	assert.equal(text.motion.samples, 21);
	assert.equal((text.motion.parts.RightHand as Summary[string]).path, 4);
	assert.equal(JSON.stringify(text).includes("positions"), false);
	assert.ok(JSON.stringify(text).length < 600);

	const drawn = renderResult({ samples: 21, render: true, views: ["left"] }, { clip_id: "clip_1", motion: raw, pose: { parts: pose } });
	const shown = drawn.payload as { render: { status: string; rows: unknown[]; layout: string } };
	assert.ok(drawn.image);
	assert.equal(shown.render.status, "ok");
	assert.deepEqual(shown.render.rows, [{ part: "RightHand", colour: "red" }]);
	assert.match(shown.render.layout, /dots far apart mean fast/);

	// Motion that is not in the expected form is reported, not drawn or passed on.
	const bad = renderResult({ samples: 21, render: true }, { clip_id: "clip_1", motion: { times: [0], parts: {} }, pose: { parts: pose } });
	assert.equal((bad.payload as { motion: { status: string } }).motion.status, "unavailable");
});
