// Runs every offline Luau suite: each file under plugin/test whose name ends in
// .test.luau, one after another with Lune, from the project root. Other files there are
// tools that are run on their own (see the comment at the top of each).

import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const suites = readdirSync(join(ROOT, "plugin", "test"), { recursive: true, encoding: "utf8" })
	.filter((file) => file.endsWith(".test.luau"))
	.map((file) => join("plugin", "test", file).replaceAll("\\", "/"))
	.sort();

if (suites.length === 0) {
	console.error("no Luau suites found under plugin/test");
	process.exit(1);
}
const failed = [];
for (const suite of suites) {
	console.log(`# ${suite}`);
	const result = spawnSync("lune", ["run", suite], { cwd: ROOT, stdio: "inherit" });
	if (result.error) {
		console.error(`could not run lune: ${result.error.message}`);
		process.exit(1);
	}
	if (result.status !== 0) failed.push(suite);
}
console.log(`\n${suites.length - failed.length} of ${suites.length} Luau suites passed`);
if (failed.length > 0) {
	for (const suite of failed) console.log(`FAILED ${suite}`);
	process.exit(1);
}
