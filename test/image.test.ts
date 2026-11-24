import assert from "node:assert/strict";
import { test } from "node:test";
import { deflateSync } from "node:zlib";
import { IMAGE_METHOD, inspectPng, MAX_IMAGE_BYTES, screenResult } from "../src/image.js";

function crc32(data: Buffer): number {
	let crc = 0xffffffff;
	for (const byte of data) {
		crc ^= byte;
		for (let k = 0; k < 8; k += 1) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
	}
	return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type: string, body: Buffer): Buffer {
	const head = Buffer.alloc(8);
	head.writeUInt32BE(body.length, 0);
	head.write(type, 4, "latin1");
	const tail = Buffer.alloc(4);
	tail.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), body])), 0);
	return Buffer.concat([head, body, tail]);
}

const SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

/** A real, complete greyscale PNG of the given size, optionally padded with an extra chunk. */
function png(width: number, height: number, padding = 0): Buffer {
	const header = Buffer.alloc(13);
	header.writeUInt32BE(width, 0);
	header.writeUInt32BE(height, 4);
	header[8] = 8;
	const rows = Buffer.alloc((width + 1) * height);
	const parts = [SIGNATURE, chunk("IHDR", header)];
	if (padding > 0) parts.push(chunk("tEXt", Buffer.alloc(padding, 0x41)));
	parts.push(chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0)));
	return Buffer.concat(parts);
}

/** What a well-behaved plugin returns for a successful screenshot of this image. */
function answer(data: Buffer, width: number, height: number, change: Record<string, unknown> = {}) {
	const capture = { status: "ok", format: "png", width, height, bytes: data.length, milliseconds: 12, ...change };
	return { clip_id: "clip_1", time: 0.5, joints: {}, capture, images: [{ png_base64: data.toString("base64") }] };
}

const ASKED = { clip_id: "clip_1", time: 0.5, capture: true };

function rejected(outcome: { payload: unknown; image?: string }, reason: RegExp): void {
	assert.equal(outcome.image, undefined);
	const payload = outcome.payload as { capture: { status: string; reason: string }; images?: unknown };
	assert.equal(payload.images, undefined);
	assert.equal(payload.capture.status, "unavailable");
	assert.match(payload.capture.reason, reason);
	assert.doesNotMatch(JSON.stringify(outcome.payload), /png_base64/);
}

test("a complete PNG of the reported size passes for a preview that asked for it", () => {
	const data = png(320, 180);
	const outcome = screenResult(IMAGE_METHOD, ASKED, answer(data, 320, 180));
	assert.equal(outcome.image, data.toString("base64"));
	const payload = outcome.payload as { capture: { status: string; width: number }; images?: unknown; joints: unknown };
	assert.equal(payload.images, undefined);
	assert.equal(payload.capture.status, "ok");
	assert.equal(payload.capture.width, 320);
	assert.deepEqual(payload.joints, {});
});

test("the size of a PNG is read only from a complete, well-formed file", () => {
	const data = png(7, 5);
	assert.deepEqual(inspectPng(data), { width: 7, height: 5 });
	assert.throws(() => inspectPng(data.subarray(0, data.length - 1)), /cut short/);
	assert.throws(() => inspectPng(data.subarray(0, data.length - 12)), /cut short/);
	assert.throws(() => inspectPng(Buffer.concat([data, Buffer.from([0])])), /cut short|after its end/);
	assert.throws(() => inspectPng(Buffer.concat([data, chunk("IEND", Buffer.alloc(0))])), /after its end/);
	assert.throws(() => inspectPng(Buffer.from("not a png at all, just text")), /not a PNG/);
	const flipped = Buffer.from(data);
	flipped[flipped.length - 20] = (flipped[flipped.length - 20] as number) ^ 0xff;
	assert.throws(() => inspectPng(flipped), /checksum/);
	const header = Buffer.alloc(13);
	header.writeUInt32BE(4, 0);
	header.writeUInt32BE(4, 4);
	header[8] = 8;
	const empty = Buffer.concat([SIGNATURE, chunk("IHDR", header), chunk("IEND", Buffer.alloc(0))]);
	assert.throws(() => inspectPng(empty), /no image data/);
	const headless = Buffer.concat([SIGNATURE, chunk("IDAT", deflateSync(Buffer.alloc(4))), chunk("IEND", Buffer.alloc(0))]);
	assert.throws(() => inspectPng(headless), /header/);
});

