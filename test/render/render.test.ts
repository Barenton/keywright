import assert from "node:assert/strict";
import { test } from "node:test";
import { inflateSync } from "node:zlib";
import { inspectPng } from "../../src/render/image.js";
import { DEFAULT_TILE, LEGEND, limbOf, MAX_PARTS, type PosePart, parsePose, renderComparison, renderOnion, renderPose, renderResult, renderStrip, SLIM_LEGEND, SLIM_THICKNESS, slimParts, strengthOf, type ViewName } from "../../src/render/render.js";

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
	assert.deepEqual(payload.render, { status: "ok", views: ["three_quarter"], width: DEFAULT_TILE, height: DEFAULT_TILE, legend: LEGEND, style: "boxes" });
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

test("a filmstrip has a column for each pose and a row for each view, all framed alike", () => {
	const torso = box("UpperTorso", [0, 0, 0], [2, 2, 1]);
	const rest = [torso, box("RightHand", [-1.5, -1, 0])];
	const frames = [0, 1, 2, 3].map((step) => [torso, box("RightHand", [-1.5, -1 + step, 0])]);
	const strip = renderStrip(frames, ["front", "top"], 128, rest);
	assert.equal(strip.width, 128 * 4);
	assert.equal(strip.height, 128 * 2);
	const image = decode(strip.png);

	// The torso does not move, so it covers the same pixels of every tile in a row.
	const grey = (column: number, row: number): string => {
		const found: number[] = [];
		for (let y = 0; y < 128; y += 1) {
			// The half of the tile away from the hand, whose outline would otherwise be counted.
			for (let x = 2; x < 64; x += 1) {
				const pixel = image.at(column * 128 + x, row * 128 + y);
				if (!isBackground(pixel) && !isOrange(pixel) && !isBlue(pixel)) found.push(y * 128 + x);
			}
		}
		return `${found.length}:${found[0]}:${found[found.length - 1]}`;
	};
	// (Seen from the front, where the hand is beside the torso and never in front of it.)
	for (let column = 1; column < 4; column += 1) assert.equal(grey(column, 0), grey(0, 0));
	assert.notEqual(grey(0, 1), grey(0, 0));

	// The hand rises from one column to the next: its highest orange pixel gets higher.
	const top = (column: number): number => {
		for (let y = 0; y < 128; y += 1) for (let x = 2; x < 128; x += 1) if (isOrange(image.at(column * 128 + x, y))) return y;
		return 128;
	};
	assert.ok(top(0) > top(1) && top(1) > top(2) && top(2) > top(3), [0, 1, 2, 3].map(top).join(" "));

	// The frames are in the order given: reversing them reverses the strip.
	const reversed = decode(renderStrip([...frames].reverse(), ["front"], 128, rest).png);
	const topReversed = (column: number): number => {
		for (let y = 0; y < 128; y += 1) for (let x = 2; x < 128; x += 1) if (isOrange(reversed.at(column * 128 + x, y))) return y;
		return 128;
	};
	assert.ok(topReversed(0) < topReversed(3));
});

test("a filmstrip is held to its limits", () => {
	const frame = [box("UpperTorso", [0, 0, 0])];
	assert.throws(() => renderStrip([frame], ["front"], 128), /two to eight/);
	assert.throws(() => renderStrip(Array(9).fill(frame), ["front"], 128), /two to eight/);
	assert.throws(() => renderStrip([frame, frame], ["front", "top", "left"], 128), /one or two views/);
	assert.throws(() => renderStrip(Array(8).fill(frame), ["front"], 256), /outside the limits/);
	assert.equal(renderStrip(Array(8).fill(frame), ["front"], 192).width, 1536);
});

