// Draws a picture of a pose from data alone.
//
// The plugin works out where each part of the rig is for the sampled joint transforms
// and sends those positions and sizes. This module draws them as boxes into a PNG. No
// part of Studio's viewport is involved: the picture cannot contain anything but the
// boxes it was given, and the same input always produces the same bytes.
//
// It shows the pose, not what the rig looks like. Every part is a plain box of its
// bounding size. The rig's left side is blue and its right side orange, the head carries
// a dark mark on its front, and each view is drawn without perspective at one common scale.

import { deflateSync } from "node:zlib";
import { crc32, inspectPng } from "./image.js";

export const VIEWS = ["front", "back", "left", "right", "top", "three_quarter"] as const;
export type ViewName = (typeof VIEWS)[number];
export const DEFAULT_VIEWS: ViewName[] = ["three_quarter"];
export const DEFAULT_TILE = 384;
export const MIN_TILE = 128;
export const MAX_TILE = 768;
export const MAX_VIEWS = 4;
export const MAX_WIDTH = 1536;
export const MAX_PARTS = 64;
/** Largest box edge and furthest position accepted, in studs. */
const MAX_SIZE = 200;
const MAX_REACH = 2000;

export const LEGEND =
	"A schematic drawn from the sampled joint positions, not a Studio screenshot. Each part is a box of its bounding size. Blue is the rig's left side, orange its right; the dark mark on the head is its front. Views are side by side in the order listed, without perspective, at one scale.";

export interface PosePart {
	name: string;
	size: [number, number, number];
	/** Position, then the nine entries of the rotation matrix, row by row. */
	cframe: number[];
}

type Vec = [number, number, number];
type Colour = [number, number, number];

const BACKGROUND: Colour = [245, 245, 245];
const SEPARATOR: Colour = [214, 214, 214];
const LEFT: Colour = [66, 133, 222];
const RIGHT: Colour = [226, 112, 58];
const HEAD: Colour = [236, 200, 110];
const BODY: Colour = [178, 178, 178];
const MARK: Colour = [58, 58, 58];

const add = (a: Vec, b: Vec): Vec => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a: Vec, b: Vec): Vec => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const scale = (a: Vec, k: number): Vec => [a[0] * k, a[1] * k, a[2] * k];
const dot = (a: Vec, b: Vec): number => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a: Vec, b: Vec): Vec => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const unit = (a: Vec): Vec => scale(a, 1 / Math.hypot(a[0], a[1], a[2]));

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** Checks what the plugin sent and returns it as parts. Throws with the reason otherwise. */
export function parsePose(value: unknown): PosePart[] {
	if (!isRecord(value) || !Array.isArray(value.parts)) throw new Error("no pose was returned");
	if (value.parts.length === 0 || value.parts.length > MAX_PARTS) throw new Error("the pose has an unusable number of parts");
	return value.parts.map((entry: unknown): PosePart => {
		if (!isRecord(entry) || typeof entry.name !== "string" || entry.name.length === 0 || entry.name.length > 64) {
			throw new Error("a part of the pose has no usable name");
		}
		const { size, cframe } = entry;
		const numbers = (list: unknown, count: number): list is number[] =>
			Array.isArray(list) && list.length === count && list.every((item) => typeof item === "number" && Number.isFinite(item));
		if (!numbers(size, 3) || size.some((edge) => edge <= 0 || edge > MAX_SIZE)) {
			throw new Error(`the size of "${entry.name}" is not usable`);
		}
		if (!numbers(cframe, 12) || cframe.slice(0, 3).some((item) => Math.abs(item) > MAX_REACH)) {
			throw new Error(`the position of "${entry.name}" is not usable`);
		}
		if (cframe.slice(3).some((item) => Math.abs(item) > 1.001)) throw new Error(`the rotation of "${entry.name}" is not usable`);
		return { name: entry.name, size: [size[0] as number, size[1] as number, size[2] as number], cframe };
	});
}

interface Box {
	centre: Vec;
	/** The box's own three directions, each scaled to half its length along that direction. */
	half: [Vec, Vec, Vec];
	colour: Colour;
}

function colourOf(name: string): Colour {
	if (name.startsWith("Left")) return LEFT;
	if (name.startsWith("Right")) return RIGHT;
	if (name === "Head") return HEAD;
	return BODY;
}

