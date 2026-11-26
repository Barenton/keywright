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

import { inspectPng } from "./image.js";
import { dotFor, drawLabel } from "./label.js";
import { encodePng } from "./png.js";
import { add, type Colour, cross, dot, isRecord, scale, sub, unit, type Vec } from "./vector.js";

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
export const MAX_SIZE = 200;
export const MAX_REACH = 2000;

export const LEGEND =
	"A schematic drawn from the sampled joint positions, not a Studio screenshot. Each part is a box of its bounding size. Blue is the rig's left side, orange its right; the dark mark on the head is its front. Views are side by side in the order listed, without perspective, at one scale.";

/** How parts are drawn: as boxes of their size, or with arms and legs thin so that their angles read. */
export const STYLES = ["boxes", "slim"] as const;
export type StyleName = (typeof STYLES)[number];

export const SLIM_LEGEND =
	"A schematic drawn from the sampled joint positions, not a Studio screenshot. Arms and legs are drawn thin along their length, so that their angles and bends read; the hands, feet, torso and head are boxes of their size. Blue is the rig's left side, orange its right; the dark mark on the head is its front. Views are side by side in the order listed, without perspective, at one scale.";

/** How thick a slim arm or leg is drawn, as a share of its real thickness. */
export const SLIM_THICKNESS = 0.35;

/**
 * The parts with each upper and lower arm and leg made thin: the same length along its
 * longest side, which on R15 is its own up direction but on a custom rig may not be, and a
 * share of the other two. Hands, feet, the torso and the head keep their size, so contact
 * with the floor still reads.
 */
export function slimParts(parts: PosePart[]): PosePart[] {
	return parts.map((part) => {
		if (!/(Upper|Lower)(Arm|Leg)$/.test(part.name)) return part;
		const longest = part.size.indexOf(Math.max(...part.size));
		return { ...part, size: part.size.map((edge, axis) => (axis === longest ? edge : edge * SLIM_THICKNESS)) as [number, number, number] };
	});
}

export interface PosePart {
	name: string;
	size: [number, number, number];
	/** Position, then the nine entries of the rotation matrix, row by row. */
	cframe: number[];
}

export const BACKGROUND: Colour = [245, 245, 245];
export const SEPARATOR: Colour = [214, 214, 214];
export const LEFT: Colour = [66, 133, 222];
export const RIGHT: Colour = [226, 112, 58];
export const HEAD: Colour = [236, 200, 110];
export const BODY: Colour = [178, 178, 178];
export const MARK: Colour = [58, 58, 58];

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

export interface Box {
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

export function boxesOf(parts: PosePart[]): Box[] {
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

export function cornersOf(box: Box): Vec[] {
	const corners: Vec[] = [];
	for (const i of [-1, 1]) for (const j of [-1, 1]) for (const k of [-1, 1]) {
		corners.push(add(box.centre, add(scale(box.half[0], i), add(scale(box.half[1], j), scale(box.half[2], k)))));
	}
	return corners;
}

/** Where the camera stands relative to the rig for each view, and which way is up in the picture. */
export function basisOf(view: ViewName): { right: Vec; up: Vec; forward: Vec } {
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

export class Tile {
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

/**
 * Draws boxes from one direction. Into a new tile, or over what `into` already holds: then
 * what was there before stays where these boxes don't cover it, whatever its depth.
 */
export function drawView(boxes: Box[], view: ViewName, size: number, centre: Vec, pixelsPerStud: number, into?: Tile): Tile {
	const tile = into ?? new Tile(size);
	if (into) tile.depth.fill(Infinity);
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

// How much room is left around the rig at rest, so that raised arms and long strides
// stay inside the picture without the framing having to change.
const REST_MARGIN = 1.4;

/** The middle of a set of boxes, and how far the furthest corner is from it. */
export function extentOf(boxes: Box[], about?: Vec): { centre: Vec; reach: number } {
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
export function renderStrip(frames: PosePart[][], views: ViewName[], tile: number, rest?: PosePart[], labels?: string[]): { png: Buffer; width: number; height: number } {
	if (frames.length < 2 || frames.length > MAX_FRAMES) throw new Error("a filmstrip has from two to eight frames");
	if (views.length === 0 || views.length > MAX_STRIP_VIEWS) throw new Error("a filmstrip is drawn from one or two views");
	if (!Number.isInteger(tile) || tile < MIN_TILE || tile > MAX_TILE || tile * frames.length > MAX_WIDTH) {
		throw new Error("the picture size is outside the limits");
	}
	return drawCells(views.map((view) => frames.map((parts) => ({ parts, view }))), tile, rest, true, labels ? [labels] : undefined);
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
/**
 * Where to centre a set of boxes, and at what scale, to fit them in a tile. With the rig's
 * rest pose, it is framed on that; `tight` then leaves just enough room for these boxes,
 * and otherwise room is left around the rest pose so that separate pictures line up.
 */
export function framing(all: Box[], rest: PosePart[] | undefined, tight: boolean, tile: number): { centre: Vec; pixelsPerStud: number } {
	let { centre, reach } = extentOf(all);
	if (rest && rest.length > 0) {
		const frame = extentOf(boxesOf(rest));
		centre = frame.centre;
		reach = tight ? Math.max(frame.reach, extentOf(all, centre).reach) * 1.05 : Math.max(frame.reach * REST_MARGIN, extentOf(all, centre).reach);
	}
	return { centre, pixelsPerStud: (tile / 2 - tile * 0.06) / Math.max(reach, 0.5) };
}

/** The colour a label is drawn in. */
export const LABEL: Colour = [40, 40, 40];

/** `labels` holds a row of labels for each row of cells, or none for a row. */
function drawCells(cells: Cell[][], tile: number, rest: PosePart[] | undefined, tight: boolean, labels?: Array<string[] | undefined>): { png: Buffer; width: number; height: number } {
	const drawn = cells.map((row) => row.map((cell) => boxesOf(cell.parts)));
	const { centre, pixelsPerStud } = framing(drawn.flat(2), rest, tight, tile);

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
	// Each column's time, in its top left corner, so that a frame can be named.
	const dot = dotFor(tile);
	labels?.slice(0, rows).forEach((row, index) =>
		row?.slice(0, columns).forEach((label, column) => drawLabel(image, width, height, column * tile + 3 * dot, index * tile + 3 * dot, label, LABEL, dot)),
	);
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
export function renderComparison(first: PosePart[][], second: PosePart[][], view: ViewName, tile: number, rest?: PosePart[], labels?: string[], otherLabels?: string[]): { png: Buffer; width: number; height: number } {
	if (first.length < 2 || first.length > MAX_FRAMES || second.length !== first.length) throw new Error("a comparison has from two to eight frames of each clip");
	if (!Number.isInteger(tile) || tile < MIN_TILE || tile > MAX_TILE || tile * first.length > MAX_WIDTH) {
		throw new Error("the picture size is outside the limits");
	}
	return drawCells([first, second].map((frames) => frames.map((parts) => ({ parts, view }))), tile, rest, true, [labels, otherLabels]);
}
