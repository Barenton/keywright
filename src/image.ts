// The relay's own check on screenshots. The plugin already limits what it sends; this
// repeats the limits on the other side of the connection, so that nothing the plugin
// (or anything speaking for it) returns can reach a model as an image unless it was
// asked for and is one complete PNG of the reported size.

export const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
export const MAX_IMAGE_EDGE = 1536;
export const MIN_IMAGE_EDGE = 64;
export const DEFAULT_IMAGE_EDGE = 768;
/** The only method that may return an image, and only when its `capture` argument is true. */
export const IMAGE_METHOD = "preview_animation";

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

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
 * Reads the size of a PNG after checking that it is complete: the signature, a header
 * chunk first, every chunk inside the data with a correct checksum, image data present,
 * and the end chunk exactly at the end. Throws with the reason otherwise.
 */
export function inspectPng(data: Buffer): { width: number; height: number } {
	if (data.length < 8 || !data.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error("it is not a PNG");
	let offset = 8;
	let size: { width: number; height: number } | undefined;
	let hasImageData = false;
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
		if (size === undefined) {
			if (type !== "IHDR" || length !== 13) throw new Error("it does not start with a header");
			size = { width: data.readUInt32BE(offset + 8), height: data.readUInt32BE(offset + 12) };
			const bitDepth = data[offset + 16] as number;
			const colourType = data[offset + 17] as number;
			if (![1, 2, 4, 8, 16].includes(bitDepth) || ![0, 2, 3, 4, 6].includes(colourType)) {
				throw new Error("its header is malformed");
			}
			if (data[offset + 18] !== 0 || data[offset + 19] !== 0 || (data[offset + 20] as number) > 1) {
				throw new Error("its header is malformed");
			}
		} else if (type === "IHDR") {
			throw new Error("it has two headers");
		} else if (type === "IDAT") {
			hasImageData = true;
		} else if (type === "IEND") {
			if (length !== 0) throw new Error("its end chunk is malformed");
			if (end !== data.length) throw new Error("it has data after its end");
			if (!hasImageData) throw new Error("it has no image data");
			return size;
		}
		offset = end;
	}
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isCount(value: unknown): value is number {
	return typeof value === "number" && Number.isInteger(value) && value > 0;
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
 * Anything else is removed, and a preview is told why its screenshot is unavailable.
 */
export function screenResult(method: string, params: unknown, result: unknown): { payload: unknown; image?: string } {
	if (!isRecord(result)) return { payload: result };
	const { images, ...payload } = result;
	const input = isRecord(params) ? params : {};
	const capture = payload.capture;
	const claimsImage = images !== undefined || (isRecord(capture) && capture.status === "ok");

	if (method !== IMAGE_METHOD) {
		// No other method returns images; whatever came is not passed on.
		return { payload };
	}
	if (input.capture !== true) {
		if (claimsImage) payload.capture = { status: "unavailable", reason: "the relay dropped a screenshot that was not asked for" };
		return { payload };
	}
	if (!isRecord(capture) || capture.status !== "ok") {
		if (!isRecord(capture) || typeof capture.status !== "string") {
			payload.capture = { status: "unavailable", reason: "no screenshot result was returned" };
		}
		return { payload };
	}
	try {
		return { payload, image: checkImage(capture, images, requestedEdge(input)) };
	} catch (error) {
		payload.capture = {
			status: "unavailable",
			reason: `the relay rejected the screenshot: ${error instanceof Error ? error.message : String(error)}`,
		};
		return { payload };
	}
}