function boxesOf(parts: PosePart[]): Box[] {
	const boxes: Box[] = [];
	for (const part of parts) {
		const c = part.cframe as number[];
		const centre: Vec = [c[0] as number, c[1] as number, c[2] as number];
		// The columns of the rotation matrix are the part's own right, up and back directions.
		const axes: [Vec, Vec, Vec] = [
			[c[3] as number, c[6] as number, c[9] as number],
			[c[4] as number, c[7] as number, c[10] as number],
			[c[5] as number, c[8] as number, c[11] as number],
		];
		const [sx, sy, sz] = part.size;
		boxes.push({ centre, half: [scale(axes[0], sx / 2), scale(axes[1], sy / 2), scale(axes[2], sz / 2)], colour: colourOf(part.name) });
		if (part.name === "Head") {
			// A rig faces along its own negative Z. The mark sits on that face of the head.
			const depth = sz * 0.2;
			boxes.push({
				centre: add(centre, scale(axes[2], -(sz / 2 + depth / 2))),
				half: [scale(axes[0], sx * 0.16), scale(axes[1], sy * 0.12), scale(axes[2], depth / 2)],
				colour: MARK,
			});
		}
	}
	return boxes;
}

function cornersOf(box: Box): Vec[] {
	const corners: Vec[] = [];
	for (const i of [-1, 1]) for (const j of [-1, 1]) for (const k of [-1, 1]) {
		corners.push(add(box.centre, add(scale(box.half[0], i), add(scale(box.half[1], j), scale(box.half[2], k)))));
	}
	return corners;
}

/** Where the camera stands relative to the rig for each view, and which way is up in the picture. */
function basisOf(view: ViewName): { right: Vec; up: Vec; forward: Vec } {
	if (view === "top") return { right: [1, 0, 0], up: [0, 0, -1], forward: [0, -1, 0] };
	const toCamera: Record<Exclude<ViewName, "top">, Vec> = {
		front: [0, 0, -1],
		back: [0, 0, 1],
		left: [-1, 0, 0],
		right: [1, 0, 0],
		three_quarter: [0.6, 0.45, -1],
	};
	const forward = unit(scale(toCamera[view], -1));
	const right = unit(cross(forward, [0, 1, 0]));
	return { right, up: cross(right, forward), forward };
}

class Tile {
	readonly pixels: Uint8Array;
	readonly depth: Float32Array;
	constructor(readonly size: number) {
		this.pixels = new Uint8Array(size * size * 3);
		for (let i = 0; i < size * size; i += 1) this.pixels.set(BACKGROUND, i * 3);
		this.depth = new Float32Array(size * size).fill(Infinity);
	}

	private put(x: number, y: number, z: number, colour: Colour, bias: number): void {
		if (x < 0 || y < 0 || x >= this.size || y >= this.size) return;
		const index = y * this.size + x;
		if (z - bias > (this.depth[index] as number)) return;
		if (bias === 0) this.depth[index] = z;
		this.pixels.set(colour, index * 3);
	}

	/** Fills a triangle given in pixel coordinates with a depth at each corner. */
	triangle(a: Vec, b: Vec, c: Vec, colour: Colour): void {
		const area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
		if (Math.abs(area) < 1e-9) return;
		const minX = Math.max(0, Math.floor(Math.min(a[0], b[0], c[0])));
		const maxX = Math.min(this.size - 1, Math.ceil(Math.max(a[0], b[0], c[0])));
		const minY = Math.max(0, Math.floor(Math.min(a[1], b[1], c[1])));
		const maxY = Math.min(this.size - 1, Math.ceil(Math.max(a[1], b[1], c[1])));
		for (let y = minY; y <= maxY; y += 1) {
			for (let x = minX; x <= maxX; x += 1) {
				const px = x + 0.5;
				const py = y + 0.5;
				const w0 = ((b[0] - px) * (c[1] - py) - (b[1] - py) * (c[0] - px)) / area;
				const w1 = ((c[0] - px) * (a[1] - py) - (c[1] - py) * (a[0] - px)) / area;
				const w2 = 1 - w0 - w1;
				if (w0 < 0 || w1 < 0 || w2 < 0) continue;
				this.put(x, y, w0 * a[2] + w1 * b[2] + w2 * c[2], colour, 0);
			}
		}
	}

