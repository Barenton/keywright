#!/usr/bin/env node
// Measures Phase 0 experiments through the ordinary tools, against a Studio session a
// person has already connected.
//
// It talks only to the local broker, the way the MCP adapter does. It does not start,
// stop or attach to Studio, install anything, or touch a file outside build/. It does
// change the place the session has open: it makes working copies, which it discards
// again at the end, and one saved clip for each rig, named "Measure fixture ...", which
// stays and is used again by later runs. No tool removes a saved clip, so it saves no
// more than that. Because it changes the place, it must be told the id of the place,
// and refuses any other.
//
// Usage: node scripts/measure.mjs --place-id <id> [--rounds 10000]

import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The value below which the given share of the numbers fall. */
export function percentile(values, share) {
	if (values.length === 0) return Number.NaN;
	const sorted = [...values].sort((a, b) => a - b);
	return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(share * sorted.length) - 1))];
}

/** The smallest turn, in degrees, between two angles given in degrees. */
export function angleBetween(a, b) {
	const difference = Math.abs(a - b) % 360;
	return difference > 180 ? 360 - difference : difference;
}

/** The largest difference between two sets of sampled joints: rotation in degrees, position in studs. */
export function largestDifference(first, second) {
	let degrees = 0;
	let studs = 0;
	let compared = 0;
	for (const [name, joint] of Object.entries(first)) {
		const other = second[name];
		if (!other) continue;
		compared += 1;
		for (let axis = 0; axis < 3; axis += 1) {
			degrees = Math.max(degrees, angleBetween(joint.rotation[axis], other.rotation[axis]));
			studs = Math.max(studs, Math.abs(joint.position[axis] - other.position[axis]));
		}
	}
	return { degrees, studs, compared };
}

/**
 * The largest difference between two sets of parts, each as { name, cframe } with the
 * twelve numbers of a CFrame: position in studs, and the turn between their rotations in
 * degrees. Parts are matched by name.
 */
export function largestPartDifference(first, second) {
	const others = new Map(second.map((part) => [part.name, part.cframe]));
	let degrees = 0;
	let studs = 0;
	let compared = 0;
	for (const { name, cframe } of first) {
		const other = others.get(name);
		if (!other) continue;
		compared += 1;
		studs = Math.max(studs, Math.hypot(cframe[0] - other[0], cframe[1] - other[1], cframe[2] - other[2]));
		// The size of the difference between two rotations gives the angle between them.
		// (The usual formula, from the trace, magnifies the rounding in these numbers into
		// half a degree when the angle is small.)
		let squares = 0;
		for (let index = 3; index < 12; index += 1) squares += (cframe[index] - other[index]) ** 2;
		degrees = Math.max(degrees, (2 * Math.asin(Math.min(1, Math.sqrt(squares / 8))) * 180) / Math.PI);
	}
	return { degrees, studs, compared };
}

/** The rotation the large clip gives one joint at one keyframe: one axis, well inside a quarter turn. */
export function largeRotation(keyframe, joint) {
	const rotation = [0, 0, 0];
	rotation[joint % 3] = ((keyframe * 7 + joint * 13) % 160) - 80 + 0.25;
	return rotation;
}

// --- Studio's own numbers, recovered from a fingerprint -------------------------------
//
// No tool returns the numbers of a CFrame as Studio holds them. A clip's fingerprint,
// though, is a hash of those numbers written to nine digits. So for a clip with one pose,
// the numbers can be found: start from the true value of each, try the few nearest
// single-precision values, and stop when the hash is the one Studio reported. A match
// means those are Studio's numbers, digit for digit.

/** A number as Luau's string.format("%.9g") writes it. */
export function nineDigits(value) {
	if (value === 0) return Object.is(value, -0) ? "-0" : "0";
	const [mantissa, exponent] = value.toExponential(8).split("e");
	const power = Number(exponent);
	if (power < -4 || power >= 9) {
		const digits = mantissa.includes(".") ? mantissa.replace(/\.?0+$/, "") : mantissa;
		return `${digits}e${power < 0 ? "-" : "+"}${String(Math.abs(power)).padStart(2, "0")}`;
	}
	return Number(value.toPrecision(9)).toString();
}

const multiply = (a, b) => a.map((_, index) => a[Math.floor(index / 3) * 3] * b[index % 3] + a[Math.floor(index / 3) * 3 + 1] * b[3 + (index % 3)] + a[Math.floor(index / 3) * 3 + 2] * b[6 + (index % 3)]);

/**
 * The nine numbers of the rotation for Euler angles in degrees, applied in X, Y, Z order,
 * as the plugin builds it: degrees to radians, radians to single precision, then exact.
 */
export function eulerRotation([x, y, z]) {
	const [a, b, c] = [x, y, z].map((degrees) => Math.fround((degrees * Math.PI) / 180));
	const aboutX = [1, 0, 0, 0, Math.cos(a), -Math.sin(a), 0, Math.sin(a), Math.cos(a)];
	const aboutY = [Math.cos(b), 0, Math.sin(b), 0, 1, 0, -Math.sin(b), 0, Math.cos(b)];
	const aboutZ = [Math.cos(c), -Math.sin(c), 0, Math.sin(c), Math.cos(c), 0, 0, 0, 1];
	return multiply(multiply(aboutX, aboutY), aboutZ);
}

/** The rotation a list of rotations gives when each is applied on top of the one before. */
export function composedRotation(rotations) {
	return rotations.map(eulerRotation).reduce(multiply);
}

const single = new Float32Array(1);
const bits = new Int32Array(single.buffer);
/** The single-precision value the given number of steps away from the nearest one to `value`. */
function stepped(value, steps) {
	single[0] = value;
	bits[0] += single[0] < 0 ? -steps : steps;
	return single[0];
}

const HEAD_PATHS = ["/HumanoidRootPart", "/HumanoidRootPart/LowerTorso", "/HumanoidRootPart/LowerTorso/UpperTorso"];
const EASING = "|Enum.PoseEasingStyle.Linear|Enum.PoseEasingDirection.In";

