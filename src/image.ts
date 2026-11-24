// The relay's own check on screenshots. The plugin already limits what it sends; this
// repeats the limits on the other side of the connection, so that nothing the plugin
// (or anything speaking for it) returns can reach a model as an image unless it was
// asked for and is one complete, decodable, still PNG of the reported size. Nothing
// image-like is passed on as text either.

import { inflateSync } from "node:zlib";

export const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
export const MAX_IMAGE_EDGE = 1536;
export const MIN_IMAGE_EDGE = 64;
export const DEFAULT_IMAGE_EDGE = 768;
/** The only method that may return an image, and only when its `capture` argument is true. */
export const IMAGE_METHOD = "preview_animation";
/** What takes the place of anything image-like found where no image belongs. */
export const REMOVED = "[removed by the relay]";

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;
/**
 * Chunks a plain still image may contain besides its header, palette, image data and end,
 * with the exact length each must have. Each may appear once, before the image data.
 * Anything else is refused: animation, text, embedded profiles, and private chunks.
 */
const ANCILLARY_CHUNKS: Record<string, number> = { gAMA: 4, cHRM: 32, sRGB: 1, pHYs: 9 };
/** Samples per pixel for each colour type, and the bit depths each allows. */
const COLOUR_TYPES: Record<number, { samples: number; depths: number[] }> = {
	0: { samples: 1, depths: [1, 2, 4, 8, 16] },
	2: { samples: 3, depths: [8, 16] },
	3: { samples: 1, depths: [1, 2, 4, 8] },
	4: { samples: 2, depths: [8, 16] },
	6: { samples: 4, depths: [8, 16] },
};

const CRC_TABLE = (() => {
	const table = new Uint32Array(256);
	for (let n = 0; n < 256; n += 1) {
		let c = n;
		for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
		table[n] = c >>> 0;
	}
	return table;
})();

function crc32(data: Buffer, start: number, end: number): number {
	let crc = 0xffffffff;
	for (let i = start; i < end; i += 1) crc = (CRC_TABLE[(crc ^ (data[i] as number)) & 0xff] as number) ^ (crc >>> 8);
	return (crc ^ 0xffffffff) >>> 0;
}

/**
 * Reads the size of a PNG after checking that it is one complete still image that
 * decodes: the signature, a well-formed header first, only chunk types a plain image
 * has, every chunk inside the data with a correct checksum, the end chunk exactly at
 * the end, and image data that decompresses to exactly the rows of pixels the header
 * describes. Throws with the reason otherwise.
 */
