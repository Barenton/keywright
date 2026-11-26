// Prints the CHANGELOG.md section for one version, which the release workflow uses as the
// release's notes. Fails if there is none, so a release cannot go out undescribed.
//
// Usage: node scripts/release-notes.mjs <version>

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * The text under "## [version]" up to the next heading of that level, or undefined. The
 * link definitions at the end of the file belong to no one section and are left out.
 */
export function notesFor(changelog, version) {
	const lines = changelog.split(/\r?\n/);
	const start = lines.findIndex((line) => line.startsWith(`## [${version}]`));
	if (start === -1) return undefined;
	const rest = lines.slice(start + 1);
	const end = rest.findIndex((line) => line.startsWith("## "));
	const text = (end === -1 ? rest : rest.slice(0, end))
		.filter((line) => !/^\[[^\]]+\]: /.test(line))
		.join("\n")
		.trim();
	return text === "" ? undefined : text;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const version = process.argv[2];
	const notes = version && notesFor(readFileSync(join(ROOT, "CHANGELOG.md"), "utf8"), version);
	if (!notes) {
		process.stderr.write(`CHANGELOG.md has no notes for version ${version ?? "(none given)"}.\n`);
		process.exit(1);
	}
	process.stdout.write(`${notes}\n`);
}
