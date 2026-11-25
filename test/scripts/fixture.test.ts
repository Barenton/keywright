import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

// Compiled tests live in dist/test, two levels below the project root.
const ROOT = fileURLToPath(new URL("../../../", import.meta.url));

/** Every Luau module of the installed plugin, as paths inside plugin/src. */
const pluginSources = () =>
	readdirSync(join(ROOT, "plugin", "src"), { recursive: true, encoding: "utf8" })
		.filter((file) => file.endsWith(".luau"))
		.sort();
const SCRIPT = join(ROOT, "scripts", "prepare-studio-fixture.mjs");

interface Plan {
	build: string;
	dir: string;
	files: Record<string, string>;
	id: string;
	marker: string;
}
interface FixtureModule {
	MARKER_NAME: string;
	MARKER_PREFIX: string;
	MODE_ATTRIBUTE: string;
	FIXTURE_FILES: string[];
	newFixtureId(): string;
	markerValue(id: string): string;
	isInside(parent: string, child: string): boolean;
	planFixture(root: string, id: string): Plan;
	placeProject(marker: string): { tree: Record<string, unknown> };
	prepareFixture(
		root?: string,
		options?: { id?: string; build?: (project: string, place: string, cwd: string) => void },
	): { plan: Plan; manifest: { id: string; marker_value: string; place: string; sha256: Record<string, string> } };
}

const fixture = (await import(new URL("../../../scripts/prepare-studio-fixture.mjs", import.meta.url).href)) as FixtureModule;
const fakeBuild = (_project: string, place: string) => writeFileSync(place, "not a real place");

test("each fixture gets a unique, explicit marker", () => {
	const first = fixture.newFixtureId();
	const second = fixture.newFixtureId();
	assert.match(first, /^[0-9a-f]{32}$/);
	assert.notEqual(first, second);
	assert.equal(fixture.markerValue(first), `keywright-fixture/1/${first}`);
	assert.throws(() => fixture.markerValue("not-an-id"));
	assert.throws(() => fixture.markerValue(first.toUpperCase()));
});

test("path containment rejects parents, siblings and unrelated paths", () => {
	assert.equal(fixture.isInside("/p/build", "/p/build"), true);
	assert.equal(fixture.isInside("/p/build", "/p/build/fixture/a.rbxl"), true);
	assert.equal(fixture.isInside("/p/build", "/p"), false);
	assert.equal(fixture.isInside("/p/build", "/p/build/../src/x"), false);
	assert.equal(fixture.isInside("/p/build", "/p/build-other/x"), false);
	assert.equal(fixture.isInside("/p/build", "/etc/passwd"), false);
});

test("a plan only names files inside build/fixture", () => {
	const plan = fixture.planFixture("/p", fixture.newFixtureId());
	assert.equal(plan.dir, join("/p", "build", "fixture"));
	assert.deepEqual(Object.keys(plan.files).sort(), [...fixture.FIXTURE_FILES].sort());
	for (const path of Object.values(plan.files)) assert.ok(fixture.isInside(plan.dir, path), path);
});

test("the place definition holds the marker, a baseplate and no scripts", () => {
	const marker = fixture.markerValue(fixture.newFixtureId());
	const project = fixture.placeProject(marker);
	const text = JSON.stringify(project);
	assert.deepEqual(Object.keys(project.tree).sort(), ["$className", "ServerStorage", "Workspace"]);
	assert.ok(text.includes(`"${fixture.MARKER_NAME}":{"$className":"StringValue","$properties":{"Value":"${marker}"}}`));
	assert.doesNotMatch(text, /Script|\$path/);
	// The marker carries an id and nothing that could connect or authenticate.
	assert.doesNotMatch(text, /port|code|secret|credential/i);
});

