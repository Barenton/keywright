// Measurements between parts of the rig over time, worked out from the tracked positions
// a preview already returns.
//
// Checking a pose often comes down to one number: how far the fist reaches past the head,
// how low the hips sink after a foot lands, how far a planted foot drifts. Each is the
// distance between two parts, or one part and the root, along one of the rig's directions,
// at each moment sampled. Doing the subtraction here saves an agent doing it by hand.

import { finite, isRecord, sub, type Vec } from "./vector.js";

export const ALONG = ["forward", "up", "right", "distance"] as const;
export type Along = (typeof ALONG)[number];
export const MAX_MEASURES = 4;

/** The parts a preview with samples follows when none are named, as the plugin does. */
export const DEFAULT_FOLLOWED = ["Head", "LeftFoot", "LeftHand", "LowerTorso", "RightFoot", "RightHand"];

export interface Measure {
	part: string;
	relative_to?: string;
	along: Along;
}

/**
 * The parts the plugin has to track for these measurements, added to the ones already
 * asked for. With samples and no parts named, the plugin's own default parts are kept, so
 * the motion summary still covers them.
 */
export function trackFor(measures: Measure[], track: string[] | undefined, samples: boolean): string[] {
	const parts = [...(track ?? (samples ? DEFAULT_FOLLOWED : []))];
	for (const measure of measures) {
		for (const name of [measure.part, measure.relative_to]) if (name !== undefined && !parts.includes(name)) parts.push(name);
	}
	return parts;
}

/** One moment: when, and where each tracked part was, from the root part. */
interface Moment {
	time: number;
	positions: Record<string, Vec>;
}

function vec(value: unknown): Vec | undefined {
	if (Array.isArray(value) && value.length === 3 && value.every(finite)) return [value[0] as number, value[1] as number, value[2] as number];
	return undefined;
}

/** Positions keyed by part, from the plugin's { name: { position } } form. */
function placed(parts: unknown): Record<string, Vec> {
	const positions: Record<string, Vec> = {};
	if (!isRecord(parts)) return positions;
	for (const [name, entry] of Object.entries(parts)) {
		const position = isRecord(entry) ? vec(entry.position) : undefined;
		if (position) positions[name] = position;
	}
	return positions;
}

/** Every moment a preview's result has positions for: sampled motion, frames, or one pose. */
export function momentsOf(payload: Record<string, unknown>): Moment[] {
	const { motion, frames } = payload;
	if (isRecord(motion) && Array.isArray(motion.times) && isRecord(motion.parts)) {
		const paths = motion.parts as Record<string, unknown>;
		return motion.times.map((time: unknown, index: number) => {
			const positions: Record<string, Vec> = {};
			for (const [name, path] of Object.entries(paths)) {
				const position = Array.isArray(path) ? vec(path[index]) : undefined;
				if (position) positions[name] = position;
			}
			return { time: finite(time) ? time : Number.NaN, positions };
		});
	}
	if (Array.isArray(frames)) {
		return frames.map((frame: unknown) => ({
			time: isRecord(frame) && finite(frame.time) ? frame.time : Number.NaN,
			positions: placed(isRecord(frame) ? frame.parts : undefined),
		}));
	}
	if (isRecord(payload.parts)) return [{ time: finite(payload.time) ? payload.time : Number.NaN, positions: placed(payload.parts) }];
	return [];
}

const rounded = (value: number, places: number) => Math.round(value * 10 ** places) / 10 ** places;

/** The measurement at one moment: forward is the rig's negative Z, up its Y, right its X. */
export function measureAt(measure: Measure, positions: Record<string, Vec>): number | undefined {
	const part = positions[measure.part];
	const base = measure.relative_to === undefined ? ([0, 0, 0] as Vec) : positions[measure.relative_to];
	if (!part || !base) return undefined;
	const [x, y, z] = sub(part, base);
	if (measure.along === "forward") return -z;
	if (measure.along === "up") return y;
	if (measure.along === "right") return x;
	return Math.hypot(x, y, z);
}

/**
 * Each measurement over the moments sampled: its value at each, the least and greatest
 * with when they happen, and the change between them. In studs.
 */
export function measureAll(measures: Measure[], moments: Moment[]): unknown[] {
	return measures.map((measure) => {
		const values: Array<[number, number]> = [];
		for (const moment of moments) {
			const value = measureAt(measure, moment.positions);
			if (value !== undefined && Number.isFinite(moment.time)) values.push([rounded(moment.time, 3), rounded(value, 3)]);
		}
		const described = { part: measure.part, relative_to: measure.relative_to ?? "root", along: measure.along };
		if (values.length === 0) return { ...described, status: "unavailable", reason: "the preview returned no positions for these parts" };
		let least = values[0] as [number, number];
		let greatest = least;
		for (const entry of values) {
			if (entry[1] < least[1]) least = entry;
			if (entry[1] > greatest[1]) greatest = entry;
		}
		return {
			...described,
			values,
			least: { value: least[1], time: least[0] },
			greatest: { value: greatest[1], time: greatest[0] },
			change: rounded(greatest[1] - least[1], 3),
		};
	});
}

/** Checks the measurements asked for. Anything unusable is left out by the tool's schema. */
export function parseMeasures(value: unknown): Measure[] {
	if (!Array.isArray(value)) return [];
	return value.filter(
		(entry): entry is Measure =>
			isRecord(entry) &&
			typeof entry.part === "string" &&
			(entry.relative_to === undefined || typeof entry.relative_to === "string") &&
			(ALONG as readonly unknown[]).includes(entry.along),
	);
}

/** Adds `measured` to a preview's result when measurements were asked for. */
export function measureResult(params: unknown, payload: unknown): unknown {
	if (!isRecord(params) || !isRecord(payload)) return payload;
	const measures = parseMeasures(params.measure);
	if (measures.length === 0) return payload;
	return { ...payload, measured: measureAll(measures, momentsOf(payload)) };
}