export function inspectPng(data: Buffer): { width: number; height: number } {
	if (data.length < 8 || !data.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error("it is not a PNG");
	let offset = 8;
	let header: { width: number; height: number; rowBytes: number; indexed: boolean; palette: boolean } | undefined;
	const imageData: Buffer[] = [];
	let imageDataEnded = false;
	const seen = new Set<string>();
	for (;;) {
		if (offset + 12 > data.length) throw new Error("it is cut short");
		const length = data.readUInt32BE(offset);
		const type = data.toString("latin1", offset + 4, offset + 8);
		if (!/^[A-Za-z]{4}$/.test(type)) throw new Error("it has a malformed chunk");
		const end = offset + 12 + length;
		if (length > MAX_IMAGE_BYTES || end > data.length) throw new Error("it is cut short");
		if (crc32(data, offset + 4, offset + 8 + length) !== data.readUInt32BE(offset + 8 + length)) {
			throw new Error("a chunk fails its checksum");
		}
		if (header === undefined) {
			if (type !== "IHDR" || length !== 13) throw new Error("it does not start with a header");
			const width = data.readUInt32BE(offset + 8);
			const height = data.readUInt32BE(offset + 12);
			const bitDepth = data[offset + 16] as number;
			const colourType = data[offset + 17] as number;
			const colour = COLOUR_TYPES[colourType];
			if (!colour?.depths.includes(bitDepth) || data[offset + 18] !== 0 || data[offset + 19] !== 0) {
				throw new Error("its header is malformed");
			}
			if (data[offset + 20] !== 0) throw new Error("it is interlaced, which is not accepted");
			if (width < 1 || height < 1 || width > MAX_IMAGE_EDGE || height > MAX_IMAGE_EDGE) {
				throw new Error(`it declares ${width} by ${height} pixels, outside the limits`);
			}
			header = {
				width,
				height,
				rowBytes: 1 + Math.ceil((width * colour.samples * bitDepth) / 8),
				indexed: colourType === 3,
				palette: colourType === 2 || colourType === 3 || colourType === 6,
			};
		} else if (type === "IHDR") {
			throw new Error("it has two headers");
		} else if (type === "IDAT") {
			if (imageDataEnded) throw new Error("its image data is split apart");
			if (length === 0) throw new Error("it has an empty image data chunk");
			if (header.indexed && !seen.has("PLTE")) throw new Error("it uses a palette but has none");
			imageData.push(data.subarray(offset + 8, offset + 8 + length));
		} else if (type === "IEND") {
			if (length !== 0) throw new Error("its end chunk is malformed");
			if (end !== data.length) throw new Error("it has data after its end");
			if (imageData.length === 0) throw new Error("it has no image data");
			checkPixels(Buffer.concat(imageData), header);
			return { width: header.width, height: header.height };
		} else {
			// Everything else belongs before the image data, once, and in a known form.
			if (imageData.length > 0) {
				imageDataEnded = true;
				throw new Error(`it has a ${type} chunk after its image data`);
			}
			if (seen.has(type)) throw new Error(`it has two ${type} chunks`);
			if (type === "PLTE") {
				if (!header.palette) throw new Error("it has a palette its colour type does not allow");
				if (length === 0 || length % 3 !== 0 || length > 768) throw new Error("its palette is malformed");
			} else if (ANCILLARY_CHUNKS[type] === undefined) {
				throw new Error(`it contains a ${type} chunk, which a plain still image does not have`);
			} else if (ANCILLARY_CHUNKS[type] !== length) {
				throw new Error(`its ${type} chunk is malformed`);
			}
		}
		seen.add(type);
		offset = end;
	}
}

/** Decompresses the image data and checks that it is exactly the rows the header describes. */
function checkPixels(compressed: Buffer, header: { height: number; rowBytes: number }): void {
	const expected = header.height * header.rowBytes;
	let pixels: Buffer;
	try {
		// One byte over, so that data longer than the image is seen and not cut off silently.
		pixels = inflateSync(compressed, { maxOutputLength: expected + 1 });
	} catch {
		throw new Error("its image data does not decompress");
	}
	// A complete stream stops being one when its last byte is taken away. If it still
	// decompresses, the stream ended earlier and something else follows it.
	let endsAtTheEnd = false;
	try {
		inflateSync(compressed.subarray(0, compressed.length - 1), { maxOutputLength: expected + 1 });
	} catch {
		endsAtTheEnd = true;
	}
	if (!endsAtTheEnd) throw new Error("its image data has bytes left over after the image");
	if (pixels.length !== expected) throw new Error("its image data is not the size its header describes");
	for (let row = 0; row < header.height; row += 1) {
		if ((pixels[row * header.rowBytes] as number) > 4) throw new Error("its image data is malformed");
	}
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isCount(value: unknown): value is number {
	return typeof value === "number" && Number.isInteger(value) && value > 0;
}

/** True for text that is, or carries, an encoded image. */
function looksLikeImage(text: string): boolean {
	// "iVBORw0KGgo" is how every base64 PNG begins.
	return text.includes("iVBORw0KGgo") || /data:image\//i.test(text);
}

/**
 * Removes anything image-like from a value that is about to be passed on as text: every
 * `images` and `png_base64` field at any depth, and any string that is an encoded image.
 * Returns the cleaned value and whether anything was removed.
 */
export function scrub(value: unknown, depth = 0): { value: unknown; removed: boolean } {
	if (typeof value === "string") return looksLikeImage(value) ? { value: REMOVED, removed: true } : { value, removed: false };
	if (value === null || typeof value !== "object") return { value, removed: false };
	if (depth > 32) return { value: REMOVED, removed: true };
	let removed = false;
	if (Array.isArray(value)) {
		const items = value.map((item) => {
			const cleaned = scrub(item, depth + 1);
			removed ||= cleaned.removed;
			return cleaned.value;
		});
		return { value: items, removed };
	}
	const result: Record<string, unknown> = {};
	for (const [key, item] of Object.entries(value)) {
		// A field is dropped whole when it is named for images or its name itself carries one.
		if (key === "images" || key === "png_base64" || looksLikeImage(key)) {
			removed = true;
			continue;
		}
		const cleaned = scrub(item, depth + 1);
		removed ||= cleaned.removed;
		result[key] = cleaned.value;
	}
	return { value: result, removed };
}

/** The longest edge the caller asked for, as the tool's input schema defines it. */
function requestedEdge(params: Record<string, unknown>): number {
	const edge = params.max_edge;
	if (typeof edge === "number" && Number.isInteger(edge) && edge >= MIN_IMAGE_EDGE && edge <= MAX_IMAGE_EDGE) return edge;
	return DEFAULT_IMAGE_EDGE;
}

function checkImage(capture: Record<string, unknown>, images: unknown, maxEdge: number): string {
	if (!Array.isArray(images) || images.length !== 1) throw new Error("exactly one image was expected");
	const entry: unknown = images[0];
	if (!isRecord(entry) || Object.keys(entry).length !== 1 || typeof entry.png_base64 !== "string") {
		throw new Error("the image is not in the expected form");
	}
	const text = entry.png_base64;
	if (capture.format !== "png") throw new Error("it is not reported as a PNG");
	const { width, height, bytes } = capture;
	if (!isCount(width) || !isCount(height) || !isCount(bytes)) throw new Error("its size was not reported");
	if (width > maxEdge || height > maxEdge) throw new Error(`it is reported as ${width} by ${height} pixels, over the ${maxEdge} asked for`);
	if (bytes > MAX_IMAGE_BYTES) throw new Error("it is over the size limit");
	if (text.length !== Math.ceil(bytes / 3) * 4 || !BASE64.test(text)) throw new Error("its encoding does not match its reported size");
	const data = Buffer.from(text, "base64");
	if (data.length !== bytes || data.toString("base64") !== text) throw new Error("its encoding is malformed");
	const actual = inspectPng(data);
	if (actual.width !== width || actual.height !== height) {
		throw new Error(`it is ${actual.width} by ${actual.height} pixels, not the ${width} by ${height} reported`);
	}
	return text;
}

/**
 * Separates a plugin result into the structured payload and, at most, one image.
 * An image passes only for a preview that asked for a screenshot and reports success,
 * and only if it is a single complete PNG matching its reported size and the limits.
 * Everything image-like is removed from the payload whatever the method, and a preview
 * is told why its screenshot is unavailable.
 */
export function screenResult(method: string, params: unknown, result: unknown): { payload: unknown; image?: string } {
	const input = isRecord(params) ? params : {};
	const images = isRecord(result) ? result.images : undefined;
	const original = isRecord(result) ? result.capture : undefined;
	const cleaned = scrub(result);
	if (!isRecord(cleaned.value)) return { payload: cleaned.value };
	const payload = cleaned.value;
	const refuse = (reason: string) => {
		payload.capture = { status: "unavailable", reason };
		return { payload };
	};
	const claimsSuccess = isRecord(original) && original.status === "ok";

	if (method !== IMAGE_METHOD) {
		// No other method returns images. A claim of one is not passed on either.
		if (claimsSuccess) return refuse("the relay dropped a screenshot from a method that does not take them");
		return { payload };
	}
	if (input.capture !== true) {
		if (cleaned.removed || claimsSuccess) return refuse("the relay dropped a screenshot that was not asked for");
		return { payload };
	}
	if (!isRecord(original) || typeof original.status !== "string") return refuse("no screenshot result was returned");
	if (original.status !== "ok") return { payload };
	try {
		return { payload, image: checkImage(original, images, requestedEdge(input)) };
	} catch (error) {
		return refuse(`the relay rejected the screenshot: ${error instanceof Error ? error.message : String(error)}`);
	}
}
