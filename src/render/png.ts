// Encoding a picture as a PNG.
import { deflateSync } from "node:zlib";
import { crc32 } from "./image.js";

function chunk(type: string, body: Buffer): Buffer {
	const head = Buffer.alloc(8);
	head.writeUInt32BE(body.length, 0);
	head.write(type, 4, "latin1");
	const typed = Buffer.concat([head.subarray(4), body]);
	const tail = Buffer.alloc(4);
	tail.writeUInt32BE(crc32(typed, 0, typed.length), 0);
	return Buffer.concat([head, body, tail]);
}

/** Encodes rows of red, green and blue bytes as a PNG. */
export function encodePng(width: number, height: number, rgb: Uint8Array): Buffer {
	const header = Buffer.alloc(13);
	header.writeUInt32BE(width, 0);
	header.writeUInt32BE(height, 4);
	header[8] = 8;
	header[9] = 2;
	const rows = Buffer.alloc((width * 3 + 1) * height);
	for (let y = 0; y < height; y += 1) {
		rows.set(rgb.subarray(y * width * 3, (y + 1) * width * 3), y * (width * 3 + 1) + 1);
	}
	return Buffer.concat([
		Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
		chunk("IHDR", header),
		chunk("IDAT", deflateSync(rows, { level: 9 })),
		chunk("IEND", Buffer.alloc(0)),
	]);
}
