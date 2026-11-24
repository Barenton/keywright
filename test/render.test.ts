import assert from "node:assert/strict";
import { test } from "node:test";
import { inflateSync } from "node:zlib";
import { inspectPng } from "../src/image.js";
import { DEFAULT_TILE, LEGEND, MAX_PARTS, type PosePart, parsePose, renderPose, renderResult, type ViewName } from "../src/render.js";

type Pixel = [number, number, number];
const BACKGROUND: Pixel = [245, 245, 245];

/** A part that is not turned: position, then the identity rotation. */
function box(name: string, position: [number, number, number], size: [number, number, number] = [1, 1, 1]): PosePart {
	return { name, size, cframe: [...position, 1, 0, 0, 0, 1, 0, 0, 0, 1] };
}

/** Decodes a PNG the renderer made back into pixels, by the format's own rules. */
function decode(png: Buffer): { width: number; height: number; at: (x: number, y: number) => Pixel } {
	const { width, height } = inspectPng(png);
	const data: Buffer[] = [];
	for (let offset = 8; offset < png.length; ) {
		const length = png.readUInt32BE(offset);
		if (png.toString("latin1", offset + 4, offset + 8) === "IDAT") data.push(png.subarray(offset + 8, offset + 8 + length));
		offset += 12 + length;
	}
	const rows = inflateSync(Buffer.concat(data));
	const stride = width * 3 + 1;
	return {
		width,
		height,
		at: (x, y) => {
			assert.equal(rows[y * stride], 0, "the renderer writes unfiltered rows");
			const start = y * stride + 1 + x * 3;
			return [rows[start] as number, rows[start + 1] as number, rows[start + 2] as number];
		},
	};
}

const isBackground = (pixel: Pixel) => pixel.every((channel, index) => channel === BACKGROUND[index]);
/** Orange is the rig's right side, blue its left, by which channel dominates. */
const isOrange = (pixel: Pixel) => !isBackground(pixel) && pixel[0] > pixel[2] + 30;
const isBlue = (pixel: Pixel) => !isBackground(pixel) && pixel[2] > pixel[0] + 30;
const isGrey = (pixel: Pixel) => !isBackground(pixel) && Math.abs(pixel[0] - pixel[2]) < 8 && pixel[0] > 70;

function draw(parts: PosePart[], view: ViewName, tile = 128) {
	return decode(renderPose(parts, [view], tile).png);
}

/** The smallest rectangle of the picture that is not background. */
function extent(image: ReturnType<typeof decode>) {
	let left = Infinity;
	let right = -Infinity;
	let top = Infinity;
	let bottom = -Infinity;
	for (let y = 0; y < image.height; y += 1) {
		for (let x = 0; x < image.width; x += 1) {
			if (isBackground(image.at(x, y))) continue;
			left = Math.min(left, x);
			right = Math.max(right, x);
			top = Math.min(top, y);
			bottom = Math.max(bottom, y);
		}
	}
	return { left, right, top, bottom, width: right - left + 1, height: bottom - top + 1 };
}

test("a pose is drawn as a valid PNG of the size asked for", () => {
	const drawn = renderPose([box("UpperTorso", [0, 0, 0], [2, 2, 1])], ["front"], 128);
	assert.deepEqual(inspectPng(drawn.png), { width: 128, height: 128 });
	assert.equal(drawn.width, 128);
	assert.equal(drawn.height, 128);
	const image = decode(drawn.png);
	assert.ok(isGrey(image.at(64, 64)), `centre ${image.at(64, 64)}`);
	assert.ok(isBackground(image.at(2, 2)));
	assert.ok(isBackground(image.at(125, 125)));
});

test("the same pose always gives the same bytes, and a different pose different ones", () => {
	const pose = [box("UpperTorso", [0, 0, 0], [2, 2, 1]), box("RightHand", [2, 1, 0])];
	const first = renderPose(pose, ["three_quarter", "front"], 160).png;
	const again = renderPose(structuredClone(pose), ["three_quarter", "front"], 160).png;
	assert.ok(first.equals(again));
	const moved = renderPose([pose[0] as PosePart, box("RightHand", [2, 1.5, 0])], ["three_quarter", "front"], 160).png;
	assert.ok(!first.equals(moved));
});