	/** Draws a line that shows only where nothing nearer has been drawn. */
	line(a: Vec, b: Vec, colour: Colour, thickness: number, bias: number): void {
		const steps = Math.max(1, Math.ceil(Math.max(Math.abs(b[0] - a[0]), Math.abs(b[1] - a[1]))));
		for (let step = 0; step <= steps; step += 1) {
			const t = step / steps;
			const x = Math.floor(a[0] + (b[0] - a[0]) * t);
			const y = Math.floor(a[1] + (b[1] - a[1]) * t);
			const z = a[2] + (b[2] - a[2]) * t;
			for (let dx = 0; dx < thickness; dx += 1) for (let dy = 0; dy < thickness; dy += 1) this.put(x + dx, y + dy, z, colour, bias);
		}
	}
}

function drawView(boxes: Box[], view: ViewName, size: number, centre: Vec, pixelsPerStud: number): Tile {
	const tile = new Tile(size);
	const { right, up, forward } = basisOf(view);
	const light = unit(add(scale(forward, -0.7), add(scale(up, 0.6), scale(right, -0.35))));
	const project = (point: Vec): Vec => {
		const local = sub(point, centre);
		return [size / 2 + dot(local, right) * pixelsPerStud, size / 2 - dot(local, up) * pixelsPerStud, dot(local, forward)];
	};
	const outlines: Array<{ from: Vec; to: Vec; colour: Colour }> = [];
	for (const box of boxes) {
		for (let axis = 0; axis < 3; axis += 1) {
			for (const sign of [-1, 1]) {
				const out = scale(box.half[axis] as Vec, sign);
				const normal = unit(out);
				// Only faces turned towards the camera are drawn.
				if (dot(normal, forward) >= 0) continue;
				const u = box.half[(axis + 1) % 3] as Vec;
				const v = box.half[(axis + 2) % 3] as Vec;
				const middle = add(box.centre, out);
				const quad = [
					project(add(middle, add(u, v))),
					project(add(middle, sub(u, v))),
					project(sub(middle, add(u, v))),
					project(add(middle, sub(v, u))),
				] as [Vec, Vec, Vec, Vec];
				const shade = 0.45 + 0.55 * Math.max(0, dot(normal, light));
				const colour = box.colour.map((channel) => Math.round(channel * shade)) as Colour;
				tile.triangle(quad[0], quad[1], quad[2], colour);
				tile.triangle(quad[0], quad[2], quad[3], colour);
				const edge = box.colour.map((channel) => Math.round(channel * 0.35)) as Colour;
				for (let i = 0; i < 4; i += 1) outlines.push({ from: quad[i] as Vec, to: quad[(i + 1) % 4] as Vec, colour: edge });
			}
		}
	}
	// Outlines go on last, so that they are drawn over the faces they belong to and
	// hidden by anything nearer.
	const thickness = size >= 320 ? 2 : 1;
	for (const outline of outlines) tile.line(outline.from, outline.to, outline.colour, thickness, 0.02);
	return tile;
}

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

// How much room is left around the rig at rest, so that raised arms and long strides
// stay inside the picture without the framing having to change.
const REST_MARGIN = 1.4;

/** The middle of a set of boxes, and how far the furthest corner is from it. */
function extentOf(boxes: Box[], about?: Vec): { centre: Vec; reach: number } {
	const corners = boxes.flatMap(cornersOf);
	const low: Vec = [Infinity, Infinity, Infinity];
	const high: Vec = [-Infinity, -Infinity, -Infinity];
	for (const corner of corners) {
		for (let axis = 0; axis < 3; axis += 1) {
			low[axis] = Math.min(low[axis] as number, corner[axis] as number);
			high[axis] = Math.max(high[axis] as number, corner[axis] as number);
		}
	}
	const centre = about ?? scale(add(low, high), 0.5);
	let reach = 0;
	for (const corner of corners) reach = Math.max(reach, Math.hypot(...sub(corner, centre)));
	return { centre, reach };
}

/**
 * Draws the pose once for each view, side by side. Every view is square, `tile` pixels on
 * a side, and all share one scale.
 *
 * When the rig's rest pose is given, the picture is framed on that, with room to spare,
 * so that pictures of different poses of one rig line up and can be compared. Only a
 * pose that reaches beyond that frame widens it. Without a rest pose the picture is
 * framed on the pose itself.
 */
