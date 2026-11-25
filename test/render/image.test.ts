import assert from "node:assert/strict";
import { test } from "node:test";
import { deflateSync } from "node:zlib";
import { IMAGE_METHOD, inspectPng, MAX_IMAGE_BYTES, REMOVED, screenResult, scrub } from "../../src/render/image.js";

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

/** A real, complete greyscale PNG of the given size. With `noise` its pixels do not compress. */
function png(width: number, height: number, noise = false): Buffer {
	const header = Buffer.alloc(13);
	header.writeUInt32BE(width, 0);
	header.writeUInt32BE(height, 4);
	header[8] = noise ? 16 : 8;
	const rowBytes = 1 + width * (noise ? 2 : 1);
	const rows = Buffer.alloc(rowBytes * height);
	if (noise) {
		let state = 12345;
		for (let i = 0; i < rows.length; i += 1) {
			state = (Math.imul(state, 1103515245) + 12345) >>> 0;
			rows[i] = i % rowBytes === 0 ? 0 : state >>> 24;
		}
	}
	return Buffer.concat([SIGNATURE, chunk("IHDR", header), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]);
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

test("a PNG passes only if its image data decodes to exactly the pixels its header describes", () => {
	const header = (width: number, height: number, depth = 8, colour = 0, interlace = 0) => {
		const body = Buffer.alloc(13);
		body.writeUInt32BE(width, 0);
		body.writeUInt32BE(height, 4);
		body[8] = depth;
		body[9] = colour;
		body[12] = interlace;
		return chunk("IHDR", body);
	};
	const end = chunk("IEND", Buffer.alloc(0));
	const build = (...parts: Buffer[]) => Buffer.concat([SIGNATURE, ...parts, end]);
	const rows = (width: number, height: number, bytesPerPixel = 1) => Buffer.alloc((width * bytesPerPixel + 1) * height);

	assert.deepEqual(inspectPng(build(header(4, 3), chunk("IDAT", deflateSync(rows(4, 3))))), { width: 4, height: 3 });
	assert.deepEqual(inspectPng(build(header(4, 3, 8, 6), chunk("IDAT", deflateSync(rows(4, 3, 4))))), { width: 4, height: 3 });
	// Image data may be split across consecutive chunks.
	const packed = deflateSync(rows(4, 3));
	assert.deepEqual(inspectPng(build(header(4, 3), chunk("IDAT", packed.subarray(0, 5)), chunk("IDAT", packed.subarray(5)))), { width: 4, height: 3 });

	assert.throws(() => inspectPng(build(header(4, 3), chunk("IDAT", Buffer.alloc(0)))), /empty image data/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("IDAT", Buffer.from("not compressed data")))), /does not decompress/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("IDAT", packed.subarray(0, packed.length - 4)))), /does not decompress/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("IDAT", deflateSync(rows(4, 2))))), /not the size its header describes/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("IDAT", deflateSync(rows(4, 4))))), /does not decompress|not the size/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("IDAT", deflateSync(Buffer.alloc(15, 9))))), /malformed/);
	assert.throws(() => inspectPng(build(header(4, 3, 8, 6), chunk("IDAT", deflateSync(rows(4, 3))))), /not the size its header describes/);
	// Not one still image, or carrying something a screenshot has no need of.
	const still = chunk("IDAT", deflateSync(rows(4, 3)));
	assert.throws(() => inspectPng(build(header(4, 3), chunk("acTL", Buffer.alloc(8)), still)), /acTL/);
	assert.throws(() => inspectPng(build(header(4, 3), still, chunk("fdAT", Buffer.alloc(8)))), /fdAT/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("tEXt", Buffer.from("Comment\0hello")), still)), /tEXt/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("prIV", Buffer.alloc(64)), still)), /prIV/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("iCCP", Buffer.alloc(40, 0x41)), still)), /iCCP/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("IDAT", packed.subarray(0, 5)), chunk("gAMA", Buffer.alloc(4)), chunk("IDAT", packed.subarray(5)))), /after its image data/);
	assert.throws(() => inspectPng(build(header(4, 3), still, chunk("sRGB", Buffer.alloc(1)))), /after its image data/);
	// The few extra chunks a plain image may have, each once and in its exact form.
	const extras = [chunk("sRGB", Buffer.alloc(1)), chunk("gAMA", Buffer.alloc(4)), chunk("pHYs", Buffer.alloc(9)), chunk("cHRM", Buffer.alloc(32))];
	assert.deepEqual(inspectPng(build(header(4, 3), ...extras, still)), { width: 4, height: 3 });
	assert.throws(() => inspectPng(build(header(4, 3), chunk("gAMA", Buffer.alloc(5)), still)), /gAMA chunk is malformed/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("sRGB", Buffer.alloc(1)), chunk("sRGB", Buffer.alloc(1)), still)), /two sRGB/);
	// A palette: required for an indexed image, well-formed, and not allowed for greyscale.
	const indexed = chunk("IDAT", deflateSync(rows(4, 3)));
	assert.throws(() => inspectPng(build(header(4, 3, 8, 3), indexed)), /uses a palette but has none/);
	assert.deepEqual(inspectPng(build(header(4, 3, 8, 3), chunk("PLTE", Buffer.alloc(6)), indexed)), { width: 4, height: 3 });
	assert.throws(() => inspectPng(build(header(4, 3, 8, 3), chunk("PLTE", Buffer.alloc(7)), indexed)), /palette is malformed/);
	assert.throws(() => inspectPng(build(header(4, 3, 8, 3), chunk("PLTE", Buffer.alloc(0)), indexed)), /palette is malformed/);
	assert.throws(() => inspectPng(build(header(4, 3, 8, 3), chunk("PLTE", Buffer.alloc(771)), indexed)), /palette is malformed/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("PLTE", Buffer.alloc(6)), still)), /palette its colour type does not allow/);
	// Image data that decodes to the right pixels but carries something extra after them.
	const trailing = Buffer.concat([packed, Buffer.from("extra bytes after the image")]);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("IDAT", trailing))), /bytes left over/);
	assert.throws(() => inspectPng(build(header(4, 3), chunk("IDAT", Buffer.concat([packed, Buffer.from([0])])))), /bytes left over/);
	assert.throws(() => inspectPng(build(header(4, 3, 8, 0, 1), still)), /interlaced/);
	assert.throws(() => inspectPng(build(header(4, 3, 3, 0), still)), /header is malformed/);
	assert.throws(() => inspectPng(build(header(4, 3, 8, 5), still)), /header is malformed/);
	assert.throws(() => inspectPng(build(header(0, 3), still)), /outside the limits/);
	assert.throws(() => inspectPng(build(header(4000, 3), chunk("IDAT", deflateSync(rows(4000, 3))))), /outside the limits/);
});