/**
 * The fingerprint of a blank working copy given one pose for the head at one second: the
 * twelve numbers of that pose's CFrame, each already as text. Follows plugin/src/Digest.luau.
 */
export function headPoseFingerprint(numbers) {
	const lines = [
		"1|keyframe",
		`1|pose|${HEAD_PATHS[2]}/Head|${numbers.join(",")}|1${EASING}`,
		...HEAD_PATHS.map((path) => `1|pose|${path}|0,0,0,1,0,0,0,1,0,0,0,1|0${EASING}`),
		"loop|false",
		"priority|Enum.AnimationPriority.Action",
	];
	lines.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
	return createHash("sha256").update(lines.join("\n")).digest("hex");
}

/**
 * Studio's twelve numbers for a head pose whose fingerprint is known, or undefined when
 * none within `reach` single-precision steps of the true rotation gives that fingerprint.
 * The position must be exact in single precision; the rotation is what is searched.
 */
export function recoverPose(fingerprint, position, rotation, reach = 2) {
	const fixed = position.map((value) => nineDigits(Math.fround(value)));
	for (let radius = 0; radius <= reach; radius += 1) {
		// A rotation number that is exactly 0 or 1 is taken as it is; the rest may be off by a few steps.
		const choices = rotation.map((value) => {
			if (value === 0 || Math.abs(value) === 1) return [value];
			const near = [];
			for (let step = -radius; step <= radius; step += 1) near.push(stepped(value, step));
			return near;
		});
		const texts = choices.map((list) => list.map(nineDigits));
		const pick = new Array(9).fill(0);
		for (;;) {
			if (headPoseFingerprint([...fixed, ...pick.map((chosen, index) => texts[index][chosen])]) === fingerprint) {
				return [...position.map(Math.fround), ...pick.map((chosen, index) => choices[index][chosen])];
			}
			let place = 0;
			while (place < 9 && pick[place] === choices[place].length - 1) pick[place++] = 0;
			if (place === 9) break;
			pick[place] += 1;
		}
	}
	return undefined;
}

/**
 * The fixed set of poses whose numbers are compared between Studio and Lune (E10). Each is
 * a list of steps for the head at one second; a step after the first is applied on top of
 * the pose so far. Positions are exact in single precision.
 */
export const VECTORS = [
	{ name: "about Y", steps: [{ rotation: [0, 30, 0] }] },
	{ name: "about X", steps: [{ rotation: [45, 0, 0] }] },
	{ name: "about Z, negative", steps: [{ rotation: [0, 0, -60] }] },
	{ name: "a quarter turn", steps: [{ rotation: [90, 0, 0] }] },
	{ name: "three axes", steps: [{ rotation: [10, 20, 30] }] },
	{ name: "three axes with an offset", steps: [{ rotation: [-75, 40, 115], position: [0.5, -1.25, 2] }] },
	{ name: "uneven angles with an offset", steps: [{ rotation: [123.4, -56.7, 89.1], position: [0.125, 0.25, -0.5] }] },
	{ name: "very small angles", steps: [{ rotation: [0.01, 0.02, 0.03] }] },
	{ name: "one turn on top of another", steps: [{ rotation: [0, 30, 0] }, { rotation: [0, 30, 0] }] },
	{ name: "three axes on top of three axes", steps: [{ rotation: [10, 20, 30] }, { rotation: [-40, 15, 70] }] },
];

/**
 * The operations that build a reference clip (PRD section 15): every one of the fifteen
 * joints posed at each keyframe, a tenth of a second apart. 31 keyframes make Ref-S
 * (3 s, 465 poses), 301 make Ref-L (30 s, 4,515 poses). The same numbers every time.
 */
export function referenceOperations(keyframes) {
	const operations = [];
	for (let keyframe = 0; keyframe < keyframes; keyframe += 1) {
		R15.forEach((joint, index) => {
			operations.push({ type: "set_pose", joint, time: keyframe / 10, rotation: largeRotation(keyframe, index) });
		});
	}
	return operations;
}

/** Turns a measured value into a result line with a verdict against its limit. */
export function judge(id, question, measured, limit, unit, detail = "") {
	const passed = typeof measured === "number" && Number.isFinite(measured) && measured <= limit;
	// Differences of rounded numbers carry noise far below anything measured here.
	const shown = typeof measured === "number" && Number.isFinite(measured) ? Math.round(measured * 1e6) / 1e6 : measured;
	return { id, question, verdict: passed ? "pass" : "fail", measured: shown, limit, unit, detail };
}

const skipped = (id, question, detail) => ({ id, question, verdict: "skipped", detail });

function parseArguments(argv) {
	const options = { rounds: 10000 };
	for (let index = 0; index < argv.length; index += 2) {
		const [flag, value] = [argv[index], argv[index + 1]];
		if (flag === "--place-id") options.placeId = Number(value);
		else if (flag === "--rounds") options.rounds = Number(value);
		else throw new Error(`Unknown argument ${flag}.`);
	}
	if (!Number.isInteger(options.placeId)) throw new Error("Give the id of the place to measure in: --place-id <id>.");
	if (!Number.isInteger(options.rounds) || options.rounds < 10 || options.rounds > 100000) throw new Error("--rounds must be from 10 to 100000.");
	return options;
}

// The clip every measurement uses: three keyframes, the same six joints in each, so that
// it is uniform, with turns about one axis per joint so that angles compare cleanly.
const JOINTS = ["Head", "UpperTorso", "RightUpperArm", "RightLowerArm", "LeftUpperLeg", "LeftLowerLeg"];
const TIMES = [0, 0.5, 1];
// Every driven part of an R15 character.
const R15 = [
	"Head", "UpperTorso", "LowerTorso",
	"RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightUpperLeg", "RightLowerLeg", "RightFoot", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
];
const MEBIBYTE = 1024 * 1024;
// Enough keyframes of all fifteen joints for the clip, read back whole, to pass 1 MiB.
const LARGE_KEYFRAMES = 714;
const LARGE_STEP = 0.25;
function clipOperations() {
	const operations = [];
	TIMES.forEach((time, step) => {
		JOINTS.forEach((joint, index) => {
			const rotation = [0, 0, 0];
			rotation[index % 3] = step * (20 + index * 7) * (index % 2 === 0 ? 1 : -1);
			const position = joint === "UpperTorso" ? [0, step * 0.125, 0] : [0, 0, 0];
			operations.push({ type: "set_pose", joint, time, rotation, position });
		});
	});
	return operations;
}