export function renderPose(parts: PosePart[], views: ViewName[], tile: number, rest?: PosePart[]): { png: Buffer; width: number; height: number } {
	if (views.length === 0 || views.length > MAX_VIEWS) throw new Error("between one and four views can be drawn");
	if (!Number.isInteger(tile) || tile < MIN_TILE || tile > MAX_TILE || tile * views.length > MAX_WIDTH) {
		throw new Error("the picture size is outside the limits");
	}
	return drawCells([views.map((view) => ({ parts, view }))], tile, rest, false);
}

export const MAX_FRAMES = 8;
export const MAX_STRIP_VIEWS = 2;

/**
 * Draws several poses of one rig as a filmstrip: one column for each pose, in the order
 * given, and one row for each view. Every tile has the same framing, so a part that does
 * not move is in the same place in every column.
 */
export function renderStrip(frames: PosePart[][], views: ViewName[], tile: number, rest?: PosePart[]): { png: Buffer; width: number; height: number } {
	if (frames.length < 2 || frames.length > MAX_FRAMES) throw new Error("a filmstrip has from two to eight frames");
	if (views.length === 0 || views.length > MAX_STRIP_VIEWS) throw new Error("a filmstrip is drawn from one or two views");
	if (!Number.isInteger(tile) || tile < MIN_TILE || tile > MAX_TILE || tile * frames.length > MAX_WIDTH) {
		throw new Error("the picture size is outside the limits");
	}
	return drawCells(views.map((view) => frames.map((parts) => ({ parts, view }))), tile, rest, true);
}

interface Cell {
	parts: PosePart[];
	view: ViewName;
}

/**
 * Draws a grid of tiles, each one pose seen from one direction, all with one framing.
 * `tight` frames the grid to hold just its own poses and the rest pose; otherwise room is
 * left around the rest pose so that separate pictures line up with each other.
 */
function drawCells(cells: Cell[][], tile: number, rest: PosePart[] | undefined, tight: boolean): { png: Buffer; width: number; height: number } {
	const drawn = cells.map((row) => row.map((cell) => boxesOf(cell.parts)));
	const all = drawn.flat(2);
	let { centre, reach } = extentOf(all);
	if (rest && rest.length > 0) {
		const frame = extentOf(boxesOf(rest));
		centre = frame.centre;
		reach = tight ? Math.max(frame.reach, extentOf(all, centre).reach) * 1.05 : Math.max(frame.reach * REST_MARGIN, extentOf(all, centre).reach);
	}
	const pixelsPerStud = (tile / 2 - tile * 0.06) / Math.max(reach, 0.5);

	const rows = cells.length;
	const columns = (cells[0] as Cell[]).length;
	const width = tile * columns;
	const height = tile * rows;
	const image = new Uint8Array(width * height * 3);
	for (let row = 0; row < rows; row += 1) {
		for (let column = 0; column < columns; column += 1) {
			const picture = drawView((drawn[row] as Box[][])[column] as Box[], ((cells[row] as Cell[])[column] as Cell).view, tile, centre, pixelsPerStud);
			for (let y = 0; y < tile; y += 1) {
				const start = ((row * tile + y) * width + column * tile) * 3;
				image.set(picture.pixels.subarray(y * tile * 3, (y + 1) * tile * 3), start);
				if (column > 0) image.set(SEPARATOR, start);
			}
			// A line between rows, so that two clips one above the other are told apart.
			if (row > 0) for (let x = 0; x < tile; x += 1) image.set(SEPARATOR, (row * tile * width + column * tile + x) * 3);
		}
	}
	const png = encodePng(width, height, image);
	// What is sent on is held to the same rules as any other image the relay passes.
	const checked = inspectPng(png);
	if (checked.width !== width || checked.height !== height) throw new Error("the picture did not encode correctly");
	return { png, width, height };
}

/**
 * Draws two clips at the same moments, one above the other: the first along the top row,
 * the second along the bottom, a column for each moment, all from one direction.
 */