test("a preview of several times gets a filmstrip, and the raw poses are not passed on", () => {
	const torso = box("UpperTorso", [0, 0, 0], [2, 2, 1]);
	const pose = { frames: [0, 1, 2].map((step) => [torso, box("RightHand", [-1.5, step, 0])]), rest: [torso, box("RightHand", [-1.5, -1, 0])] };
	const result = renderResult({ render: true, times: [0, 0.5, 1], views: ["right", "front", "top"] }, { clip_id: "clip_1", frames: [{ time: 0 }, { time: 0.5 }, { time: 1 }], pose });
	const payload = result.payload as { pose?: unknown; frames: unknown[]; render: { status: string; frames: number; views: string[]; width: number; height: number } };
	assert.equal(payload.pose, undefined);
	assert.equal(payload.frames.length, 3);
	assert.equal(payload.render.status, "ok");
	assert.equal(payload.render.frames, 3);
	// At most two rows, and the size asked for is kept when it fits.
	assert.deepEqual(payload.render.views, ["right", "front"]);
	assert.equal(payload.render.width, DEFAULT_TILE * 3);
	assert.equal(payload.render.height, DEFAULT_TILE * 2);
	assert.ok(result.image);
	const { width, height } = inspectPng(Buffer.from(result.image as string, "base64"));
	assert.deepEqual([width, height], [payload.render.width, payload.render.height]);
	// Without render, no picture and no poses.
	const plain = renderResult({ times: [0, 1] }, { clip_id: "clip_1", frames: [], pose });
	assert.equal(plain.image, undefined);
	assert.equal((plain.payload as { pose?: unknown }).pose, undefined);
});

test("two clips are drawn one above the other at the same moments", () => {
	const torso = box("UpperTorso", [0, 0, 0], [2, 2, 1]);
	const rest = [torso, box("RightHand", [-1.5, -1, 0])];
	const still = [0, 1, 2].map(() => [torso, box("RightHand", [-1.5, -1, 0])]);
	const rising = [0, 1, 2].map((step) => [torso, box("RightHand", [-1.5, -1 + step, 0])]);
	const both = renderComparison(still, rising, "front", 128, rest);
	assert.deepEqual([both.width, both.height], [128 * 3, 128 * 2]);
	const image = decode(both.png);
	const top = (column: number, row: number): number => {
		for (let y = 2; y < 128; y += 1) for (let x = 2; x < 128; x += 1) if (isOrange(image.at(column * 128 + x, row * 128 + y))) return y;
		return 128;
	};
	// Top row: the first clip, whose hand does not move.
	assert.equal(top(0, 0), top(2, 0));
	// Bottom row: the second, whose hand rises; at the first moment the two agree.
	assert.equal(top(0, 1), top(0, 0));
	assert.ok(top(2, 1) < top(0, 1));
	assert.throws(() => renderComparison(still, rising.slice(0, 2), "front", 128, rest), /two to eight frames of each/);

	const pose = { frames: still, compare: rising, rest };
	const result = renderResult({ render: true, times: [0, 1, 2], views: ["front"] }, { clip_id: "clip_1", frames: [], compared: { name: "Other", differences: [] }, pose });
	const payload = result.payload as { pose?: unknown; compared: { name: string }; render: { layout: string; height: number } };
	assert.equal(payload.pose, undefined);
	assert.equal(payload.compared.name, "Other");
	assert.match(payload.render.layout, /top row this clip, bottom row/);
	assert.equal(payload.render.height, DEFAULT_TILE * 2);
});

test("the slim style thins arms and legs along their length, and leaves the rest as it is", () => {
	const parts = [
		box("RightUpperArm", [1, 0, 0], [1, 1.2, 1]),
		box("LeftLowerLeg", [-0.5, -2, 0], [1, 1.2, 1]),
		box("RightHand", [1, -1, 0], [1, 0.3, 1]),
		box("LeftFoot", [-0.5, -3, 0], [1, 0.3, 1]),
		box("UpperTorso", [0, 0, 0], [2, 1.6, 1]),
		box("Head", [0, 1.5, 0], [1.2, 1.2, 1.2]),
	];
	const slim = slimParts(parts);
	const size = (name: string) => slim.find((part) => part.name === name)?.size;
	assert.deepEqual(size("RightUpperArm"), [SLIM_THICKNESS, 1.2, SLIM_THICKNESS]);
	assert.deepEqual(size("LeftLowerLeg"), [SLIM_THICKNESS, 1.2, SLIM_THICKNESS]);
	for (const name of ["RightHand", "LeftFoot", "UpperTorso", "Head"]) {
		assert.deepEqual(size(name), parts.find((part) => part.name === name)?.size, name);
	}
	assert.deepEqual(slim.map((part) => part.cframe), parts.map((part) => part.cframe), "nothing moves");
});

