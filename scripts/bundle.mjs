// Makes the single-file release of the adapter: build/release/keywright.mjs, all of
// Keywright's TypeScript and its dependencies in one file that Node runs as it is. Beside
// it go the built plugin, Keywright.rbxm (which the bundle's install-plugin looks for in
// its own folder), and THIRD_PARTY_LICENSES.txt, the licences of the packages bundled.
//
// Usage: npm run build:release        (builds the plugin first)
//        node scripts/bundle.mjs [--out <folder>] [--no-plugin]

import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The licence text of a package folder: its LICENSE file, or failing that the licence named in package.json. */
function licenceOf(folder) {
	const file = readdirSync(folder).find((name) => /^(licen[cs]e|copying)(\.|$)/i.test(name));
	if (file) return readFileSync(join(folder, file), "utf8").trim();
	const manifest = JSON.parse(readFileSync(join(folder, "package.json"), "utf8"));
	return `Licensed under ${manifest.license ?? "an unstated licence"}; the package carries no licence file.`;
}

/** The node_modules package each bundled file came from, as the folder that holds its package.json. */
function bundledPackages(metafile) {
	const folders = new Set();
	for (const input of Object.keys(metafile.inputs)) {
		const match = /^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//.exec(input);
		if (match) folders.add(resolve(ROOT, match[1]));
	}
	return [...folders].sort();
}

export async function bundle({ out = join(ROOT, "build", "release"), plugin = true } = {}) {
	const { version } = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
	mkdirSync(out, { recursive: true });
	const outfile = join(out, "keywright.mjs");
	const result = await build({
		entryPoints: [join(ROOT, "src", "cli.ts")],
		outfile,
		bundle: true,
		platform: "node",
		format: "esm",
		target: "node22",
		metafile: true,
		logLevel: "warning",
		legalComments: "none",
		define: {
			__KEYWRIGHT_BUNDLED__: "true",
			__KEYWRIGHT_VERSION__: JSON.stringify(version),
			// ws would look for these optional speed-ups wherever Node searches for packages,
			// including folders above the release's. The release uses ws's own code instead.
			"process.env.WS_NO_BUFFER_UTIL": '"1"',
			"process.env.WS_NO_UTF_8_VALIDATE": '"1"',
		},
		external: ["bufferutil", "utf-8-validate"],
		// Paths in the metafile are then relative to the project, wherever this runs from.
		absWorkingDir: ROOT,
		// Some dependencies are CommonJS and call require(); an ES module has none of its own.
		banner: { js: 'import { createRequire as __keywrightRequire } from "node:module"; const require = __keywrightRequire(import.meta.url);' },
	});

	const notices = bundledPackages(result.metafile).map((folder) => {
		const manifest = JSON.parse(readFileSync(join(folder, "package.json"), "utf8"));
		return `${manifest.name} ${manifest.version}\n${"-".repeat(72)}\n${licenceOf(folder)}\n`;
	});
	writeFileSync(
		join(out, "THIRD_PARTY_LICENSES.txt"),
		`keywright.mjs ${version} contains the following packages, under their own licences.\n\n${notices.join("\n")}`,
	);

	if (plugin) {
		const built = join(ROOT, "build", "Keywright.rbxm");
		if (!existsSync(built)) throw new Error("There is no build/Keywright.rbxm. Run npm run build:plugin first.");
		copyFileSync(built, join(out, "Keywright.rbxm"));
	}
	return { outfile, packages: notices.length };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const flag = process.argv.indexOf("--out");
	const made = await bundle({ out: flag > 0 ? resolve(process.argv[flag + 1]) : undefined, plugin: !process.argv.includes("--no-plugin") });
	process.stdout.write(`Wrote ${made.outfile}, bundling ${made.packages} packages.\n`);
}