export function renderComparison(first: PosePart[][], second: PosePart[][], view: ViewName, tile: number, rest?: PosePart[]): { png: Buffer; width: number; height: number } {
	if (first.length < 2 || first.length > MAX_FRAMES || second.length !== first.length) throw new Error("a comparison has from two to eight frames of each clip");
	if (!Number.isInteger(tile) || tile < MIN_TILE || tile > MAX_TILE || tile * first.length > MAX_WIDTH) {
		throw new Error("the picture size is outside the limits");
	}
	return drawCells([first, second].map((frames) => frames.map((parts) => ({ parts, view }))), tile, rest, true);
}

// --- Motion: the paths parts travel, and how fast, over a whole clip -------------------
//
// A pose picture shows where the rig is at one moment. What makes motion read as alive
// or stiff is between the moments: whether a hand travels in a curve, whether its speed
// builds and fades or jumps, whether the parts of the body start and stop together.
// These are drawn from the same sampled positions, many more of them.

export const MIN_SAMPLES = 9;
export const MAX_SAMPLES = 48;
export const MAX_TRACKS = 8;

/** A colour for each tracked part, in order, with the name it is described by. */
const TRACK_COLOURS: Array<{ name: string; rgb: Colour }> = [
	{ name: "red", rgb: [214, 48, 49] },
	{ name: "blue", rgb: [39, 110, 214] },
	{ name: "green", rgb: [34, 150, 76] },
	{ name: "purple", rgb: [142, 68, 173] },
	{ name: "orange", rgb: [230, 126, 34] },
	{ name: "teal", rgb: [22, 160, 160] },
	{ name: "brown", rgb: [133, 87, 35] },
	{ name: "black", rgb: [45, 45, 45] },
];

export interface Motion {
	/** The time of each sample, in order. */
	times: number[];
	/** The clip's keyframe times. */
	keyframes: number[];
	/** For each tracked part, where its middle is at each sample, and how high its lowest point is when known. */
	parts: Array<{ name: string; positions: Vec[]; lowest?: number[] }>;
}

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

/** Checks sampled motion from a plugin and returns it in a known form. */
export function parseMotion(value: unknown): Motion {
	if (!isRecord(value) || !Array.isArray(value.times) || !isRecord(value.parts)) throw new Error("no motion was returned");
	const times = value.times;
	if (times.length < 2 || times.length > MAX_SAMPLES || !times.every(finite)) throw new Error("the motion has an unusable number of samples");
	for (let index = 1; index < times.length; index += 1) {
		if (!((times[index] as number) > (times[index - 1] as number))) throw new Error("the samples are not in order of time");
	}
	const keyframes = Array.isArray(value.keyframes) ? value.keyframes.filter(finite).slice(0, 2000) : [];
	const names = Object.keys(value.parts).sort();
	if (names.length === 0 || names.length > MAX_TRACKS) throw new Error("the motion tracks an unusable number of parts");
	const parts: Motion["parts"] = names.map((name) => {
		const positions = (value.parts as Record<string, unknown>)[name];
		if (name.length > 64 || !Array.isArray(positions) || positions.length !== times.length) throw new Error(`the path of "${name}" is not usable`);
		return {
			name,
			positions: positions.map((position: unknown): Vec => {
				if (!Array.isArray(position) || position.length !== 3 || !position.every((item) => finite(item) && Math.abs(item) <= MAX_REACH)) {
					throw new Error(`the path of "${name}" is not usable`);
				}
				return [position[0] as number, position[1] as number, position[2] as number];
			}),
		};
	});
	// The height of each part's lowest point at each sample, from a plugin that sends it.
	const lowest = isRecord(value.lowest) ? value.lowest : {};
	for (const part of parts) {
		const heights = lowest[part.name];
		if (Array.isArray(heights) && heights.length === times.length && heights.every((item) => finite(item) && Math.abs(item) <= MAX_REACH)) {
			part.lowest = heights as number[];
		}
	}
	return { times: times as number[], keyframes, parts };
}

const hundredths = (value: number) => Math.round(value * 100) / 100;

/** The speed of a part between each pair of neighbouring samples, in studs per second. */
function speedsOf(motion: Motion, positions: Vec[]): number[] {
	const speeds: number[] = [];
	for (let index = 1; index < positions.length; index += 1) {
		const seconds = (motion.times[index] as number) - (motion.times[index - 1] as number);
		speeds.push(Math.hypot(...sub(positions[index] as Vec, positions[index - 1] as Vec)) / seconds);
	}
	return speeds;
}