test("a slim arm is drawn far thinner for its length than a box arm", () => {
	const arm = [box("RightUpperArm", [0, 0, 0], [1, 2, 1])];
	const wide = extent(draw(arm, "front"));
	const thin = extent(draw(slimParts(arm), "front"));
	// Each picture is scaled to fit its parts, so compare the arm's shape, not its pixels.
	assert.ok(thin.width / thin.height < wide.width / wide.height / 2, `${thin.width}x${thin.height} against ${wide.width}x${wide.height}`);
});

test("a preview asked for in the slim style is drawn so, and says so", () => {
	const pose = { parts: [box("UpperTorso", [0, 0, 0], [2, 1.6, 1]), box("RightUpperArm", [1.5, 0, 0], [1, 1.2, 1])] };
	const plain = renderResult({ render: true }, { pose });
	const slim = renderResult({ render: true, style: "slim" }, { pose });
	assert.equal((plain.payload as { render: { legend: string } }).render.legend, LEGEND);
	assert.equal((slim.payload as { render: { legend: string } }).render.legend, SLIM_LEGEND);
	assert.equal((plain.payload as { render: { style: string } }).render.style, "boxes");
	assert.equal((slim.payload as { render: { style: string } }).render.style, "slim");
	assert.ok(slim.image && plain.image && slim.image !== plain.image);
});

test("a filmstrip labels each column with its time", () => {
	const frames = [[box("UpperTorso", [0, 0, 0], [2, 2, 1])], [box("UpperTorso", [0, 0.5, 0], [2, 2, 1])]];
	const plain = decode(renderStrip(frames, ["front"], 128).png);
	const labelled = decode(renderStrip(frames, ["front"], 128, undefined, ["0.5", "1"]).png);
	const dark = (image: ReturnType<typeof decode>, column: number) => {
		let count = 0;
		for (let y = 0; y < 16; y += 1) for (let x = column * 128; x < column * 128 + 40; x += 1) if ((image.at(x, y)[0] as number) < 80) count += 1;
		return count;
	};
	assert.equal(dark(plain, 0), 0);
	assert.ok(dark(labelled, 0) > 0 && dark(labelled, 1) > 0, "both columns carry a label");
});

test("an onion skin draws every frame, the last in full colour and earlier ones fainter", () => {
	const frames = [0, 1, 2].map((step) => [box("UpperTorso", [0, 0, 0], [2, 2, 1]), box("RightUpperArm", [1.5, step * 0.8 - 0.8, 0], [1, 1, 1])]);
	const image = decode(renderOnion(frames, ["front"], 128).png);
	const oranges = new Set<string>();
	for (let y = 0; y < image.height; y += 1) for (let x = 0; x < image.width; x += 1) if (isOrange(image.at(x, y))) oranges.add(image.at(x, y).join());
	// A full-strength orange face, and paler ones from the earlier frames.
	const saturations = [...oranges].map((rgb) => { const [r, , b] = rgb.split(",").map(Number) as [number, number, number]; return r - b; });
	assert.ok(Math.max(...saturations) > 120, "the last frame is solid");
	assert.ok(saturations.some((value) => value > 0 && value < 80), "an earlier frame is faint");
});