test("nothing image-like is passed on as text, at any depth and from any method", () => {
	const text = png(16, 16).toString("base64");
	const nested = {
		rigs: [{ rig_id: "rig_1", thumbnail: { images: [{ png_base64: text }] } }],
		note: text,
		deep: { list: [1, "two", { png_base64: text, keep: true }], uri: `data:image/png;base64,${text}` },
		plain: "RightUpperArm",
	};
	for (const method of ["get_workspace", "read_animation", IMAGE_METHOD]) {
		const outcome = screenResult(method, {}, nested);
		assert.equal(outcome.image, undefined, method);
		const sent = JSON.stringify(outcome.payload);
		assert.doesNotMatch(sent, /iVBORw0KGgo|png_base64|"images"|data:image/, method);
		const payload = outcome.payload as typeof nested & { deep: { list: unknown[] } };
		assert.equal(payload.plain, "RightUpperArm");
		assert.equal(payload.note, REMOVED);
		assert.deepEqual(payload.deep.list, [1, "two", { keep: true }]);
		assert.deepEqual(payload.rigs, [{ rig_id: "rig_1", thumbnail: {} }]);
	}
	// A preview that did not ask for a screenshot is told that one was dropped.
	const preview = screenResult(IMAGE_METHOD, { time: 0 }, nested).payload as { capture: { status: string; reason: string } };
	assert.equal(preview.capture.status, "unavailable");
	assert.match(preview.capture.reason, /not asked for/);
	// A claim of success from another method is not passed on either.
	const claim = screenResult("read_animation", { capture: true }, { capture: { status: "ok", width: 4 } }).payload as { capture: { status: string } };
	assert.equal(claim.capture.status, "unavailable");

	// An image carried in the name of a field, not its value.
	for (const method of ["get_workspace", IMAGE_METHOD]) {
		const keyed = screenResult(method, {}, { rigs: { [text]: 1, [`data:image/png;base64,${text}`]: { ok: true }, name: "Dummy" } });
		assert.doesNotMatch(JSON.stringify(keyed.payload), /iVBORw0KGgo|data:image/, method);
		assert.deepEqual((keyed.payload as { rigs: unknown }).rigs, { name: "Dummy" });
	}
	assert.equal(scrub({ [text]: "x" }).removed, true);

	assert.deepEqual(scrub({ a: [1, { b: "c" }], d: null }), { value: { a: [1, { b: "c" }], d: null }, removed: false });
	assert.deepEqual(scrub("plain text"), { value: "plain text", removed: false });
	assert.equal(scrub(text).removed, true);
	let chain: unknown = text;
	for (let level = 0; level < 60; level += 1) chain = { next: chain };
	assert.doesNotMatch(JSON.stringify(scrub(chain).value), /iVBORw0KGgo/);
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

	// A real image, valid in every respect, that is simply too large.
	const heavy = png(1536, 1536, true);
	assert.ok(heavy.length > MAX_IMAGE_BYTES, String(heavy.length));
	rejected(screenResult(IMAGE_METHOD, { ...ASKED, max_edge: 1536 }, answer(heavy, 1536, 1536)), /over the size limit/);
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