/**
 * What the motion amounts to, in numbers, for each tracked part: how far it travels and
 * how far it ends from where it began; its top speed and when; when it starts and stops
 * moving; the stretches in between where it stands still; how sharply its speed changes
 * from one sample to the next at worst; and how far its path bows away from a straight
 * line. Parts that all start and stop at the same times move as one block; a large jump
 * in speed is a corner in the motion; a path that does not bow is a straight line.
 */
export function summariseMotion(motion: Motion): Record<string, unknown> {
	const summary: Record<string, unknown> = {};
	for (const part of motion.parts) {
		const speeds = speedsOf(motion, part.positions);
		const peak = Math.max(...speeds);
		// Where the part comes lowest, and when: how near the floor it gets.
		const low: Record<string, number> = {};
		if (part.lowest) {
			const least = Math.min(...part.lowest);
			low.lowest = Math.round(least * 1000) / 1000;
			low.lowest_time = hundredths(motion.times[part.lowest.indexOf(least)] as number);
		}
		let path = 0;
		for (let index = 1; index < part.positions.length; index += 1) path += Math.hypot(...sub(part.positions[index] as Vec, part.positions[index - 1] as Vec));
		const first = part.positions[0] as Vec;
		const last = part.positions[part.positions.length - 1] as Vec;
		if (peak < 0.05) {
			summary[part.name] = { path: hundredths(path), still: true, ...low };
			continue;
		}
		// Moving means faster than a twentieth of its own top speed.
		const moving = speeds.map((speed) => speed > peak * 0.05);
		const start = moving.indexOf(true);
		const end = moving.lastIndexOf(true);
		const holds: Array<[number, number]> = [];
		for (let index = start; index <= end; index += 1) {
			if (moving[index]) continue;
			let until = index;
			while (until + 1 <= end && !moving[until + 1]) until += 1;
			holds.push([hundredths(motion.times[index] as number), hundredths(motion.times[until + 1] as number)]);
			index = until;
		}
		let jump = 0;
		let jumpAt = 0;
		for (let index = 1; index < speeds.length; index += 1) {
			const change = Math.abs((speeds[index] as number) - (speeds[index - 1] as number));
			if (change > jump) [jump, jumpAt] = [change, motion.times[index] as number];
		}
		// How far the path strays from the straight line to the point furthest from its start.
		let far = first;
		for (const position of part.positions) if (Math.hypot(...sub(position, first)) > Math.hypot(...sub(far, first))) far = position;
		const chord = sub(far, first);
		const length = Math.hypot(...chord);
		let bow = 0;
		if (length > 1e-6) {
			for (const position of part.positions) {
				const offset = sub(position, first);
				const along = dot(offset, chord) / length;
				bow = Math.max(bow, Math.sqrt(Math.max(0, dot(offset, offset) - along * along)));
			}
		}
		const fastest = speeds.indexOf(peak);
		summary[part.name] = {
			path: hundredths(path),
			net: hundredths(Math.hypot(...sub(last, first))),
			peak_speed: hundredths(peak),
			peak_time: hundredths(((motion.times[fastest] as number) + (motion.times[fastest + 1] as number)) / 2),
			starts: hundredths(motion.times[start] as number),
			stops: hundredths(motion.times[end + 1] as number),
			holds: holds.slice(0, 6),
			largest_speed_jump: hundredths(jump),
			largest_speed_jump_time: hundredths(jumpAt),
			bow: hundredths(bow),
			...low,
		};
	}
	return summary;
}

/** A plain picture to draw a chart on. */
class Canvas {
	readonly pixels: Uint8Array;
	constructor(
		readonly width: number,
		readonly height: number,
	) {
		this.pixels = new Uint8Array(width * height * 3);
		for (let index = 0; index < width * height; index += 1) this.pixels.set(BACKGROUND, index * 3);
	}
	rect(left: number, top: number, right: number, bottom: number, colour: Colour): void {
		for (let y = Math.max(0, Math.floor(top)); y < Math.min(this.height, Math.ceil(bottom)); y += 1) {
			for (let x = Math.max(0, Math.floor(left)); x < Math.min(this.width, Math.ceil(right)); x += 1) this.pixels.set(colour, (y * this.width + x) * 3);
		}
	}
}

