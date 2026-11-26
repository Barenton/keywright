// Small numbers drawn into a picture, so that a frame or a point on a path can be named
// in words: "the third frame", "the dot marked 0.267". There is no font to load; each
// character is a pattern of square dots, three wide and five high.

import type { Colour } from "./vector.js";

const GLYPHS: Record<string, string[]> = {
	"0": ["111", "101", "101", "101", "111"],
	"1": ["010", "110", "010", "010", "111"],
	"2": ["111", "001", "111", "100", "111"],
	"3": ["111", "001", "111", "001", "111"],
	"4": ["101", "101", "111", "001", "001"],
	"5": ["111", "100", "111", "001", "111"],
	"6": ["111", "100", "111", "101", "111"],
	"7": ["111", "001", "010", "010", "010"],
	"8": ["111", "101", "111", "101", "111"],
	"9": ["111", "101", "111", "001", "111"],
	".": ["0", "0", "0", "0", "1"],
};

const PAD: Colour = [255, 255, 255];

/** How wide and high a label is, in pixels, at a given size of dot. */
export function labelSize(text: string, dot: number): { width: number; height: number } {
	let columns = 0;
	for (const character of text) columns += ((GLYPHS[character] ?? GLYPHS["0"]) as string[])[0]?.length ?? 3;
	columns += Math.max(0, text.length - 1);
	return { width: (columns + 2) * dot, height: 7 * dot };
}

/**
 * Draws `text` (digits and points) with its top left at x, y, on a white pad so that it
 * reads over anything. Pixels outside the picture are skipped.
 */
export function drawLabel(pixels: Uint8Array, width: number, height: number, x: number, y: number, text: string, colour: Colour, dot: number): void {
	const set = (px: number, py: number, rgb: Colour) => {
		if (px >= 0 && py >= 0 && px < width && py < height) pixels.set(rgb, (py * width + px) * 3);
	};
	const size = labelSize(text, dot);
	for (let py = 0; py < size.height; py += 1) for (let px = 0; px < size.width; px += 1) set(x + px, y + py, PAD);
	let column = 1;
	for (const character of text) {
		const glyph = (GLYPHS[character] ?? GLYPHS["0"]) as string[];
		glyph.forEach((row, line) => {
			for (let index = 0; index < row.length; index += 1) {
				if (row[index] !== "1") continue;
				for (let dy = 0; dy < dot; dy += 1) for (let dx = 0; dx < dot; dx += 1) set(x + (column + index) * dot + dx, y + (line + 1) * dot + dy, colour);
			}
		});
		column += (glyph[0]?.length ?? 3) + 1;
	}
}

/** A time in seconds as a label: three decimals at most, with no trailing zeros. */
export function timeLabel(time: number): string {
	return String(Math.round(time * 1000) / 1000);
}

/** The size of dot that suits a tile: larger pictures get larger numbers. */
export function dotFor(tile: number): number {
	return Math.max(1, Math.round(tile / 160));
}
