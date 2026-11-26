import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { ERROR_CODES } from "../../src/broker/protocol.js";
import { describeType, listTools, renderReference } from "../../src/mcp/reference.js";

const root = new URL("../../../", import.meta.url);
const read = (path: string) => readFileSync(new URL(path, root), "utf8");

test("the tool reference is the one the adapter's tools give", async () => {
	assert.equal(read("docs/tools.md"), renderReference(await listTools()), "run: npm run docs:tools");
});

test("every tool, argument and operation field is described", async () => {
	const missing: string[] = [];
	const walk = (where: string, schema: { properties?: Record<string, { description?: string; items?: unknown }> }) => {
		for (const [name, property] of Object.entries(schema.properties ?? {})) {
			if (!property.description && name !== "type") missing.push(`${where}.${name}`);
		}
	};
	for (const tool of await listTools()) {
		if (!tool.description) missing.push(tool.name);
		walk(tool.name, tool.inputSchema as never);
		const operations = (tool.inputSchema.properties?.operations?.items?.oneOf ?? []) as Array<{ properties?: Record<string, { const?: unknown; description?: string }> }>;
		for (const operation of operations) {
			if (!operation.properties?.type?.description) missing.push(`${tool.name}.${String(operation.properties?.type?.const)}`);
			walk(`${tool.name}.${String(operation.properties?.type?.const)}`, operation as never);
		}
	}
	assert.deepEqual(missing, []);
});

test("types are said in words, with their limits", () => {
	assert.equal(describeType({ type: "number", minimum: 0, maximum: 300 }), "number, 0 to 300");
	assert.equal(describeType({ type: "number", exclusiveMinimum: 0 }), "number, over 0");
	assert.equal(describeType({ type: "integer", minimum: Number.MIN_SAFE_INTEGER, maximum: Number.MAX_SAFE_INTEGER }), "whole number");
	assert.equal(describeType({ type: "string", minLength: 1, maxLength: 100 }), "text, 1 to 100 characters");
	assert.equal(describeType({ type: "array", items: { type: "number" }, minItems: 3, maxItems: 3 }), "3 numbers");
	assert.equal(describeType({ type: "array", items: { type: "string" }, maxItems: 32 }), "list of texts (up to 32 items)");
	assert.equal(describeType({ type: "array", items: { enum: ["a", "b"] }, minItems: 1, maxItems: 2 }), "list of any of `a`, `b` (1 to 2 items)");
	assert.equal(describeType({ anyOf: [{ type: "array", items: { type: "number" }, minItems: 3, maxItems: 3 }, { const: "match" }] }), "3 numbers, or `match`");
});

// Codes as the plugin and the relay raise them: an error code is thrown, a finding code is
// reported. Each must be explained in docs/errors.md.
function luauFiles(dir: URL): string[] {
	return readdirSync(dir, { recursive: true, encoding: "utf8" })
		.filter((file) => file.endsWith(".luau"))
		.map((file) => readFileSync(new URL(file, dir), "utf8"));
}

test("every error code and finding code is explained", () => {
	const errors = read("docs/errors.md");
	const thrown = new Set<string>(ERROR_CODES);
	const findings = new Set<string>();
	for (const source of luauFiles(new URL("plugin/src/", root))) {
		for (const match of source.matchAll(/Errors\.throw\(\s*"([A-Z_]+)"/g)) thrown.add(match[1] as string);
		for (const match of source.matchAll(/code = "([A-Z_]+)"/g)) findings.add(match[1] as string);
	}
	const unexplained = [...thrown, ...findings].filter((code) => !errors.includes(`\`${code}\``));
	assert.deepEqual(unexplained, [], "add these to docs/errors.md");
	assert.ok(thrown.size >= ERROR_CODES.length && findings.size > 5, "the codes were found in the sources");
});