/**
 * Draws the motion as one picture. On the left, the rig at the first sample, with the
 * path of each tracked part over it: a line in the part's colour with a dot at every
 * sample, so that dots far apart mean fast and dots bunched together mean slow. On the
 * right, a row for each part in the same colour: its speed across the clip, all rows to
 * one scale, with a grey line at each keyframe.
 */
export function renderMotion(motion: Motion, pose: PosePart[], view: ViewName, size: number, rest?: PosePart[]): { png: Buffer; width: number; height: number } {
	if (!Number.isInteger(size) || size < MIN_TILE || size > MAX_TILE) throw new Error("the picture size is outside the limits");
	const boxes = boxesOf(pose);
	const points = motion.parts.flatMap((part) => part.positions);
	let { centre } = extentOf(boxes);
	if (rest && rest.length > 0) centre = extentOf(boxesOf(rest)).centre;
	let reach = extentOf(boxes, centre).reach;
	for (const point of points) reach = Math.max(reach, Math.hypot(...sub(point, centre)));
	const pixelsPerStud = (size / 2 - size * 0.06) / Math.max(reach * 1.03, 0.5);
	const tile = drawView(boxes, view, size, centre, pixelsPerStud);
	const { right, up } = basisOf(view);
	// Paths are drawn over everything: they are about the motion, not about what hides what.
	const place = (point: Vec): Vec => {
		const local = sub(point, centre);
		return [size / 2 + dot(local, right) * pixelsPerStud, size / 2 - dot(local, up) * pixelsPerStud, -1e9];
	};
	motion.parts.forEach((part, index) => {
		const colour = (TRACK_COLOURS[index % TRACK_COLOURS.length] as { rgb: Colour }).rgb;
		const path = part.positions.map(place);
		for (let step = 1; step < path.length; step += 1) tile.line(path[step - 1] as Vec, path[step] as Vec, colour, 1, 1);
		for (const sample of path) tile.line([sample[0] - 1, sample[1] - 1, sample[2]], [sample[0] - 1, sample[1] - 1, sample[2]], colour, 3, 1);
	});

	const chartWidth = Math.min(MAX_WIDTH - size, size * 2);
	const chart = new Canvas(chartWidth, size);
	const rowHeight = size / motion.parts.length;
	const start = motion.times[0] as number;
	const span = (motion.times[motion.times.length - 1] as number) - start;
	const margin = 6;
	const across = (time: number) => margin + ((time - start) / span) * (chartWidth - 2 * margin);
	const speeds = motion.parts.map((part) => speedsOf(motion, part.positions));
	const top = Math.max(0.05, ...speeds.flat());
	for (const keyframe of motion.keyframes) {
		if (keyframe >= start && keyframe <= start + span) chart.rect(across(keyframe), 0, across(keyframe) + 1, size, SEPARATOR);
	}
	speeds.forEach((row, index) => {
		const colour = (TRACK_COLOURS[index % TRACK_COLOURS.length] as { rgb: Colour }).rgb;
		const floor = (index + 1) * rowHeight - 3;
		const room = rowHeight - 8;
		chart.rect(0, floor, chartWidth, floor + 1, [150, 150, 150]);
		row.forEach((speed, sample) => {
			// One bar for each stretch between two samples, as tall as the speed over it.
			chart.rect(across(motion.times[sample] as number), floor - (speed / top) * room, across(motion.times[sample + 1] as number), floor, colour);
		});
	});

	const width = size + chartWidth;
	const image = new Uint8Array(width * size * 3);
	for (let y = 0; y < size; y += 1) {
		image.set(tile.pixels.subarray(y * size * 3, (y + 1) * size * 3), y * width * 3);
		image.set(chart.pixels.subarray(y * chartWidth * 3, (y + 1) * chartWidth * 3), (y * width + size) * 3);
		image.set(SEPARATOR, (y * width + size) * 3);
	}
	const png = encodePng(width, size, image);
	const checked = inspectPng(png);
	if (checked.width !== width || checked.height !== size) throw new Error("the picture did not encode correctly");
	return { png, width, height: size };
}

/** Which colour each tracked part is drawn in, in the order of the chart's rows. */
export function trackColours(motion: Motion): Array<{ part: string; colour: string }> {
	return motion.parts.map((part, index) => ({ part: part.name, colour: (TRACK_COLOURS[index % TRACK_COLOURS.length] as { name: string }).name }));
}

