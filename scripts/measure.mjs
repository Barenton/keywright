#!/usr/bin/env node
// Measures Phase 0 experiments through the ordinary tools, against a Studio session a
// person has already connected.
//
// It talks only to the local broker, the way the MCP adapter does. It does not start,
// stop or attach to Studio, install anything, or touch a file outside build/. It does
// change the place the session has open: it makes working copies, which it discards
// again at the end, and saved clips, which stay, all named "Measure ...". Because of
// that it must be told the id of the place, and refuses any other.
//
// Usage: node scripts/measure.mjs --place-id <id> [--rounds 10000]

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
			results.push(skipped("E1", "A 1 MiB message, reconnection after a broker restart, and two Studio windows", "Not measured by this script."));
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
			for (let step = 0; step <= 10; step += 1) {
				const time = step / 10;
				const [motor, constraint] = await Promise.all(
					[clips.Motor6D, clips.AnimationConstraint].map((clip) => call("preview_animation", { clip_id: clip.clipId, time, joints: JOINTS }, 60000)),
				);
				const difference = largestDifference(motor.joints, constraint.joints);
				degrees = Math.max(degrees, difference.degrees);
				studs = Math.max(studs, difference.studs);
			}
			results.push(judge("E3", "The same clip gives the same joint rotations on both joint classes, at 11 times", degrees, 0.01, "degrees"));
			results.push(judge("E3", "The same clip gives the same joint positions on both joint classes", studs, 0.001, "studs"));
			results.push(skipped("E3", "Part positions, reset, and joints with IsKinematic off", "Not measured by this script. The two rigs may also differ in size."));
		} else {
			results.push(skipped("E3", "The two joint classes against each other", "The place needs one Motor6D rig and one AnimationConstraint rig."));
		}

		// E5: a round trip through saving and opening changes nothing.
		{
			const before = await call("read_animation", { clip_id: main.clipId, hash: true });
			if (typeof before.content_hash !== "string") {
				results.push(skipped("E5", "A round trip through saving and opening changes nothing", "The plugin in Studio predates clip fingerprints. Reinstall it and run again."));
			} else {
				let changed = 0;
				let source = { clipId: main.clipId, revision: before.revision, hash: before.content_hash };
				for (const lap of ["a", "b"]) {
					const name = `Measure ${stamp} ${lap}`;
					await call("save_animation", { clip_id: source.clipId, expected_revision: source.revision, name });
					saved += 1;
					const reopened = await call("open_animation", { rig_id: main.rig.rig_id, source: `saved:${name}` });
					const after = await call("read_animation", { clip_id: reopened.clip_id, hash: true });
					if (after.content_hash !== before.content_hash) changed += 1;
					source = { clipId: reopened.clip_id, revision: after.revision, hash: after.content_hash };
				}
				results.push(judge("E5", "Two round trips through saving and opening leave the clip's fingerprint unchanged", changed, 0, "changed"));
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

				const name = `Measure ${stamp} demo ${jointClass}`;
				const current = await call("read_animation", { clip_id: clipId });
				await call("save_animation", { clip_id: clipId, expected_revision: current.revision, name });
				saved += 1;
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

		// Timings against the targets in the requirements, on this small clip.
		{
			const samples = 30;
			const measure = async (label, target, run) => {
				const times = [];
				for (let index = 0; index < samples; index += 1) times.push(await run(index));
				results.push(judge("Timing", `${label}, 95th percentile of ${samples}`, Math.round(percentile(times, 0.95)), target, "ms"));
			};
			await measure("inspect_rig summary", 300, async () => (await timed("inspect_rig", { rig_id: main.rig.rig_id })).ms);
			await measure("read_animation summary", 500, async () => (await timed("read_animation", { clip_id: main.clipId })).ms);
			let revision = (await call("read_animation", { clip_id: main.clipId })).revision;
			await measure("edit_animation, one joint at one keyframe", 1000, async (index) => {
				const { result, ms } = await timed("edit_animation", {
					clip_id: main.clipId,
					expected_revision: revision,
					operations: [{ type: "set_pose", joint: "Head", time: 1, rotation: [0, 20 + (index % 5), 0] }],
				});
				revision = result.revision;
				return ms;
			});
			await measure("sample one time and draw a pose picture", 1000, async () => {
				const started = performance.now();
				const sampled = await call("preview_animation", { clip_id: main.clipId, time: 0.5, render: true }, 60000);
				render.renderPose(render.parsePose(sampled.pose), ["three_quarter"], 384);
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
				`Discarded ${discarded} of the ${made.length} working copies this run made; ${saved} saved clips named "Measure ${stamp} ..." remain`,
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
		process.stdout.write(`\nWritten to ${file}\n`);
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