test("the rig's sides are told apart by colour and land where a viewer expects them", () => {
	// A rig faces along its own negative Z, with its right side towards positive X.
	const pose = [box("LeftHand", [-3, 0, 0]), box("RightHand", [3, 0, 0])];
	const front = draw(pose, "front");
	assert.ok(isOrange(front.at(20, 64)), "facing the rig, its right hand is on the viewer's left");
	assert.ok(isBlue(front.at(107, 64)));
	const back = draw(pose, "back");
	assert.ok(isBlue(back.at(20, 64)), "from behind, its left hand is on the viewer's left");
	assert.ok(isOrange(back.at(107, 64)));
	const top = draw(pose, "top");
	assert.ok(isBlue(top.at(20, 64)), "from above with its front upwards, left is on the left");
	assert.ok(isOrange(top.at(107, 64)));
	// From its own right side only the right hand can be seen; the left one is behind it.
	const right = draw(pose, "right");
	assert.ok(isOrange(right.at(64, 64)));
	const left = draw(pose, "left");
	assert.ok(isBlue(left.at(64, 64)));
});

test("a nearer part hides a farther one", () => {
	const pose = [box("RightFoot", [0, 0, -3], [2, 2, 1]), box("LeftFoot", [0, 0, 3], [2, 2, 1])];
	assert.ok(isOrange(draw(pose, "front").at(64, 64)), "the part in front of the rig is nearer to a viewer facing it");
	assert.ok(isBlue(draw(pose, "back").at(64, 64)));
	// Order in the list does not decide what is in front.
	assert.ok(isOrange(draw([...pose].reverse(), "front").at(64, 64)));
	assert.ok(isBlue(draw([...pose].reverse(), "back").at(64, 64)));
	// Parts that pass through each other are resolved point by point, not part by part.
	const crossed = [box("RightFoot", [0, 0, 0], [3, 0.5, 0.5]), box("LeftFoot", [0, 0, 0], [0.5, 0.5, 3])];
	const side = draw(crossed, "front");
	assert.ok(isBlue(side.at(64, 64)), "the end of the bar pointing at the viewer covers the middle");
	assert.ok(isOrange(side.at(30, 64)), "and the bar lying across shows beside it");
});

test("the head carries a mark on its front and nowhere else", () => {
	const pose = [box("Head", [0, 0, 0], [2, 2, 2])];
	const dark = (pixel: Pixel) => pixel[0] < 90 && pixel[1] < 90 && pixel[2] < 90;
	assert.ok(dark(draw(pose, "front").at(64, 64)), `front ${draw(pose, "front").at(64, 64)}`);
	const back = draw(pose, "back").at(64, 64);
	assert.ok(!dark(back) && back[0] > back[2] + 30, `back ${back}`);
	// From above with its front upwards, the mark sticks out of the top edge of the head.
	const top = draw(pose, "top");
	const head = extent(draw([box("UpperTorso", [0, 0, 0], [2, 2, 2])], "top"));
	assert.ok(extent(top).height > extent(top).width, "the mark makes the head longer along its front");
	assert.ok(head.width === head.height || Math.abs(head.width - head.height) <= 1);
});

test("a part that is turned is drawn turned", () => {
	const upright: PosePart = { name: "UpperTorso", size: [1, 4, 1], cframe: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1] };
	// A quarter turn about the forward axis lays the tall box on its side.
	const lying: PosePart = { name: "UpperTorso", size: [1, 4, 1], cframe: [0, 0, 0, 0, -1, 0, 1, 0, 0, 0, 0, 1] };
	const tall = extent(draw([upright], "front"));
	const wide = extent(draw([lying], "front"));
	assert.ok(tall.height > tall.width * 3, `${tall.width}x${tall.height}`);
	assert.ok(wide.width > wide.height * 3, `${wide.width}x${wide.height}`);
	// Which way it turns matters. Seen from behind, where the rig's right is on the viewer's
	// right, a bar turned 30 degrees anticlockwise about the axis towards the viewer rises
	// to the right. Reading the rotation the wrong way round would make it fall.
	const cos = Math.cos(Math.PI / 6);
	const sin = Math.sin(Math.PI / 6);
	const bar: PosePart = { name: "UpperTorso", size: [6, 0.6, 0.6], cframe: [0, 0, 0, cos, -sin, 0, sin, cos, 0, 0, 0, 1] };
	const tilted = draw([bar], "back", 200);
	assert.ok(!isBackground(tilted.at(160, 65)), "its right end is up");
	assert.ok(isBackground(tilted.at(160, 135)), "and not down");
	assert.ok(!isBackground(tilted.at(40, 135)), "its left end is down");
	assert.ok(isBackground(tilted.at(40, 65)));
	// Halfway between, it leans.
	const k = Math.SQRT1_2;
	const leaning = extent(draw([{ name: "UpperTorso", size: [1, 4, 1], cframe: [0, 0, 0, k, -k, 0, k, k, 0, 0, 0, 1] }], "front"));
	assert.ok(Math.abs(leaning.width - leaning.height) <= 2, `${leaning.width}x${leaning.height}`);
});

