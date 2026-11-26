// Writes docs/tools.md from the tools the built adapter offers. With --check, writes
// nothing and fails if the file is out of date.
//
// Usage: npm run docs:tools        (builds first)
//        node scripts/tool-reference.mjs [--check]

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const FILE = join(ROOT, "docs", "tools.md");
const { listTools, renderReference } = await import(new URL("../dist/src/mcp/reference.js", import.meta.url).href);

const text = renderReference(await listTools());
if (process.argv.includes("--check")) {
	let current = "";
	try {
		current = readFileSync(FILE, "utf8");
	} catch {}
	if (current !== text) {
		process.stderr.write("docs/tools.md is out of date. Run: npm run docs:tools\n");
		process.exit(1);
	}
} else {
	writeFileSync(FILE, text);
	process.stdout.write("Wrote docs/tools.md.\n");
}