async function main() {
	const options = parseArguments(process.argv.slice(2));
	const { connectAdapter } = await import(pathToFileURL(join(ROOT, "dist/src/client.js")).href);
	const state = await import(pathToFileURL(join(ROOT, "dist/src/state.js")).href);
	const render = await import(pathToFileURL(join(ROOT, "dist/src/render.js")).href);
	const broker = await connectAdapter(state.configuredPort(), state.loadOrCreateSecret(state.stateDir()));
	const results = [];
	const made = [];
	let saved = 0;
	const stamp = new Date().toISOString().replace(/[-:]/g, "").slice(0, 15);

	try {
		const { sessions } = await broker.request("broker.sessions");
		const session = sessions.find((candidate) => candidate.placeId === options.placeId);
		if (!session) {
			throw new Error(`No connected Studio session has place id ${options.placeId}. Connected: ${sessions.map((s) => s.placeId).join(", ") || "none"}.`);
		}
		const call = async (method, params, timeoutMs) => {
			const result = await broker.request(method, params, session.id, timeoutMs);
			// Every working copy this run opens is noted, to be discarded at the end.
			if (method === "open_animation") made.push(result.clip_id);
			return result;
		};
		const timed = async (method, params, timeoutMs) => {
			const started = performance.now();
			const result = await call(method, params, timeoutMs);
			return { result, ms: performance.now() - started };
		};

		const workspace = await call("get_workspace", {});
		const rigOf = (jointClass) => workspace.rigs.find((rig) => rig.supported && rig.joint_classes?.[jointClass] === 15);
		const rigs = { Motor6D: rigOf("Motor6D"), AnimationConstraint: rigOf("AnimationConstraint") };
		const clips = {};
		for (const [jointClass, rig] of Object.entries(rigs)) {
			if (!rig) continue;
			const opened = await call("open_animation", { rig_id: rig.rig_id, name: `Measure ${stamp} ${jointClass}` });
			const edited = await call("edit_animation", { clip_id: opened.clip_id, expected_revision: opened.revision, operations: clipOperations() });
			clips[jointClass] = { rig, clipId: opened.clip_id, revision: edited.revision };
		}
		const available = Object.keys(clips);
		// The one clip this script keeps saved for each rig. Saved if the rig does not have
		// it yet; a name that is taken means an earlier run saved it. Returns whether this
		// run did.
		const fixtureName = (jointClass) => `Measure fixture ${jointClass}`;
		const ensureFixture = async (jointClass) => {
			const { clipId } = clips[jointClass];
			const current = await call("read_animation", { clip_id: clipId });
			try {
				await call("save_animation", { clip_id: clipId, expected_revision: current.revision, name: fixtureName(jointClass) });
				saved += 1;
				return true;
			} catch (error) {
				if (error?.code === "INVALID_ARGUMENT") return false;
				throw error;
			}
		};
		if (available.length === 0) throw new Error("The place has no supported R15 rig to measure on.");
		const main = clips[available[0]];

		// E1: round trips, and requests answered in the order they were sent.
		{
			const latencies = [];
			let answered = 0;
			let wrong = 0;
			const window = 25;
			for (let sent = 0; sent < options.rounds; sent += window) {
				const batch = Array.from({ length: Math.min(window, options.rounds - sent) }, () => timed("read_animation", { clip_id: main.clipId }));
				for (const { result, ms } of await Promise.all(batch)) {
					answered += 1;
					latencies.push(ms);
					if (result.clip_id !== main.clipId || result.revision !== main.revision) wrong += 1;
				}
			}
			results.push(judge("E1", `${options.rounds} request and response round trips with none lost or wrong`, options.rounds - answered + wrong, 0, "lost or wrong", `p95 ${percentile(latencies, 0.95).toFixed(1)} ms with ${window} in flight`));

			// Each edit names the revision the one before it produced, and all are sent at
			// once. They can only all succeed if Studio handles them in the order sent.
			const scratch = await call("open_animation", { rig_id: main.rig.rig_id, name: `Measure ${stamp} order` });
			const chain = 200;
			let revision = scratch.revision;
			const number = Number(String(revision).replace(/\D/g, ""));
			const pending = [];
			for (let step = 0; step < chain; step += 1) {
				pending.push(
					call("edit_animation", {
						clip_id: scratch.clip_id,
						expected_revision: `r${number + step}`,
						operations: [{ type: "set_pose", joint: "Head", time: 0, rotation: [0, step % 90, 0] }],
					}).then(
						() => true,
						() => false,
					),
				);
			}
			const outOfOrder = (await Promise.all(pending)).filter((ok) => !ok).length;
			results.push(judge("E1", `${chain} dependent edits sent at once are applied in the order sent`, outOfOrder, 0, "refused"));

			// A message of more than 1 MiB in each direction. From Studio: a clip large enough
			// that reading it whole is over 1 MiB, checked pose by pose against what was
			// written. To Studio: an edit carrying 1 MiB it has no use for, which must still
			// be read and applied.
			const large = await call("open_animation", { rig_id: main.rig.rig_id, name: `Measure ${stamp} large` });
			let largeRevision = large.revision;
			const perBatch = Math.floor(256 / R15.length);
			for (let first = 0; first < LARGE_KEYFRAMES; first += perBatch) {
				const operations = [];
				for (let keyframe = first; keyframe < Math.min(LARGE_KEYFRAMES, first + perBatch); keyframe += 1) {
					R15.forEach((joint, index) => operations.push({ type: "set_pose", joint, time: keyframe * LARGE_STEP, rotation: largeRotation(keyframe, index) }));
				}
				largeRevision = (await call("edit_animation", { clip_id: large.clip_id, expected_revision: largeRevision, operations }, 60000)).revision;
			}
			// Asked for in one piece: by default the plugin returns poses a page at a time.
			const whole = await call("read_animation", { clip_id: large.clip_id, joints: R15, limit: 20000 }, 120000);
			const received = Buffer.byteLength(JSON.stringify(whole));
			let damaged = whole.poses.length === LARGE_KEYFRAMES * R15.length ? 0 : 1;
			for (const pose of whole.poses) {
				const expected = largeRotation(Math.round(pose.time / LARGE_STEP), R15.indexOf(pose.joint));
				if (expected.some((angle, axis) => angleBetween(angle, pose.rotation[axis]) > 0.01)) damaged += 1;
			}
			results.push(
				judge("E1", "A message of over 1 MiB from Studio arrives intact", received >= MEBIBYTE ? damaged : Number.NaN, 0, "wrong poses", `${received} bytes, ${whole.poses.length} poses, each checked against what was written`),
			);

			const padding = "0123456789abcdef".repeat(MEBIBYTE / 16);
			const padded = await call(
				"edit_animation",
				{ clip_id: scratch.clip_id, expected_revision: `r${number + chain}`, operations: [{ type: "set_pose", joint: "Head", time: 5, rotation: [0, 12, 0] }], padding },
				60000,
			).then(
				() => true,
				() => false,
			);
			const afterPadded = padded ? await call("read_animation", { clip_id: scratch.clip_id, joints: ["Head"], time_from: 5, time_to: 5 }) : { poses: [] };
			const applied = afterPadded.poses.length === 1 && angleBetween(afterPadded.poses[0].rotation[1], 12) <= 0.01;
			results.push(
				judge("E1", "A request of over 1 MiB to Studio is read and its edit applied", applied ? 0 : 1, 0, "failed", `${Buffer.byteLength(padding)} bytes of padding beside one edit; the padding itself is not read back`),
			);
			results.push(skipped("E1", "Reconnection after a broker restart, and two Studio windows", "Not measured by this script. Both were checked by hand."));
		}

		// E4: the engine's values at keyframes, and repeatability.
		{
			let worstDegrees = 0;
			let worstStuds = 0;
			for (const jointClass of available) {
				const clip = clips[jointClass];
				const stored = await call("read_animation", { clip_id: clip.clipId, joints: JOINTS });
				for (const time of TIMES) {
					const sampled = await call("preview_animation", { clip_id: clip.clipId, time, joints: JOINTS }, 60000);
					const expected = Object.fromEntries(stored.poses.filter((pose) => Math.abs(pose.time - time) < 1e-6).map((pose) => [pose.joint, pose]));
					const difference = largestDifference(expected, sampled.joints);
					if (difference.compared !== JOINTS.length) throw new Error(`Only ${difference.compared} of ${JOINTS.length} joints came back at ${time} s.`);
					worstDegrees = Math.max(worstDegrees, difference.degrees);
					worstStuds = Math.max(worstStuds, difference.studs);
				}
			}
			results.push(judge("E4", "Sampled rotation at keyframe times equals the stored poses", worstDegrees, 0.01, "degrees", `on ${available.join(" and ")}`));
			results.push(judge("E4", "Sampled position at keyframe times equals the stored poses", worstStuds, 0.001, "studs"));

			const repeats = 100;
			const seen = new Set();
			for (let index = 0; index < repeats; index += 1) {
				const sampled = await call("preview_animation", { clip_id: main.clipId, time: 0.37, joints: JOINTS }, 60000);
				seen.add(JSON.stringify(sampled.joints));
			}
			results.push(judge("E4", `${repeats} repeated samples at one time are identical`, seen.size - 1, 0, "differing results"));
		}

		// E3: the two joint classes against each other, in joint space.
		if (clips.Motor6D && clips.AnimationConstraint) {
			let degrees = 0;
			let studs = 0;
			// Parts, from each rig's own rest joints and the sampled transforms, relative to
			// its root part. At time 0 the clip is the rest pose, so a difference there is
			// a difference between the two rigs, not between the joint classes.
			const parts = { degrees: 0, studs: 0, restDegrees: 0, restStuds: 0, compared: 0 };
			for (let step = 0; step <= 10; step += 1) {
				const time = step / 10;
				const [motor, constraint] = await Promise.all(
					[clips.Motor6D, clips.AnimationConstraint].map((clip) => call("preview_animation", { clip_id: clip.clipId, time, joints: JOINTS, render: true }, 60000)),
				);
				const difference = largestDifference(motor.joints, constraint.joints);
				degrees = Math.max(degrees, difference.degrees);
				studs = Math.max(studs, difference.studs);
				const placed = largestPartDifference(motor.pose.parts, constraint.pose.parts);
				parts.compared = placed.compared;
				parts.degrees = Math.max(parts.degrees, placed.degrees);
				parts.studs = Math.max(parts.studs, placed.studs);
				if (step === 0) [parts.restDegrees, parts.restStuds] = [placed.degrees, placed.studs];
			}
			results.push(judge("E3", "The same clip gives the same joint rotations on both joint classes, at 11 times", degrees, 0.01, "degrees"));
			results.push(judge("E3", "The same clip gives the same joint positions on both joint classes", studs, 0.001, "studs"));
			const atRest = `${parts.compared} parts, worked out from the sampled joints and each rig's rest joints, in numbers rounded to four places, which alone allows about 0.008 degrees; at rest the two rigs differ by ${parts.restStuds.toFixed(6)} studs and ${parts.restDegrees.toFixed(6)} degrees`;
			results.push(judge("E3", "The same clip turns parts the same way on both joint classes, at 11 times", parts.compared >= R15.length ? parts.degrees : Number.NaN, 0.01, "degrees", atRest));
			if (parts.restStuds > 0.001) {
				// Two different bodies: their parts cannot coincide, whatever joins them.
				results.push(skipped("E3", "The same clip puts parts in the same place on both joint classes", `Not comparable here: the two rigs are different bodies, ${parts.restStuds.toFixed(4)} studs apart at rest and ${parts.studs.toFixed(4)} at most in the clip. Needs two rigs that differ only in joint class.`));
			} else {
				results.push(judge("E3", "The same clip puts parts in the same place on both joint classes", parts.studs, 0.001, "studs"));
			}
			results.push(skipped("E3", "Reset, and joints with IsKinematic off", "Not measured by this script. Previews run on a copy, so the rig itself is never moved."));
		} else {
			results.push(skipped("E3", "The two joint classes against each other", "The place needs one Motor6D rig and one AnimationConstraint rig."));
		}

		// E3, on each rig by itself: does Studio put each part where the joint's rest
		// offsets and transform say? If it does on both joint classes, and the transforms
		// are the same on both (measured above), two rigs with the same body would have
		// their parts in the same place. This does not need the two rigs to be alike.
		for (const jointClass of available) {
			const worst = { studs: 0, degrees: 0, part: "", parts: 0, missing: false };
			for (let step = 0; step <= 10; step += 1) {
				const sampled = await call("preview_animation", { clip_id: clips[jointClass].clipId, time: step / 10, check_placement: true }, 60000);
				if (!sampled.placement) {
					worst.missing = true;
					break;
				}
				worst.parts = sampled.placement.parts;
				worst.degrees = Math.max(worst.degrees, sampled.placement.degrees);
				if (sampled.placement.studs >= worst.studs) [worst.studs, worst.part] = [sampled.placement.studs, sampled.placement.worst ?? ""];
			}
			const question = `On the ${jointClass} rig, Studio puts each part where the joint transforms say, at 11 times`;
			if (worst.missing) {
				results.push(skipped("E3", question, "The plugin in Studio predates this check. Reinstall it and run again."));
			} else {
				results.push(judge("E3", `${question}: position`, worst.parts === R15.length ? worst.studs : Number.NaN, 0.001, "studs", `${worst.parts} parts, read from the parts of the disposable copy${worst.part ? `; largest on ${worst.part}` : ""}`));
				results.push(judge("E3", `${question}: rotation`, worst.degrees, 0.01, "degrees"));
			}
		}

		// E5: a round trip through saving and opening changes nothing.
		{
			const before = await call("read_animation", { clip_id: main.clipId, hash: true });
			if (typeof before.content_hash !== "string") {
				results.push(skipped("E5", "A round trip through saving and opening changes nothing", "The plugin in Studio predates clip fingerprints. Reinstall it and run again."));
			} else {
				// The clip is saved once and kept: a later run opens what an earlier run saved,
				// and it must still be, to the fingerprint, the clip as it is built now.
				const mainClass = available[0];
				const fresh = await ensureFixture(mainClass);
				const reopened = await call("open_animation", { rig_id: main.rig.rig_id, source: `saved:${fixtureName(mainClass)}` });
				const after = await call("read_animation", { clip_id: reopened.clip_id, hash: true });
				results.push(
					judge(
						"E5",
						"A saved clip opens with the fingerprint of the same clip built now",
						after.content_hash === before.content_hash ? 0 : 1,
						0,
						"changed",
						fresh ? "saved by this run" : "saved by an earlier run",
					),
				);
				results.push(skipped("E5", "Opening a clip the Animation Editor saved, and the editor saving ours", "Needs a person in the Animation Editor."));
			}
		}

		// The Phase 0 walk-through on each rig: inspect, open, edit one keyframe, preview it,
		// get a picture, have a stale write from a second client refused, and put the clip
		// back as it was. Reverting by Studio's own undo needs a person and is not done here.
		for (const jointClass of available) {
			const { rig, clipId } = clips[jointClass];
			const failed = [];
			const step = (name, passed) => {
				if (!passed) failed.push(name);
			};
			try {
				const inspected = await call("inspect_rig", { rig_id: rig.rig_id });
				step("inspect", inspected.supported === true && inspected.joint_count === 15 && inspected.joint_classes?.[jointClass] === 15);

				const name = fixtureName(jointClass);
				await ensureFixture(jointClass);
				const working = await call("open_animation", { rig_id: rig.rig_id, source: `saved:${name}` });
				const before = await call("read_animation", { clip_id: working.clip_id, hash: true });
				step("open", typeof before.content_hash === "string" && before.keyframe_count === TIMES.length);

				const turn = [{ type: "set_pose", joint: "Head", time: 1, rotation: [0, 60, 0] }];
				const edited = await call("edit_animation", { clip_id: working.clip_id, expected_revision: before.revision, operations: turn });
				const changed = await call("read_animation", { clip_id: working.clip_id, hash: true });
				step("edit", changed.content_hash !== before.content_hash && changed.revision === edited.revision);

				const preview = await call("preview_animation", { clip_id: working.clip_id, time: 1, joints: ["Head"], render: true }, 60000);
				step("preview", angleBetween(preview.joints.Head.rotation[1], 60) <= 0.01);
				const picture = render.renderPose(render.parsePose(preview.pose), ["front", "three_quarter"], 256);
				step("picture", picture.width === 512 && picture.png.length > 500);

				// A second client that still holds the revision from before the edit.
				const other = await connectAdapter(state.configuredPort(), state.loadOrCreateSecret(state.stateDir()));
				try {
					const refusal = await other
						.request("edit_animation", { clip_id: working.clip_id, expected_revision: before.revision, operations: turn }, session.id)
						.then(
							() => "accepted",
							(error) => error.code,
						);
					const untouched = await call("read_animation", { clip_id: working.clip_id, hash: true });
					step("stale write refused", refusal === "REVISION_CONFLICT" && untouched.content_hash === changed.content_hash);
				} finally {
					other.close();
				}

				await call("edit_animation", { clip_id: working.clip_id, expected_revision: edited.revision, operations: [{ type: "restore_source" }] });
				const restored = await call("read_animation", { clip_id: working.clip_id, hash: true });
				step("source restored", restored.content_hash === before.content_hash);
			} catch (error) {
				failed.push(`stopped: ${error instanceof Error ? error.message : String(error)}`);
			}
			results.push(
				judge(
					"Demo",
					`The walk-through on the ${jointClass} rig: inspect, open, edit, preview, picture, stale write from a second client refused, source restored`,
					failed.length,
					0,
					"failed steps",
					failed.join("; "),
				),
			);
		}

		// E10: Studio's numbers for a fixed set of poses, recovered from fingerprints, for
		// the offline suite to compare with Lune's (plugin/test/vectors.luau).
		const vectors = [];
		{
			let unrecovered = 0;
			for (const vector of VECTORS) {
				const opened = await call("open_animation", { rig_id: main.rig.rig_id, name: `Measure ${stamp} vector` });
				let revision = opened.revision;
				for (const [index, step] of vector.steps.entries()) {
					const operation = { type: "set_pose", joint: "Head", time: 1, rotation: step.rotation, position: step.position ?? [0, 0, 0], relative: index > 0 };
					revision = (await call("edit_animation", { clip_id: opened.clip_id, expected_revision: revision, operations: [operation] })).revision;
				}
				const { content_hash: fingerprint } = await call("read_animation", { clip_id: opened.clip_id, hash: true });
				const position = vector.steps[0].position ?? [0, 0, 0];
				const studio = recoverPose(fingerprint, position, composedRotation(vector.steps.map((step) => step.rotation)));
				if (!studio) unrecovered += 1;
				vectors.push({ ...vector, fingerprint, studio: studio ?? null });
			}
			results.push(
				judge("E10", `Studio's exact numbers recovered for ${VECTORS.length} poses, from their fingerprints`, unrecovered, 0, "not recovered", "compare with Lune by copying the vectors file to plugin/test/studio-vectors.json and running plugin/test/vectors.luau"),
			);
		}

		// Phase 1: every kind of edit, each checked by reading the clip back.
		{
			const failed = [];
			const step = (name, passed) => {
				if (!passed) failed.push(name);
			};
			const same = (list, expected) => list.length === expected.length && list.every((value, index) => Math.abs(value - expected[index]) < 0.0015);
			let outdated = false;
			try {
				const opened = await call("open_animation", { rig_id: main.rig.rig_id, name: `Measure ${stamp} operations` });
				const clipId = opened.clip_id;
				let revision = opened.revision;
				const edit = async (operations) => {
					const result = await call("edit_animation", { clip_id: clipId, expected_revision: revision, operations });
					revision = result.revision;
					return result.changed;
				};
				const read = () => call("read_animation", { clip_id: clipId, joints: ["Head", "LeftUpperArm"], hash: true });
				const headAt = (clip, time) => clip.poses.find((pose) => pose.joint === "Head" && Math.abs(pose.time - time) < 0.0015);
				const turn = (clip, time) => headAt(clip, time)?.rotation[1];

				await edit([
					{ type: "set_pose", joint: "Head", time: 0, rotation: [0, 10, 0] },
					{ type: "set_pose", joint: "Head", time: 1, rotation: [0, 20, 0], easing_style: "Bounce", easing_direction: "Out" },
					{ type: "set_pose", joint: "Head", time: 2, rotation: [0, 30, 0] },
					{ type: "set_pose", joint: "LeftUpperArm", time: 1, rotation: [0, 0, -45] },
					{ type: "set_marker", time: 1, name: "Step", value: "left" },
				]);
				let clip = await read();
				step("poses with easing", same(clip.keyframe_times, [0, 1, 2]) && headAt(clip, 1)?.easing_style === "Bounce" && headAt(clip, 1)?.easing_direction === "Out");
				step("a marker", clip.markers.length === 1 && clip.markers[0].name === "Step" && clip.markers[0].value === "left");

				// Reads come a page at a time, and rotations as quaternions on request.
				const page = await call("read_animation", { clip_id: clipId, joints: ["Head"], rotation_format: "quaternion", limit: 2 });
				const rest = await call("read_animation", { clip_id: clipId, joints: ["Head"], offset: page.next_offset, limit: 2, poses_only: true });
				const halfTurn = (degrees) => [Math.sin((degrees * Math.PI) / 360), Math.cos((degrees * Math.PI) / 360)];
				const second = page.poses?.[1]?.quaternion ?? [];
				step("a read in two pages", page.poses?.length === 2 && page.poses_total === 3 && page.next_offset === 2 && rest.poses?.length === 1 && rest.next_offset === undefined && rest.name === undefined);
				step("a rotation as a quaternion", page.poses?.[1]?.rotation === undefined && Math.abs(second[1] - halfTurn(20)[0]) < 1e-4 && Math.abs(second[3] - halfTurn(20)[1]) < 1e-4);
				await edit([{ type: "set_pose", joint: "Head", time: 2, quaternion: [0, halfTurn(30)[0], 0, halfTurn(30)[1]] }]);
				step("a pose set from a quaternion", angleBetween(turn(await read(), 2), 30) < 0.01);

				await edit([{ type: "offset_pose", joint: "Head", time_from: 1, time_to: 2, rotation: [0, 5, 0] }]);
				clip = await read();
				step("an offset over a range", angleBetween(turn(clip, 0), 10) < 0.01 && angleBetween(turn(clip, 1), 25) < 0.01 && angleBetween(turn(clip, 2), 35) < 0.01);

				await edit([{ type: "set_easing", joint: "Head", time_from: 0, time_to: 0, easing_style: "Elastic", easing_direction: "InOut" }]);
				clip = await read();
				step("easing over a range", headAt(clip, 0)?.easing_style === "Elastic" && headAt(clip, 0)?.easing_direction === "InOut" && headAt(clip, 2)?.easing_style === "Linear");

				await edit([
					{ type: "add_keyframe", time: 0.5 },
					{ type: "duplicate_keyframe", time: 1, to: 3 },
					{ type: "move_keyframe", time: 3, to: 2.5 },
					{ type: "remove_keyframe", time: 0.5 },
				]);
				clip = await read();
				step("keyframes added, duplicated, moved and removed", same(clip.keyframe_times, [0, 1, 2, 2.5]) && angleBetween(turn(clip, 2.5), 25) < 0.01 && clip.markers.length === 2);

				await edit([{ type: "shift_time", time_from: 2, time_to: 2.5, offset: 1 }]);
				step("a range shifted", same((await read()).keyframe_times, [0, 1, 3, 3.5]));
				await edit([{ type: "scale_time", time_from: 0, time_to: 3.5, factor: 0.5 }]);
				clip = await read();
				step("a range scaled", same(clip.keyframe_times, [0, 0.5, 1.5, 1.75]) && Math.abs(clip.duration - 1.75) < 0.0015);

				await edit([{ type: "set_properties", name: `Measure ${stamp} renamed`, loop: true, priority: "Movement" }]);
				clip = await read();
				step("the clip's settings", clip.name === `Measure ${stamp} renamed` && clip.loop === true && clip.priority === "Movement");

				await edit([
					{ type: "set_marker", time: 0.5, name: "Step", value: "right" },
					{ type: "remove_marker", time: 1.75, name: "Step" },
				]);
				clip = await read();
				step("a marker changed and one removed", clip.markers.length === 1 && clip.markers[0].value === "right");

				await edit([{ type: "remove_pose", joint: "LeftUpperArm", time: 0.5 }]);
				clip = await read();
				// The arm was keyed at one keyframe, which was then duplicated: only the one named goes.
				const armTimes = clip.poses.filter((pose) => pose.joint === "LeftUpperArm").map((pose) => pose.time);
				step("a pose removed", same(armTimes, [1.75]) && headAt(clip, 0.5) !== undefined);

				// A batch whose last operation cannot be done changes nothing at all.
				const before = await read();
				const refusal = await call("edit_animation", {
					clip_id: clipId,
					expected_revision: revision,
					operations: [
						{ type: "set_pose", joint: "Head", time: 0, rotation: [0, 99, 0] },
						{ type: "remove_keyframe", time: 0 },
						{ type: "move_keyframe", time: 0, to: 9 },
					],
				}).then(
					() => null,
					(error) => error,
				);
				const after = await read();
				step("a batch that cannot finish is refused whole", refusal?.code === "INVALID_ARGUMENT" && /operations\[3\]/.test(refusal.message) && after.content_hash === before.content_hash && after.revision === before.revision);

				const unknown = await call("edit_animation", { clip_id: clipId, expected_revision: revision, operations: [{ type: "explode" }] }).then(
					() => null,
					(error) => error,
				);
				step("an unknown operation is refused by the plugin", unknown?.code === "INVALID_ARGUMENT");

				// A keyframe that holds the pose the clip already has. The stretch from 1.5 to
				// 1.75 seconds starts at a pose with straight easing, so the head must be where
				// it was at the new keyframe and on both sides of it. The stretch from 0 is
				// eased, so a keyframe there is reported as changing the motion.
				const probe = async (time) => (await call("preview_animation", { clip_id: clipId, time, joints: ["Head"] }, 60000)).joints.Head.rotation;
				const stretch = [1.52, 1.56, 1.6, 1.65, 1.7];
				const was = [];
				for (const time of stretch) was.push(await probe(time));
				const held = await call("edit_animation", { clip_id: clipId, expected_revision: revision, operations: [{ type: "add_keyframe", time: 1.6, hold: true }] });
				revision = held.revision;
				let drift = 0;
				for (const [index, time] of stretch.entries()) {
					const now = await probe(time);
					drift = Math.max(drift, ...now.map((value, axis) => angleBetween(value, was[index][axis])));
				}
				step("a keyframe that holds a straight stretch leaves the motion as it was", held.held?.length === 1 && held.held[0].motion_changed === undefined && drift < 0.02);
				const eased = await call("edit_animation", { clip_id: clipId, expected_revision: revision, operations: [{ type: "add_keyframe", time: 0.25, hold: true }] });
				revision = eased.revision;
				step("one that splits an eased stretch says which joints changed", eased.held?.[0]?.motion_changed?.includes("Head") === true);
				await edit([{ type: "remove_keyframe", time: 1.6 }, { type: "remove_keyframe", time: 0.25 }]);

				// The checks: this clip loops, and its head ends 15 degrees from where it starts.
				// With the speed limit lowered far enough, its ordinary turns count as abrupt.
				const checked = await call("validate_animation", { clip_id: clipId });
				const mismatch = checked.issues?.find((issue) => issue.code === "LOOP_ROTATION_MISMATCH" && issue.joints?.[0] === "Head");
				step("validation measures a loop that does not close", checked.valid === true && checked.errors === 0 && mismatch && Math.abs(mismatch.measured - 15) < 0.01 && mismatch.threshold === 2);
				const strict = await call("validate_animation", { clip_id: clipId, thresholds: { speed_degrees_per_second: 20, loop_rotation_degrees: 90 } });
				step("validation uses the limits it is given", strict.counts?.LOOP_ROTATION_MISMATCH === undefined && strict.counts?.ABRUPT_ROTATION >= 1 && strict.thresholds?.speed_degrees_per_second === 20);

				// The edited clip still plays: the engine gives the head's pose at a keyframe.
				const sampled = await call("preview_animation", { clip_id: clipId, time: 0.5, joints: ["Head"] }, 60000);
				step("the edited clip samples", angleBetween(sampled.joints.Head.rotation[1], 25) < 0.01);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				// A plugin from before these operations knows only how to set a pose.
				outdated = /unknown operation type/.test(message);
				failed.push(`stopped: ${message}`);
			}
			const question = "Every kind of edit does what it says, read back from Studio: poses, offsets, easing, keyframes, retiming, settings, markers, quaternions, paged reads, hold keyframes, validation, and a refused batch";
			results.push(outdated ? skipped("Edits", question, "The plugin in Studio predates these operations. Reinstall it and run again.") : judge("Edits", question, failed.length, 0, "failed steps", failed.join("; ")));
		}

		// Timings against the targets in the requirements (section 15), on the two reference
		// clips. The times are taken here, where an adapter would take them.
		{
			const samples = 30;
			const measure = async (label, target, run) => {
				const times = [];
				for (let index = 0; index < samples; index += 1) times.push(await run(index));
				results.push(judge("Timing", `${label}, 95th percentile of ${samples}`, Math.round(percentile(times, 0.95)), target, "ms"));
			};
			const build = async (name, keyframes) => {
				const opened = await call("open_animation", { rig_id: main.rig.rig_id, name: `Measure ${stamp} ${name}` });
				const operations = referenceOperations(keyframes);
				let revision = opened.revision;
				for (let first = 0; first < operations.length; first += 255) {
					revision = (await call("edit_animation", { clip_id: opened.clip_id, expected_revision: revision, operations: operations.slice(first, first + 255) }, 60000)).revision;
				}
				return { clipId: opened.clip_id, revision };
			};
			const small = await build("Ref-S", 31);
			const long = await build("Ref-L", 301);

			await measure("inspect_rig summary", 300, async () => (await timed("inspect_rig", { rig_id: main.rig.rig_id })).ms);
			await measure("edit_animation, a batch of 50 operations on Ref-S", 1000, async (index) => {
				const operations = Array.from({ length: 50 }, (_, step) => ({ type: "set_pose", joint: R15[step % 15], time: ((index + step) % 31) / 10, rotation: [0, (index + step) % 60, 0] }));
				const { result, ms } = await timed("edit_animation", { clip_id: small.clipId, expected_revision: small.revision, operations });
				small.revision = result.revision;
				return ms;
			});
			await measure("edit_animation, one joint at one keyframe on Ref-L", 1000, async (index) => {
				const { result, ms } = await timed("edit_animation", {
					clip_id: long.clipId,
					expected_revision: long.revision,
					operations: [{ type: "set_pose", joint: "Head", time: 15, rotation: [0, 20 + (index % 5), 0] }],
				});
				long.revision = result.revision;
				return ms;
			});
			let summaryBytes = 0;
			await measure("read_animation summary on Ref-L", 500, async () => {
				const { result, ms } = await timed("read_animation", { clip_id: long.clipId });
				summaryBytes = Buffer.byteLength(JSON.stringify(result));
				return ms;
			});
			results.push(judge("Timing", "read_animation summary on Ref-L, size", summaryBytes, 16384, "bytes"));
			await measure("sample one time of Ref-L and draw a pose picture", 1000, async () => {
				const started = performance.now();
				const sampled = await call("preview_animation", { clip_id: long.clipId, time: 15.05, render: true }, 60000);
				render.renderPose(render.parsePose(sampled.pose), ["three_quarter"], 384);
				return performance.now() - started;
			});
			await measure("validate_animation on Ref-L", 1000, async () => (await timed("validate_animation", { clip_id: long.clipId })).ms);
			await measure("a filmstrip of eight frames of Ref-S with a comparison", 3000, async () => {
				const started = performance.now();
				const strip = await call("preview_animation", { clip_id: small.clipId, times: [0, 0.4, 0.8, 1.2, 1.6, 2, 2.4, 2.8], render: true, compare_with: long.clipId, track: ["LeftFoot"] }, 60000);
				render.renderComparison(strip.pose.frames.map((parts) => render.parsePose({ parts })), strip.pose.compare.map((parts) => render.parsePose({ parts })), "right", 192, render.parsePose({ parts: strip.pose.rest }));
				return performance.now() - started;
			});
		}

		// Leave the place as tidy as the tools allow: working copies go, saved clips stay.
		let discarded = 0;
		let leftover = "";
		for (const clipId of made) {
			try {
				const current = await call("read_animation", { clip_id: clipId });
				await call("discard_animation", { clip_id: clipId, expected_revision: current.revision });
				discarded += 1;
			} catch (error) {
				leftover = error instanceof Error ? error.message : String(error);
			}
		}
		results.push(
			skipped(
				"Tidy",
				`Discarded ${discarded} of the ${made.length} working copies this run made; saved ${saved} new ${saved === 1 ? "clip" : "clips"} ("Measure fixture ..."), kept for later runs`,
				leftover ? `Not all could be discarded: ${leftover}` : "",
			),
		);

		results.push(skipped("E6", "Undo", "Needs a person to press Ctrl+Z."));
		results.push(skipped("E2", "Screenshots", "The capture path is gated off."));

		const report = {
			measured_at: new Date().toISOString(),
			place_id: session.placeId,
			place_name: session.placeName,
			plugin_version: session.pluginVersion,
			rigs: Object.fromEntries(Object.entries(rigs).map(([jointClass, rig]) => [jointClass, rig ? rig.name : null])),
			rounds: options.rounds,
			results,
		};
		const directory = join(ROOT, "build", "measurements");
		mkdirSync(directory, { recursive: true });
		const file = join(directory, `measure-${stamp}.json`);
		writeFileSync(file, `${JSON.stringify(report, null, 2)}\n`);

		for (const result of results) {
			const value = result.verdict === "skipped" ? "" : ` ${result.measured} ${result.unit} (limit ${result.limit})`;
			process.stdout.write(`${result.verdict.toUpperCase().padEnd(7)} ${result.id.padEnd(6)} ${result.question}${value}${result.detail ? ` [${result.detail}]` : ""}\n`);
		}
		const vectorsFile = join(directory, `studio-vectors-${stamp}.json`);
		writeFileSync(vectorsFile, `${JSON.stringify({ recorded_at: report.measured_at, joint: "Head", time: 1, vectors }, null, 2)}\n`);
		process.stdout.write(`\nWritten to ${file}\nand ${vectorsFile}\n`);
		return results.some((result) => result.verdict === "fail") ? 1 : 0;
	} finally {
		broker.close();
	}
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	main().then(
		(code) => process.exit(code),
		(error) => {
			process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
			process.exit(2);
		},
	);
}
