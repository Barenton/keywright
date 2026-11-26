// Onion skin: several moments of a clip drawn over each other in one picture.
//
// A filmstrip puts each pose in its own column, so how a limb travels between them has to
// be pieced together across columns. Drawn over each other, the latest pose solid and the
// earlier ones fainter the earlier they are, the change from one to the next shows in
// place: where an elbow turns round, whether a fist travels in an arc. A tracked part's
// whole limb is drawn stronger in every frame, with its path through the frames.

import { inspectPng } from "./image.js";
import { dotFor, drawLabel, labelSize } from "./label.js";
import { trackColour } from "./motion.js";
import { encodePng } from "./png.js";
import { BACKGROUND, type Box, boxesOf, drawView, framing, MAX_FRAMES, MAX_STRIP_VIEWS, MAX_TILE, MAX_WIDTH, MIN_TILE, type PosePart, SEPARATOR, Tile, type ViewName, basisOf } from "./pose.js";
import { type Colour, dot, sub, type Vec } from "./vector.js";

/** The parts drawn stronger with a tracked part: the whole arm or leg it belongs to. */
export function limbOf(name: string): string[] {
	const arm = /^(Left|Right)(UpperArm|LowerArm|Hand)$/.exec(name);
	if (arm) return ["UpperArm", "LowerArm", "Hand"].map((part) => `${arm[1]}${part}`);
	const leg = /^(Left|Right)(UpperLeg|LowerLeg|Foot)$/.exec(name);
	if (leg) return ["UpperLeg", "LowerLeg", "Foot"].map((part) => `${leg[1]}${part}`);
	return [name];
}

/** A colour moved toward the background: 1 keeps it, 0 is the background. */
function faded(colour: Colour, strength: number): Colour {
	return colour.map((channel, index) => Math.round((BACKGROUND[index] as number) + (channel - (BACKGROUND[index] as number)) * strength)) as Colour;
}

/** How strongly a frame is drawn: the last in full, earlier ones fainter, a tracked limb less so. */
export function strengthOf(index: number, count: number, emphasised: boolean): number {
	if (index === count - 1) return 1;
	const t = count > 1 ? index / (count - 1) : 1;
	return emphasised ? 0.45 + 0.4 * t : 0.12 + 0.33 * t;
}

function centreOf(parts: PosePart[], name: string): Vec | undefined {
	const part = parts.find((entry) => entry.name === name);
	return part ? [part.cframe[0] as number, part.cframe[1] as number, part.cframe[2] as number] : undefined;
}

/**
 * Draws the frames over each other, once for each view, side by side. Frames are drawn in
 * order, each over the last. `follow` names parts whose limb is drawn stronger and whose
 * path is drawn through the frames, a numbered dot at each (1 for the first frame).
 */
export function renderOnion(frames: PosePart[][], views: ViewName[], tile: number, rest?: PosePart[], follow: string[] = []): { png: Buffer; width: number; height: number } {
	if (frames.length < 2 || frames.length > MAX_FRAMES) throw new Error("an onion skin has from two to eight frames");
	if (views.length === 0 || views.length > MAX_STRIP_VIEWS) throw new Error("an onion skin is drawn from one or two views");
	if (!Number.isInteger(tile) || tile < MIN_TILE || tile > MAX_TILE || tile * views.length > MAX_WIDTH) throw new Error("the picture size is outside the limits");
	const strong = new Set(follow.flatMap(limbOf));
	const boxed = frames.map((parts, index) =>
		parts.flatMap((part) => boxesOf([part]).map((box): Box => ({ ...box, colour: faded(box.colour, strengthOf(index, frames.length, strong.has(part.name))) }))),
	);
	const { centre, pixelsPerStud } = framing(boxed.flat(), rest, true, tile);
	const width = tile * views.length;
	const image = new Uint8Array(width * tile * 3);
	const label = dotFor(tile);
	views.forEach((view, column) => {
		const picture = new Tile(tile);
		for (const boxes of boxed) drawView(boxes, view, tile, centre, pixelsPerStud, picture);
		const { right, up } = basisOf(view);
		const place = (point: Vec): Vec => {
			const local = sub(point, centre);
			return [tile / 2 + dot(local, right) * pixelsPerStud, tile / 2 - dot(local, up) * pixelsPerStud, -1e9];
		};
		// Paths go over everything, with the frame's number beside each dot.
		const dots: Array<{ at: Vec; text: string; colour: Colour; keep: boolean }> = [];
		follow.forEach((name, index) => {
			const colour = trackColour(index).rgb;
			const path = frames.map((parts) => centreOf(parts, name)).map((point) => (point ? place(point) : undefined));
			for (let step = 1; step < path.length; step += 1) {
				const from = path[step - 1];
				const to = path[step];
				if (from && to) picture.line(from, to, colour, 2, 1);
			}
			path.forEach((at, frame) => {
				if (!at) return;
				picture.line([at[0] - 2, at[1] - 2, at[2]], [at[0] - 2, at[1] - 2, at[2]], colour, 5, 1);
				dots.push({ at, text: String(frame + 1), colour, keep: frame === 0 || frame === frames.length - 1 });
			});
		});
		// Where dots bunch up, as a part slows, numbers that would overlap one already
		// drawn are left out. The first and last frames' numbers are always drawn.
		const drawnAt: Array<{ x: number; y: number; width: number; height: number }> = [];
		const overlaps = (box: { x: number; y: number; width: number; height: number }) =>
			drawnAt.some((other) => box.x < other.x + other.width && other.x < box.x + box.width && box.y < other.y + other.height && other.y < box.y + box.height);
		for (const entry of [...dots.filter((dot) => dot.keep), ...dots.filter((dot) => !dot.keep)]) {
			const box = { x: Math.round(entry.at[0]) + 4, y: Math.round(entry.at[1]) - 9 * label, ...labelSize(entry.text, label) };
			if (!entry.keep && overlaps(box)) continue;
			drawnAt.push(box);
			drawLabel(picture.pixels, tile, tile, box.x, box.y, entry.text, entry.colour, label);
		}
		for (let y = 0; y < tile; y += 1) {
			const start = (y * width + column * tile) * 3;
			image.set(picture.pixels.subarray(y * tile * 3, (y + 1) * tile * 3), start);
			if (column > 0) image.set(SEPARATOR, start);
		}
	});
	const png = encodePng(width, tile, image);
	const checked = inspectPng(png);
	if (checked.width !== width || checked.height !== tile) throw new Error("the picture did not encode correctly");
	return { png, width, height: tile };
}