test("a fixture is prepared in neither mode, and nothing in a place can approve a screenshot", () => {
	const read = (...parts: string[]) => readFileSync(join(ROOT, ...parts), "utf8");
	const guard = read("plugin", "probe", "FixtureGuard.luau");
	assert.ok(guard.includes(`FixtureGuard.MODE_ATTRIBUTE = "${fixture.MODE_ATTRIBUTE}"`));
	// The place definition sets no attributes at all, so it cannot arrive in screenshot mode.
	const text = JSON.stringify(fixture.placeProject(fixture.markerValue(fixture.newFixtureId())));
	assert.doesNotMatch(text, /\$attributes|Armed|ScreenshotMode/);
	// The installed plugin never opens the capture gate; only the probe entry point does.
	const sources = pluginSources().map((file) => [file, read("plugin", "src", file)] as const);
	assert.doesNotMatch(read("plugin", "Main.server.luau"), /setCaptureGate|setGate|FixtureGuard|Approval|E2Scene/);
	for (const [file, source] of sources) {
		assert.doesNotMatch(source, /setCaptureGate\(function|setGate\(function|FixtureGuard|Approval|E2Scene/, file);
	}
	const entry = read("plugin", "probe", "Probe.server.luau").replace(/--[^\n]*/g, "");
	assert.match(entry, /Preview\.setCaptureGate\(function/);
	// Approval is given in exactly one place: the panel button's handler, with what was typed there.
	assert.equal(entry.split("Approval.arm(").length - 1, 1);
	assert.match(entry, /approve\.MouseButton1Click:Connect\(function\(\)[\s\S]{0,200}Approval\.arm\(state, look\(\), typed\)/);
	// The only attributes read from the place are the connection details and the mode; none reaches approval.
	const attributes = [...entry.matchAll(/GetAttribute\(([^)]*)\)/g)].map((match) => match[1]);
	assert.deepEqual(attributes.sort(), ['"PairingCode"', '"Port"', "FixtureGuard.MODE_ATTRIBUTE"].sort());
	assert.doesNotMatch(entry, /GetAttributeChangedSignal|AttributeChanged/);
	// The rig is always the probe's own: built here, never adopted from the place.
	assert.match(entry, /if workspace:FindFirstChild\(E2Scene\.RIG_NAME\) then[\s\S]{0,200}else\s+local built = SyntheticRig\.build\(/);
	assert.match(entry, /Approval\.new\(marker, detail, rig\)/);
});

test("nothing on the screenshot path writes to a camera or drives the undo history", () => {
	const read = (...parts: string[]) => readFileSync(join(ROOT, ...parts), "utf8");
	const path = [
		...pluginSources().map((file) => ["plugin", "src", file]),
		["plugin", "Main.server.luau"],
		["plugin", "probe", "Probe.server.luau"],
		["plugin", "probe", "Approval.luau"],
		["plugin", "probe", "E2Scene.luau"],
		["plugin", "probe", "FixtureGuard.luau"],
	];
	for (const parts of path) {
		const source = read(...parts).replace(/--[^\n]*/g, "");
		const name = parts.join("/");
		// No assignment to the current camera or to any camera property, and no camera methods that move it.
		assert.doesNotMatch(source, /CurrentCamera\s*=[^=]/, name);
		assert.doesNotMatch(source, /[Cc]amera\w*\.(CFrame|Focus|FieldOfView|CameraType|CameraSubject|DiagonalFieldOfView|MaxAxisFieldOfView|FieldOfViewMode)\s*=[^=]/, name);
		assert.doesNotMatch(source, /:(Zoom|SetRoll|PanUnits|TiltUnits|Interpolate|SetCameraPanMode|ZoomToExtents)\(/, name);
		assert.doesNotMatch(source, /ResetWaypoints|:Undo\(|:Redo\(|SetWaypoint/, name);
	}
	// The experiment probes, which do drive undo and redo, are loaded only outside screenshot mode.
	const entry = read("plugin", "probe", "Probe.server.luau");
	assert.equal(entry.split('require("./Probes")').length - 1, 1);
	const screenshotBranch = entry.slice(entry.indexOf("if screenshotMode then"), entry.indexOf('local Probes = require("./Probes")'));
	assert.match(screenshotBranch, /Preview\.setCaptureGate\(function/);
	assert.match(screenshotBranch, /\nelse\n\t$/);
	assert.doesNotMatch(screenshotBranch, /Probes/);
	// Outside screenshot mode the gate is never opened.
	assert.doesNotMatch(entry.slice(entry.indexOf('local Probes = require("./Probes")')), /setCaptureGate\(function/);
});

test("preparing writes exactly four files, all inside build/fixture, and replaces the previous fixture", () => {
	const root = mkdtempSync(join(tmpdir(), "keywright-fixture-"));
	try {
		writeFileSync(join(root, "outside.txt"), "untouched");
		const first = fixture.prepareFixture(root, { build: fakeBuild });
		assert.deepEqual(readdirSync(first.plan.dir).sort(), [...fixture.FIXTURE_FILES].sort());
		assert.deepEqual(readdirSync(root).sort(), ["build", "outside.txt"]);
		assert.deepEqual(readdirSync(join(root, "build")), ["fixture"]);
		assert.equal(readFileSync(join(root, "outside.txt"), "utf8"), "untouched");

		const second = fixture.prepareFixture(root, { build: fakeBuild });
		assert.notEqual(second.manifest.id, first.manifest.id);
		assert.deepEqual(readdirSync(second.plan.dir).sort(), [...fixture.FIXTURE_FILES].sort());
		assert.ok(readFileSync(second.plan.files["INSTRUCTIONS.md"] as string, "utf8").includes(second.manifest.id));
		assert.ok(!readFileSync(second.plan.files["INSTRUCTIONS.md"] as string, "utf8").includes(first.manifest.id));
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});

test("preparing refuses to write through a symlinked build or fixture directory", () => {
	const root = mkdtempSync(join(tmpdir(), "keywright-fixture-"));
	const elsewhere = mkdtempSync(join(tmpdir(), "keywright-elsewhere-"));
	try {
		symlinkSync(elsewhere, join(root, "build"));
		assert.throws(() => fixture.prepareFixture(root, { build: fakeBuild }), /symbolic link/);
		assert.deepEqual(readdirSync(elsewhere), []);

		rmSync(join(root, "build"));
		mkdirSync(join(root, "build"));
		symlinkSync(elsewhere, join(root, "build", "fixture"));
		assert.throws(() => fixture.prepareFixture(root, { build: fakeBuild }), /symbolic link/);
		assert.deepEqual(readdirSync(elsewhere), []);
	} finally {
		rmSync(root, { recursive: true, force: true });
		rmSync(elsewhere, { recursive: true, force: true });
	}
});

test("the preparation script can only read and write files and run rojo", () => {
	const source = readFileSync(SCRIPT, "utf8");
	const imports = [...source.matchAll(/^import .* from "([^"]+)";$/gm)].map((match) => match[1]).sort();
	assert.deepEqual(imports, ["node:child_process", "node:crypto", "node:fs", "node:path", "node:url"]);
	assert.doesNotMatch(source, /\bimport\(|\brequire\(/);
	assert.deepEqual(
		[...source.matchAll(/^import \{([^}]+)\} from "node:child_process";$/gm)].map((match) => match[1]?.trim()),
		["execFileSync"],
	);
	const calls = [...source.matchAll(/execFileSync\(([^,)]*)/g)].map((match) => match[1]?.trim());
	assert.deepEqual(calls, ['"rojo"']);
});

test("the automated Studio harness is gone and nothing aliases it", () => {
	assert.equal(existsSync(join(ROOT, "scripts", "studio-probe.mjs")), false);
	const scripts = (JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")) as { scripts: Record<string, string> }).scripts;
	assert.equal(scripts["probe:studio"], undefined);
	for (const [name, command] of Object.entries(scripts)) {
		assert.doesNotMatch(command, /studio-probe|RobloxStudio|taskkill/i, name);
	}
	// No script in the project launches Studio, installs into its plugins folder or ends a process.
	for (const name of readdirSync(join(ROOT, "scripts"))) {
		const source = readFileSync(join(ROOT, "scripts", name), "utf8");
		assert.doesNotMatch(source, /RobloxStudioBeta|taskkill|Start-Process|Roblox["', ]+Plugins/i, name);
	}
});

test("a real fixture is built in the project and passes the headless place check", () => {
	const { plan, manifest } = fixture.prepareFixture();
	assert.equal(plan.dir, join(ROOT, "build", "fixture"));
	assert.deepEqual(readdirSync(plan.dir).sort(), [...fixture.FIXTURE_FILES].sort());
	for (const [name, expected] of Object.entries(manifest.sha256)) {
		const actual = createHash("sha256").update(readFileSync(join(plan.dir, name))).digest("hex");
		assert.equal(actual, expected, name);
	}
	assert.equal(manifest.marker_value, plan.marker);
	// Lune parses the place file and applies the same guard the probe uses.
	const output = execFileSync("lune", ["run", "plugin/test/probe/fixture.luau"], { cwd: ROOT, encoding: "utf8" });
	assert.match(output, /11\/11 fixture checks passed/);
});
