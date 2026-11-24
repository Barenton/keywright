// Prepares a disposable Roblox Studio fixture. Preparation only.
//
// It writes four files into build/fixture/ inside this project: a Rojo project, the
// place file built from it, a manifest with hashes, and instructions for the person who
// will work in Studio. The place carries a unique fixture marker.
//
// It does not start, stop or attach to Studio, install a plugin, open a network
// listener, pair with anything, or write outside this project. The only program it runs
// is `rojo build`, which reads the project file it has just written and writes the place.
//
// Usage: npm run prepare:fixture

import { execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const MARKER_NAME = "MotionBridgeFixture";
export const MARKER_PREFIX = "motion-bridge-fixture/1/";
// Attribute a person sets on the marker to start the probe in screenshot mode. It selects
// a mode and approves nothing. Never set here.
export const MODE_ATTRIBUTE = "ScreenshotMode";
export const FIXTURE_FILES = ["fixture.project.json", "fixture.rbxl", "manifest.json", "INSTRUCTIONS.md"];

const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export function newFixtureId() {
	return randomBytes(16).toString("hex");
}

export function markerValue(id) {
	if (!/^[0-9a-f]{32}$/.test(id)) throw new Error("A fixture id is 32 lowercase hex characters.");
	return `${MARKER_PREFIX}${id}`;
}

/** True when `child` is `parent` or lies beneath it. Both must be absolute. */
export function isInside(parent, child) {
	const path = relative(parent, child);
	return path === "" || (!path.startsWith("..") && !isAbsolute(path));
}

/** Where a fixture goes. Every path is checked to lie in <root>/build/fixture. */
export function planFixture(root, id) {
	const build = join(root, "build");
	const dir = join(build, "fixture");
	const files = Object.fromEntries(FIXTURE_FILES.map((name) => [name, join(dir, name)]));
	for (const path of [dir, ...Object.values(files)]) {
		if (!isInside(build, path)) throw new Error(`Refusing to plan a fixture path outside ${build}: ${path}`);
	}
	return { root, build, dir, files, id, marker: markerValue(id) };
}

/** The whole place: the marker and a baseplate. No scripts. */
export function placeProject(marker) {
	return {
		name: "MotionBridgeFixture",
		tree: {
			$className: "DataModel",
			ServerStorage: {
				$className: "ServerStorage",
				[MARKER_NAME]: { $className: "StringValue", $properties: { Value: marker } },
			},
			Workspace: {
				$className: "Workspace",
				Baseplate: { $className: "Part", $properties: { Anchored: true, Size: [64, 1, 64], Position: [0, -0.5, 0] } },
			},
		},
	};
}

export function instructions(plan, created) {
	return `# Motion Bridge disposable Studio fixture

Fixture id: \`${plan.id}\`
Created: ${created}

## What this is

\`fixture.rbxl\` is an unpublished place that holds a baseplate and one marker:

- \`ServerStorage.${MARKER_NAME}\` (StringValue) = \`${plan.marker}\`

It contains no scripts. The Motion Bridge probe code refuses to act unless the open
place is unpublished, is in edit mode, and carries a marker of this form. The rules
are in \`plugin/probe/FixtureGuard.luau\`.

\`manifest.json\` lists the SHA-256 of each file here.

## What preparing it did and did not do

Preparing this fixture only wrote the four files in this folder. It did not start,
stop or attach to Studio, install a plugin, enter anything in the command bar, change
a permission, open a network listener, or pair with a broker.

## What still needs a person in Studio

Nothing in this project opens this place or runs anything in Studio. The experiments
below can only be carried out by a person working in Studio on a disposable place such
as this one. The in-Studio procedure for them is not implemented yet.

| Experiment | Why it needs a person |
|---|---|
| E1 plugin WebSocket | The plugin's transport only exists inside Studio. |
| E2 screenshot capture | Needs Studio's viewport and a person to answer the permission prompt, once granting and once denying. |
| E3 Motor6D and AnimationConstraint rigs | Needs the engine to play a clip on both rigs in edit mode. |
| E4 native clip evaluation | Needs the engine's animation system. |
| E5 Animation Editor interoperability | Needs a person to save and load a clip with the Animation Editor. |
| E6 undo | Needs Studio's change history. |
| E8 plugin settings across windows | Needs two Studio windows open at once. |
| E9 WSL, mirrored networking | Needs a person to decide to change their WSL configuration. |
| E10 headless parity, Studio half | The reference values must be computed inside Studio. |
| E11 images reaching the model | Needs each MCP client to be checked by a person. |
| Vertical-slice demonstration | Needs a connected Studio session on both rig types. |

Checked without Studio: E7 (broker single instance and foreign listeners), the Lune half
of E10, and the network path of E9 under NAT.

## Screenshots of a preview

Screenshots are off everywhere by default, and the plugin people install can never turn
them on. They are possible only in the probe build, only in this fixture, and only after
a person has approved one scene through one camera in the probe's own panel. Nothing in
this place can give that approval, and nothing moves or changes the camera for you: the
picture is whatever you have framed by hand.

1. Before loading the probe, add a boolean attribute named \`${MODE_ATTRIBUTE}\`, set to
   true, to \`ServerStorage.${MARKER_NAME}\`. This only selects screenshot mode: the probe
   then builds one invisible synthetic rig on the baseplate, shows a panel, and does not
   load the experiment probes that drive undo and redo.
2. Frame the camera by hand so that the whole rig is in the picture, from above the
   baseplate (select the rig and press F), then clear the selection and stay on the 3D
   viewport tab.
3. In the probe's panel, type this fixture's id, \`${plan.id}\`, and press the approve
   button. The panel says whether the scene and camera were approved, and why not.

Approval covers exactly that scene and that camera position, field of view and viewport
size, and only this fixture's id is accepted. It is withdrawn if a screenshot is
cancelled or runs out of time, the camera or tab is switched, you withdraw it in the
panel, the probe unloads, or anything in the scene or camera differs while an image is
being taken. To approve again, type the id and press the button once more.

A preview that asks for a screenshot then shows its own disposable copy of the rig where
the invisible rig stands and asks Studio for a PNG through StudioCaptureService (Studio
shows its own permission prompt). The copy, as posed, must be wholly in the picture and
above the baseplate, or no image is taken. None of this has been run in Studio yet.

If a rig named MotionBridgeE2Rig is already in the place when the probe loads, remove it
and reload: the probe only ever uses a rig it built itself in that session.

## Handling

- Treat the place as disposable. Do not save it over another place and do not publish it.
- Deleting this folder removes the fixture completely. Preparing again creates a new
  fixture with a new id.
`;
}

function runRojo(project, place, cwd) {
	execFileSync("rojo", ["build", project, "-o", place], { cwd, stdio: "ignore" });
}

/**
 * Writes a new fixture into <root>/build/fixture, replacing any previous one there.
 * `build` is how the place file is produced; tests replace it.
 */
export function prepareFixture(root = PROJECT_ROOT, { id = newFixtureId(), build = runRojo } = {}) {
	const plan = planFixture(root, id);

	// A symlinked build or fixture directory could redirect writes outside the project.
	for (const path of [plan.build, plan.dir]) {
		if (existsSync(path) && lstatSync(path).isSymbolicLink()) {
			throw new Error(`Refusing to write through a symbolic link: ${path}`);
		}
	}
	mkdirSync(plan.build, { recursive: true });
	if (!isInside(realpathSync(root), realpathSync(plan.build))) {
		throw new Error(`Refusing to write outside the project: ${plan.build}`);
	}
	rmSync(plan.dir, { recursive: true, force: true });
	mkdirSync(plan.dir);

	const created = new Date().toISOString();
	writeFileSync(plan.files["fixture.project.json"], `${JSON.stringify(placeProject(plan.marker), null, 2)}\n`);
	build(plan.files["fixture.project.json"], plan.files["fixture.rbxl"], root);
	writeFileSync(plan.files["INSTRUCTIONS.md"], instructions(plan, created));

	const hashes = {};
	for (const name of FIXTURE_FILES) {
		if (name === "manifest.json") continue;
		hashes[name] = createHash("sha256").update(readFileSync(plan.files[name])).digest("hex");
	}
	const manifest = {
		kind: "motion-bridge-disposable-fixture",
		id: plan.id,
		created,
		marker_name: MARKER_NAME,
		marker_value: plan.marker,
		place: "fixture.rbxl",
		sha256: hashes,
	};
	writeFileSync(plan.files["manifest.json"], `${JSON.stringify(manifest, null, 2)}\n`);
	return { plan, manifest };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	const { plan, manifest } = prepareFixture();
	console.log(`Fixture ${manifest.id} prepared in ${plan.dir}`);
	console.log("Nothing was started or installed. See INSTRUCTIONS.md in that folder.");
}
