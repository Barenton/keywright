// The pictures a preview returns, drawn from data alone, and the summaries that go with
// them: poses (pose.ts) and motion over a whole clip (motion.ts). See pose.ts for what a
// picture shows and does not.

export * from "./pose.js";
export * from "./motion.js";
export { encodePng } from "./png.js";

import { DEFAULT_TILE, DEFAULT_VIEWS, LEGEND, MAX_STRIP_VIEWS, MAX_TILE, MAX_VIEWS, MAX_WIDTH, MIN_TILE, type PosePart, SLIM_LEGEND, VIEWS, type ViewName, parsePose as parseParts, renderComparison, renderPose, renderStrip, slimParts } from "./pose.js";
import { type Motion, parseMotion, renderMotion, summariseMotion, trackColours } from "./motion.js";
import { isRecord } from "./vector.js";

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
	// Every set of parts drawn goes through one shape: as sent, or with arms and legs thin.
	const slim = input.style === "slim";
	const parsePose = (value: unknown): PosePart[] => (slim ? slimParts(parseParts(value)) : parseParts(value));
	const legend = slim ? SLIM_LEGEND : LEGEND;
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
				legend,
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
				rest.render = { status: "ok", layout: "one column for each time in order; top row this clip, bottom row the clip it is compared with", views: [view], frames: frames.length, width: both.width, height: both.height, legend };
				return { payload: rest, image: both.png.toString("base64") };
			}
			const strip = renderStrip(frames, rows, each, resting);
			rest.render = { status: "ok", layout: "one column for each time in order, one row for each view", views: rows, frames: frames.length, width: strip.width, height: strip.height, legend };
			return { payload: rest, image: strip.png.toString("base64") };
		}
		const tile = Math.min(size, Math.floor(MAX_WIDTH / views.length));
		const drawn = renderPose(parsePose(pose), views, tile, resting);
		rest.render = { status: "ok", views, width: drawn.width, height: drawn.height, legend };
		return { payload: rest, image: drawn.png.toString("base64") };
	} catch (error) {
		rest.render = { status: "unavailable", reason: error instanceof Error ? error.message : String(error) };
		return { payload: rest };
	}
}
