// Motion: the paths parts travel, and how fast, over a whole clip, as numbers and as a
// picture beside a chart of speed.
import { inspectPng } from "./image.js";
import { encodePng } from "./png.js";
import { BACKGROUND, MAX_REACH, MAX_TILE, MAX_WIDTH, MIN_TILE, type PosePart, SEPARATOR, type ViewName, basisOf, boxesOf, drawView, extentOf } from "./pose.js";
import { type Colour, type Vec, dot, finite, isRecord, scale, sub } from "./vector.js";

// -------------------
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

/** The colour the part at this place in a list of tracked parts is drawn in, and its name. */
export function trackColour(index: number): { name: string; rgb: Colour } {
	return TRACK_COLOURS[index % TRACK_COLOURS.length] as { name: string; rgb: Colour };
}

export interface Motion {
	/** The time of each sample, in order. */
	times: number[];
	/** The clip's keyframe times. */
	keyframes: number[];
	/** For each tracked part, where its middle is at each sample, and how high its lowest point is when known. */
	parts: Array<{ name: string; positions: Vec[]; lowest?: number[] }>;
}



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