test("the whole pose fits in every view, at one scale, however it is spread", () => {
	const pose = [box("UpperTorso", [0, 0, 0], [2, 2, 1]), box("RightHand", [9, 4, 0]), box("LeftFoot", [-1, -7, 5]), box("Head", [0, 3, -6], [1.2, 1.2, 1.2])];
	const views: ViewName[] = ["front", "back", "left", "right", "top", "three_quarter"];
	for (const view of views) {
		const image = draw(pose, view, 200);
		const drawn = extent(image);
		assert.ok(drawn.left > 0 && drawn.top > 0 && drawn.right < 199 && drawn.bottom < 199, `${view} ${JSON.stringify(drawn)}`);
	}
	// One scale: the torso is as wide from the back as from the front.
	const only = [box("UpperTorso", [0, 0, 0], [2, 2, 1])];
	assert.equal(extent(draw(only, "front", 200)).width, extent(draw(only, "back", 200)).width);
	// And a tiny pose is not blown up beyond a sensible size.
	const speck = extent(draw([box("UpperTorso", [0, 0, 0], [0.01, 0.01, 0.01])], "front", 200));
	assert.ok(speck.width < 20, String(speck.width));
});

test("several views are drawn side by side in the order asked for", () => {
	const pose = [box("LeftHand", [-3, 0, 0]), box("RightHand", [3, 0, 0])];
	const drawn = renderPose(pose, ["front", "back", "top"], 128);
	assert.equal(drawn.width, 384);
	assert.equal(drawn.height, 128);
	const image = decode(drawn.png);
	assert.ok(isOrange(image.at(20, 64)) && isBlue(image.at(107, 64)), "front first");
	assert.ok(isBlue(image.at(128 + 20, 64)) && isOrange(image.at(128 + 107, 64)), "then back");
	assert.ok(isBlue(image.at(256 + 20, 64)) && isOrange(image.at(256 + 107, 64)), "then top");
	// A thin line separates the views.
	assert.deepEqual(image.at(128, 5), [214, 214, 214]);
	assert.deepEqual(image.at(256, 5), [214, 214, 214]);
	assert.ok(isBackground(image.at(0, 5)));
});

test("only a pose in the expected form is drawn", () => {
	const good = { parts: [box("Head", [0, 1, 0])] };
	assert.equal(parsePose(good).length, 1);
	const withPart = (change: Record<string, unknown>) => ({ parts: [{ ...box("Head", [0, 1, 0]), ...change }] });
	assert.throws(() => parsePose(undefined), /no pose/);
	assert.throws(() => parsePose("pose"), /no pose/);
	assert.throws(() => parsePose({ parts: "many" }), /no pose/);
	assert.throws(() => parsePose({ parts: [] }), /number of parts/);
	assert.throws(() => parsePose({ parts: Array.from({ length: MAX_PARTS + 1 }, () => box("Head", [0, 0, 0])) }), /number of parts/);
	assert.equal(parsePose({ parts: Array.from({ length: MAX_PARTS }, () => box("Head", [0, 0, 0])) }).length, MAX_PARTS);
	assert.throws(() => parsePose({ parts: [null] }), /name/);
	assert.throws(() => parsePose(withPart({ name: "" })), /name/);
	assert.throws(() => parsePose(withPart({ name: 7 })), /name/);
	assert.throws(() => parsePose(withPart({ name: "x".repeat(65) })), /name/);
	assert.throws(() => parsePose(withPart({ size: [1, 1] })), /size/);
	assert.throws(() => parsePose(withPart({ size: [1, 0, 1] })), /size/);
	assert.throws(() => parsePose(withPart({ size: [1, -2, 1] })), /size/);
	assert.throws(() => parsePose(withPart({ size: [1, Number.NaN, 1] })), /size/);
	assert.throws(() => parsePose(withPart({ size: [1, 5000, 1] })), /size/);
	assert.throws(() => parsePose(withPart({ size: ["1", 1, 1] })), /size/);
	assert.throws(() => parsePose(withPart({ cframe: [0, 0, 0] })), /position/);
	assert.throws(() => parsePose(withPart({ cframe: [0, 0, 1e9, 1, 0, 0, 0, 1, 0, 0, 0, 1] })), /position/);
	assert.throws(() => parsePose(withPart({ cframe: [0, 0, Number.POSITIVE_INFINITY, 1, 0, 0, 0, 1, 0, 0, 0, 1] })), /position/);
	assert.throws(() => parsePose(withPart({ cframe: [0, 0, 0, 5, 0, 0, 0, 1, 0, 0, 0, 1] })), /rotation/);
});