test("an image is dropped when the preview did not ask for one", () => {
	const data = png(16, 16);
	for (const params of [{ clip_id: "clip_1", time: 0.5 }, { capture: false }, { capture: "true" }, undefined, null]) {
		rejected(screenResult(IMAGE_METHOD, params, answer(data, 16, 16)), /not asked for/);
	}
});

test("an image is dropped from every other method", () => {
	const data = png(16, 16);
	for (const method of ["get_workspace", "read_animation", "edit_animation", "inspect_rig", "open_animation", "broker.status", "PREVIEW_ANIMATION"]) {
		const outcome = screenResult(method, ASKED, answer(data, 16, 16));
		assert.equal(outcome.image, undefined, method);
		assert.doesNotMatch(JSON.stringify(outcome.payload), /png_base64/, method);
	}
});

test("an image is dropped unless the preview reports success", () => {
	const data = png(16, 16);
	for (const status of ["unavailable", "pending", "OK", 1, undefined]) {
		const outcome = screenResult(IMAGE_METHOD, ASKED, answer(data, 16, 16, { status }));
		assert.equal(outcome.image, undefined, String(status));
		assert.doesNotMatch(JSON.stringify(outcome.payload), /png_base64/);
		assert.notEqual((outcome.payload as { capture: { status: unknown } }).capture.status, "ok");
	}
	const none = screenResult(IMAGE_METHOD, ASKED, { clip_id: "clip_1", images: [{ png_base64: data.toString("base64") }] });
	rejected(none, /no screenshot result/);
});

test("a result that reports success without one well-formed image entry is rejected", () => {
	const data = png(16, 16);
	const text = data.toString("base64");
	const base = answer(data, 16, 16);
	rejected(screenResult(IMAGE_METHOD, ASKED, { ...base, images: undefined }), /exactly one image/);
	rejected(screenResult(IMAGE_METHOD, ASKED, { ...base, images: [] }), /exactly one image/);
	rejected(screenResult(IMAGE_METHOD, ASKED, { ...base, images: [{ png_base64: text }, { png_base64: text }] }), /exactly one image/);
	rejected(screenResult(IMAGE_METHOD, ASKED, { ...base, images: { png_base64: text } }), /exactly one image/);
	rejected(screenResult(IMAGE_METHOD, ASKED, { ...base, images: [text] }), /expected form/);
	rejected(screenResult(IMAGE_METHOD, ASKED, { ...base, images: [{ png_base64: text, url: "x" }] }), /expected form/);
	rejected(screenResult(IMAGE_METHOD, ASKED, { ...base, images: [{ png_base64: 5 }] }), /expected form/);
});

test("an image that does not match what is reported about it is rejected", () => {
	const data = png(64, 48);
	rejected(screenResult(IMAGE_METHOD, ASKED, answer(data, 64, 48, { format: "rgba8" })), /not reported as a PNG/);
	rejected(screenResult(IMAGE_METHOD, ASKED, answer(data, 64, 48, { format: undefined })), /not reported as a PNG/);
	rejected(screenResult(IMAGE_METHOD, ASKED, answer(data, 48, 64)), /not the 48 by 64 reported/);
	rejected(screenResult(IMAGE_METHOD, ASKED, answer(data, 64, 48, { width: undefined })), /size was not reported/);
	rejected(screenResult(IMAGE_METHOD, ASKED, answer(data, 64, 48, { height: 0 })), /size was not reported/);
	rejected(screenResult(IMAGE_METHOD, ASKED, answer(data, 64, 48, { bytes: data.length - 1 })), /encoding/);
	rejected(screenResult(IMAGE_METHOD, ASKED, answer(data, 64, 48, { bytes: 1.5 })), /size was not reported/);
});