test("an onion skin draws a tracked limb stronger than the rest of an earlier frame", () => {
	assert.deepEqual(limbOf("RightHand"), ["RightUpperArm", "RightLowerArm", "RightHand"]);
	assert.deepEqual(limbOf("LeftLowerLeg"), ["LeftUpperLeg", "LeftLowerLeg", "LeftFoot"]);
	assert.deepEqual(limbOf("Head"), ["Head"]);
	assert.equal(strengthOf(2, 3, false), 1);
	assert.ok(strengthOf(0, 3, true) > strengthOf(0, 3, false));
	assert.ok(strengthOf(0, 3, false) < strengthOf(1, 3, false), "earlier is fainter");
});

test("a preview asked for an onion skin draws one, and says why when it can't", () => {
	const parts = (y: number) => [box("UpperTorso", [0, y, 0], [2, 2, 1]), box("RightHand", [1.5, y, 0], [0.5, 0.5, 0.5])];
	const pose = { frames: [parts(0), parts(0.5), parts(1)] };
	const frames = [0, 0.1, 0.2].map((time) => ({ time }));
	const drawn = renderResult({ render: true, times: [0, 0.1, 0.2], onion: true, track: ["RightHand"] }, { frames, pose });
	const render = (drawn.payload as { render: Record<string, unknown> }).render;
	assert.equal(render.status, "ok");
	assert.deepEqual(render.paths, [{ part: "RightHand", colour: "red" }]);
	assert.deepEqual(render.numbered, [{ number: 1, time: 0 }, { number: 2, time: 0.1 }, { number: 3, time: 0.2 }]);
	assert.ok(drawn.image);
	// Paths beyond what can be drawn are named, not dropped without a word.
	const nine = ["RightHand", "UpperTorso", "RightHand", "UpperTorso", "RightHand", "UpperTorso", "RightHand", "UpperTorso", "RightHand"];
	const crowded = renderResult({ render: true, times: [0, 0.1, 0.2], onion: true, track: nine }, { frames, pose });
	assert.deepEqual((crowded.payload as { render: { paths_left_out: string[] } }).render.paths_left_out, ["RightHand"]);
	const single = renderResult({ render: true, onion: true }, { pose: { parts: parts(0) } });
	assert.match(String((single.payload as { render: { reason: string } }).render.reason), /needs times/);
	const compared = renderResult({ render: true, onion: true }, { frames, pose: { ...pose, compare: pose.frames } });
	assert.match(String((compared.payload as { render: { reason: string } }).render.reason), /one clip/);
});

test("a comparison at the other clip's own times labels its row with them", () => {
	const frames = [[box("UpperTorso", [0, 0, 0], [2, 2, 1])], [box("UpperTorso", [0, 0.5, 0], [2, 2, 1])]];
	const pose = { frames, compare: frames };
	const labelled = (compared: unknown) => {
		const drawn = renderResult({ render: true, times: [0.3, 0.4], compare_with: "source" }, { frames: [{ time: 0.3 }, { time: 0.4 }], compared, pose });
		const image = decode(Buffer.from(drawn.image ?? "", "base64"));
		const tile = image.height / 2;
		let dark = 0;
		for (let y = tile; y < tile + 16; y += 1) for (let x = 0; x < 40; x += 1) if ((image.at(x, y)[0] as number) < 80) dark += 1;
		return { dark, layout: String((drawn.payload as { render: { layout: string } }).render.layout) };
	};
	const same = labelled({ name: "Old", differences: [{ time: 0.3, other_time: 0.3 }, { time: 0.4, other_time: 0.4 }] });
	assert.equal(same.dark, 0, "at the same times, only the top row is labelled");
	// The other clip held at its end, shorter than this one: its row says so.
	const held = labelled({ name: "Old", differences: [{ time: 0.3, other_time: 0.3 }, { time: 0.4, other_time: 0.35 }] });
	assert.ok(held.dark > 0, "a time held at the other clip's end is labelled");
	const paired = labelled({ name: "Old", differences: [{ time: 0.3, other_time: 0.2 }, { time: 0.4, other_time: 0.267 }] });
	assert.ok(paired.dark > 0, "at its own times, the bottom row carries them");
	assert.match(paired.layout, /times it was sampled at/);
});