test("the size and number of views are held to their limits", () => {
	const pose = [box("Head", [0, 0, 0])];
	assert.throws(() => renderPose(pose, [], 128), /views/);
	assert.throws(() => renderPose(pose, ["front", "back", "left", "right", "top"], 128), /views/);
	assert.throws(() => renderPose(pose, ["front"], 64), /size/);
	assert.throws(() => renderPose(pose, ["front"], 1024), /size/);
	assert.throws(() => renderPose(pose, ["front"], 200.5), /size/);
	assert.throws(() => renderPose(pose, ["front", "back", "left"], 768), /size/);
	assert.equal(renderPose(pose, ["front", "back", "left", "right"], 384).width, 1536);
});

test("a preview's result gets a picture only when one was asked for, and never keeps the raw pose", () => {
	const pose = { parts: [box("UpperTorso", [0, 0, 0], [2, 2, 1]), box("RightHand", [2, 0, 0])] };
	const result = { clip_id: "clip_1", time: 0.5, joints: { Head: { rotation: [0, 0, 0] } }, pose };

	const plain = renderResult({ clip_id: "clip_1", time: 0.5 }, result);
	assert.equal(plain.image, undefined);
	assert.deepEqual(plain.payload, { clip_id: "clip_1", time: 0.5, joints: { Head: { rotation: [0, 0, 0] } } });

	const asked = renderResult({ clip_id: "clip_1", time: 0.5, render: true }, result);
	assert.ok(asked.image !== undefined);
	const png = Buffer.from(asked.image as string, "base64");
	assert.deepEqual(inspectPng(png), { width: DEFAULT_TILE, height: DEFAULT_TILE });
	const payload = asked.payload as { pose?: unknown; render: Record<string, unknown>; joints: unknown };
	assert.equal(payload.pose, undefined);
	assert.deepEqual(payload.render, { status: "ok", views: ["three_quarter"], width: DEFAULT_TILE, height: DEFAULT_TILE, legend: LEGEND });
	assert.deepEqual(payload.joints, { Head: { rotation: [0, 0, 0] } });

	const chosen = renderResult({ render: true, views: ["front", "right"], render_size: 256 }, result);
	assert.deepEqual(inspectPng(Buffer.from(chosen.image as string, "base64")), { width: 512, height: 256 });
	assert.deepEqual((chosen.payload as { render: { views: string[] } }).render.views, ["front", "right"]);

	// Four views at the largest size would be too wide, so each is made smaller.
	const many = renderResult({ render: true, views: ["front", "back", "left", "right"], render_size: 768 }, result);
	assert.deepEqual(inspectPng(Buffer.from(many.image as string, "base64")), { width: 1536, height: 384 });
	// A size outside what the tool accepts falls back to the default.
	const odd = renderResult({ render: true, render_size: 5000 }, result);
	assert.deepEqual(inspectPng(Buffer.from(odd.image as string, "base64")), { width: DEFAULT_TILE, height: DEFAULT_TILE });
});