/**
 * Takes the pose out of a preview's result and, when a picture was asked for, draws it.
 * The pose data itself is never passed on. Returns the payload with a `render` entry
 * saying what was drawn, or why nothing was, and the picture as base64 when there is one.
 */
export function renderResult(params: unknown, payload: unknown): { payload: unknown; image?: string } {
	if (!isRecord(payload)) return { payload };
	const { pose, ...rest } = payload;
	const input = isRecord(params) ? params : {};
	// Sampled motion is always boiled down to a summary: the raw positions are many, and
	// are what the picture is for.
	let motion: Motion | undefined;
	if (rest.motion !== undefined) {
		try {
			motion = parseMotion(rest.motion);
			rest.motion = { samples: motion.times.length, from: motion.times[0], to: motion.times[motion.times.length - 1], parts: summariseMotion(motion) };
		} catch (error) {
			rest.motion = { status: "unavailable", reason: error instanceof Error ? error.message : String(error) };
		}
	}
	if (input.render !== true) return { payload: rest };
	try {
		const requested = Array.isArray(input.views) ? input.views : DEFAULT_VIEWS;
		const views = requested.filter((view): view is ViewName => (VIEWS as readonly unknown[]).includes(view)).slice(0, MAX_VIEWS);
		if (views.length === 0 || views.length !== requested.length) throw new Error("the views asked for are not ones that can be drawn");
		const asked = input.render_size;
		const size = typeof asked === "number" && Number.isInteger(asked) && asked >= MIN_TILE && asked <= MAX_TILE ? asked : DEFAULT_TILE;
		// A plugin from before rest poses were sent has none; the picture is then framed on the pose.
		const resting = isRecord(pose) && Array.isArray(pose.rest) ? parsePose({ parts: pose.rest }) : undefined;
		if (motion) {
			const view = views[0] as ViewName;
			const drawn = renderMotion(motion, parsePose(pose), view, Math.min(size, 512), resting);
			rest.render = {
				status: "ok",
				layout: "left: the rig at the first sample with each tracked part's path over it, a dot at every sample, so dots far apart mean fast. Right: one row for each part, its speed across the clip, all rows to one scale, grey lines at the keyframes",
				views: [view],
				rows: trackColours(motion),
				width: drawn.width,
				height: drawn.height,
				legend: LEGEND,
			};
			return { payload: rest, image: drawn.png.toString("base64") };
		}
		if (isRecord(pose) && Array.isArray(pose.frames)) {
			// Several moments of the clip: a filmstrip, one column for each.
			const frames = pose.frames.map((parts: unknown) => parsePose({ parts }));
			const rows = views.slice(0, MAX_STRIP_VIEWS);
			const each = Math.max(MIN_TILE, Math.min(size, Math.floor(MAX_WIDTH / Math.max(frames.length, 1))));
			if (Array.isArray(pose.compare)) {
				// The same moments of another clip: this clip along the top, that one below.
				const other = pose.compare.map((parts: unknown) => parsePose({ parts }));
				const view = rows[0] as ViewName;
				const both = renderComparison(frames, other, view, each, resting);
				rest.render = { status: "ok", layout: "one column for each time in order; top row this clip, bottom row the clip it is compared with", views: [view], frames: frames.length, width: both.width, height: both.height, legend: LEGEND };
				return { payload: rest, image: both.png.toString("base64") };
			}
			const strip = renderStrip(frames, rows, each, resting);
			rest.render = { status: "ok", layout: "one column for each time in order, one row for each view", views: rows, frames: frames.length, width: strip.width, height: strip.height, legend: LEGEND };
			return { payload: rest, image: strip.png.toString("base64") };
		}
		const tile = Math.min(size, Math.floor(MAX_WIDTH / views.length));
		const drawn = renderPose(parsePose(pose), views, tile, resting);
		rest.render = { status: "ok", views, width: drawn.width, height: drawn.height, legend: LEGEND };
		return { payload: rest, image: drawn.png.toString("base64") };
	} catch (error) {
		rest.render = { status: "unavailable", reason: error instanceof Error ? error.message : String(error) };
		return { payload: rest };
	}
}