test("an image larger than was asked for, or over the limits, is rejected", () => {
	rejected(screenResult(IMAGE_METHOD, ASKED, answer(png(800, 10), 800, 10)), /over the 768 asked for/);
	rejected(screenResult(IMAGE_METHOD, { ...ASKED, max_edge: 64 }, answer(png(65, 10), 65, 10)), /over the 64 asked for/);
	// A max_edge outside what the tool accepts falls back to the default, not to something larger.
	rejected(screenResult(IMAGE_METHOD, { ...ASKED, max_edge: 100000 }, answer(png(800, 10), 800, 10)), /over the 768 asked for/);
	assert.notEqual(screenResult(IMAGE_METHOD, { ...ASKED, max_edge: 1536 }, answer(png(1536, 4), 1536, 4)).image, undefined);
	rejected(screenResult(IMAGE_METHOD, { ...ASKED, max_edge: 1536 }, answer(png(1537, 4), 1537, 4)), /over the 1536 asked for/);

	const heavy = png(8, 8, MAX_IMAGE_BYTES);
	assert.ok(heavy.length > MAX_IMAGE_BYTES);
	assert.deepEqual(inspectPng(heavy), { width: 8, height: 8 });
	rejected(screenResult(IMAGE_METHOD, ASKED, answer(heavy, 8, 8)), /over the size limit/);
});

test("a malformed or cut-short image is rejected", () => {
	const data = png(32, 32);
	const text = data.toString("base64");
	const base = answer(data, 32, 32);
	const withText = (png_base64: string, bytes = data.length) => ({ ...base, capture: { ...base.capture, bytes }, images: [{ png_base64 }] });

	rejected(screenResult(IMAGE_METHOD, ASKED, withText(text.slice(0, -4))), /encoding/);
	rejected(screenResult(IMAGE_METHOD, ASKED, withText(`${text.slice(0, -1)}!`)), /encoding/);
	rejected(screenResult(IMAGE_METHOD, ASKED, withText(`data:image/png;base64,${text}`)), /encoding/);
	rejected(screenResult(IMAGE_METHOD, ASKED, withText("")), /encoding|size was not reported/);

	const cut = data.subarray(0, data.length - 12);
	rejected(screenResult(IMAGE_METHOD, ASKED, withText(cut.toString("base64"), cut.length)), /cut short/);
	const corrupt = Buffer.from(data);
	corrupt[44] = (corrupt[44] as number) ^ 0x55;
	rejected(screenResult(IMAGE_METHOD, ASKED, withText(corrupt.toString("base64"))), /checksum/);
	const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(200)]);
	rejected(screenResult(IMAGE_METHOD, ASKED, withText(jpeg.toString("base64"), jpeg.length)), /not a PNG/);
});

test("results without images pass through unchanged", () => {
	const plain = { clip_id: "clip_1", revision: "r2", joints: { Head: { rotation: [0, 0, 0] } } };
	assert.deepEqual(screenResult(IMAGE_METHOD, { clip_id: "clip_1", time: 0 }, plain), { payload: plain });
	const off = { ...plain, capture: { status: "unavailable", reason: "screenshots are off" } };
	assert.deepEqual(screenResult(IMAGE_METHOD, ASKED, off), { payload: off });
	assert.deepEqual(screenResult("read_animation", {}, plain), { payload: plain });
	assert.deepEqual(screenResult("read_animation", {}, "text"), { payload: "text" });
	assert.deepEqual(screenResult("read_animation", {}, null), { payload: null });
});