test("a picture that cannot be drawn is reported, and the rest of the result still arrives", () => {
	const unavailable = (params: unknown, result: unknown, reason: RegExp) => {
		const outcome = renderResult(params, result);
		assert.equal(outcome.image, undefined);
		const payload = outcome.payload as { pose?: unknown; render: { status: string; reason: string }; clip_id?: string };
		assert.equal(payload.pose, undefined);
		assert.equal(payload.render.status, "unavailable");
		assert.match(payload.render.reason, reason);
		assert.equal(payload.clip_id, "clip_1");
	};
	const pose = { parts: [box("Head", [0, 0, 0])] };
	unavailable({ render: true }, { clip_id: "clip_1" }, /no pose/);
	unavailable({ render: true }, { clip_id: "clip_1", pose: { parts: [] } }, /number of parts/);
	unavailable({ render: true }, { clip_id: "clip_1", pose: { parts: [{ name: "Head", size: [1, 1, 1], cframe: [] }] } }, /position/);
	unavailable({ render: true, views: ["front", "sideways"] }, { clip_id: "clip_1", pose }, /views/);
	unavailable({ render: true, views: [] }, { clip_id: "clip_1", pose }, /views/);
	// Asking for a picture in any way other than `true` is not asking.
	for (const render of ["true", 1, null, undefined]) {
		const outcome = renderResult({ render }, { clip_id: "clip_1", pose });
		assert.equal(outcome.image, undefined);
		assert.deepEqual(outcome.payload, { clip_id: "clip_1" });
	}
	assert.deepEqual(renderResult({ render: true }, "text"), { payload: "text" });
	assert.deepEqual(renderResult({ render: true }, null), { payload: null });
});

test("with the rest pose given, pictures of different poses are framed alike", () => {
	const torso = box("UpperTorso", [0, 0, 0], [2, 2, 1]);
	const rest = [torso, box("RightHand", [-1.5, -1, 0]), box("LeftHand", [1.5, -1, 0])];
	const raised = [torso, box("RightHand", [-1.5, 2, 0]), box("LeftHand", [1.5, -1, 0])];
	const bounds = (parts: PosePart[], frame?: PosePart[]) => {
		const image = decode(renderPose(parts, ["front"], 128, frame).png);
		// Where the grey torso is in the picture: its first and last columns and rows.
		let [left, right, top, bottom] = [128, -1, 128, -1];
		for (let y = 0; y < 128; y += 1) {
			for (let x = 0; x < 128; x += 1) {
				const pixel = image.at(x, y);
				if (!isBackground(pixel) && !isOrange(pixel) && !isBlue(pixel)) {
					[left, right, top, bottom] = [Math.min(left, x), Math.max(right, x), Math.min(top, y), Math.max(bottom, y)];
				}
			}
		}
		return [left, right, top, bottom];
	};
	// Framed on each pose by itself, the torso moves and changes size when a hand is raised.
	assert.notDeepEqual(bounds(rest), bounds(raised));
	// Framed on the rest pose, it stays exactly where it was.
	assert.deepEqual(bounds(rest, rest), bounds(raised, rest));

	// A pose that reaches far outside the rest frame still fits: nothing is cut off.
	const far = [torso, box("RightHand", [-9, 6, 0]), box("LeftHand", [1.5, -1, 0])];
	const image = decode(renderPose(far, ["front"], 128, rest).png);
	let orange = 0;
	for (let y = 0; y < 128; y += 1) for (let x = 0; x < 128; x += 1) if (isOrange(image.at(x, y))) orange += 1;
	assert.ok(orange > 0);
	for (let edge = 0; edge < 128; edge += 1) {
		for (const pixel of [image.at(edge, 0), image.at(edge, 127), image.at(0, edge), image.at(127, edge)]) assert.ok(isBackground(pixel));
	}
});

test("a preview's rest pose frames its picture and is not passed on", () => {
	const torso = box("UpperTorso", [0, 0, 0], [2, 2, 1]);
	const pose = { parts: [torso, box("RightHand", [-1.5, 2, 0])], rest: [torso, box("RightHand", [-1.5, -1, 0])] };
	const framed = renderResult({ render: true }, { clip_id: "clip_1", pose });
	const alone = renderResult({ render: true }, { clip_id: "clip_1", pose: { parts: pose.parts } });
	assert.equal((framed.payload as { pose?: unknown }).pose, undefined);
	assert.ok(framed.image && alone.image && framed.image !== alone.image);
	// A rest pose that is not in the expected form means no picture, not a wrong one.
	const bad = renderResult({ render: true }, { clip_id: "clip_1", pose: { parts: pose.parts, rest: [{ name: "x" }] } });
	assert.equal(bad.image, undefined);
	assert.equal((bad.payload as { render: { status: string } }).render.status, "unavailable");
});
