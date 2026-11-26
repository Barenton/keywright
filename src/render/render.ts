// The pictures a preview returns, drawn from data alone, and the summaries that go with
// them: poses (pose.ts) and motion over a whole clip (motion.ts). See pose.ts for what a
// picture shows and does not.

export * from "./pose.js";
export * from "./motion.js";
export * from "./measure.js";
export * from "./label.js";
export * from "./onion.js";
export { encodePng } from "./png.js";

import { DEFAULT_TILE, DEFAULT_VIEWS, LEGEND, MAX_STRIP_VIEWS, MAX_TILE, MAX_VIEWS, MAX_WIDTH, MIN_TILE, type PosePart, SLIM_LEGEND, VIEWS, type ViewName, parsePose as parseParts, renderComparison, renderPose, renderStrip, slimParts } from "./pose.js";
import { timeLabel } from "./label.js";
import { type Motion, MAX_TRACKS, parseMotion, renderMotion, summariseMotion, trackColour, trackColours } from "./motion.js";
import { renderOnion } from "./onion.js";
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
	// Every picture says how it was drawn, so an agent can tell the style asked for was used.
	const style = slim ? "slim" : "boxes";
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
				style,
			};
			return { payload: rest, image: drawn.png.toString("base64") };
		}
		if (input.onion === true && !(isRecord(pose) && Array.isArray(pose.frames))) throw new Error("onion needs times: the moments to draw over each other");
		if (isRecord(pose) && Array.isArray(pose.frames)) {
			// Several moments of the clip: a filmstrip, one column for each.
			const frames = pose.frames.map((parts: unknown) => parsePose({ parts }));
			const rows = views.slice(0, MAX_STRIP_VIEWS);
			// Each moment's time, as the plugin reports it, to label it by.
			const times = Array.isArray(rest.frames) ? rest.frames.map((frame) => (isRecord(frame) && typeof frame.time === "number" ? timeLabel(frame.time) : "")) : [];
			if (input.onion === true) {
				if (Array.isArray(pose.compare)) throw new Error("onion draws one clip: leave out compare_with");
				const names = new Set((frames[0] ?? []).map((part) => part.name));
				const follow = (Array.isArray(input.track) ? input.track : []).filter((name): name is string => typeof name === "string" && names.has(name)).slice(0, MAX_TRACKS);
				const tile = Math.min(size, Math.floor(MAX_WIDTH / rows.length));
				const drawn = renderOnion(frames, rows, tile, resting, follow);
				rest.render = {
					status: "ok",
					layout: "one picture for each view: every time drawn over the others in order, the last solid and the earlier ones fainter the earlier they are. Each tracked part's arm or leg is drawn stronger, with its path through the frames: a dot at each, numbered in the order of the times (1 is the first)",
					views: rows,
					frames: frames.length,
					numbered: times.map((time, index) => ({ number: index + 1, time: Number(time) })),
					paths: follow.map((part, index) => ({ part, colour: trackColour(index).name })),
					width: drawn.width,
					height: drawn.height,
					legend,
					style,
				};
				return { payload: rest, image: drawn.png.toString("base64") };
			}
			const each = Math.max(MIN_TILE, Math.min(size, Math.floor(MAX_WIDTH / Math.max(frames.length, 1))));
			if (Array.isArray(pose.compare)) {
				// The same moments of another clip: this clip along the top, that one below.
				const other = pose.compare.map((parts: unknown) => parsePose({ parts }));
				const view = rows[0] as ViewName;
				const both = renderComparison(frames, other, view, each, resting, times);
				rest.render = { status: "ok", layout: "one column for each time in order, labelled with the time in seconds; top row this clip, bottom row the clip it is compared with", views: [view], frames: frames.length, width: both.width, height: both.height, legend, style };
				return { payload: rest, image: both.png.toString("base64") };
			}
			const strip = renderStrip(frames, rows, each, resting, times);
			rest.render = { status: "ok", layout: "one column for each time in order, labelled with the time in seconds, one row for each view", views: rows, frames: frames.length, width: strip.width, height: strip.height, legend, style };
			return { payload: rest, image: strip.png.toString("base64") };
		}
		const tile = Math.min(size, Math.floor(MAX_WIDTH / views.length));
		const drawn = renderPose(parsePose(pose), views, tile, resting);
		rest.render = { status: "ok", views, width: drawn.width, height: drawn.height, legend, style };
		return { payload: rest, image: drawn.png.toString("base64") };
	} catch (error) {
		rest.render = { status: "unavailable", reason: error instanceof Error ? error.message : String(error) };
		return { payload: rest };
	}
}
