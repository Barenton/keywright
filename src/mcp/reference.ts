// The tool reference in docs/tools.md, written from the tools the adapter itself offers,
// so that it says exactly what an AI app is told. A test fails when the file is out of
// date; `npm run docs:tools` writes it again.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createAdapter, SERVER_INSTRUCTIONS } from "./adapter.js";

interface Schema {
	type?: string;
	description?: string;
	properties?: Record<string, Schema>;
	required?: string[];
	items?: Schema;
	oneOf?: Schema[];
	anyOf?: Schema[];
	enum?: unknown[];
	const?: unknown;
	minimum?: number;
	maximum?: number;
	exclusiveMinimum?: number;
	minLength?: number;
	maxLength?: number;
	minItems?: number;
	maxItems?: number;
}

export interface ListedTool {
	name: string;
	description?: string;
	inputSchema: Schema;
	annotations?: { readOnlyHint?: boolean };
}

/** The tools as an AI app sees them, asked of an adapter that is never connected to a broker. */
export async function listTools(): Promise<ListedTool[]> {
	const server = createAdapter({ home: "", port: 0 });
	const [serverSide, clientSide] = InMemoryTransport.createLinkedPair();
	await server.connect(serverSide);
	const client = new Client({ name: "keywright-reference", version: "0" });
	await client.connect(clientSide);
	try {
		return (await client.listTools()).tools as ListedTool[];
	} finally {
		await client.close();
		await server.close();
	}
}

const code = (value: unknown) => `\`${typeof value === "string" ? value : JSON.stringify(value)}\``;

/** Text for one table cell: on one line, with no character that would end the cell. */
function cell(text: string): string {
	return text.replace(/\s*\n\s*/g, " ").replace(/\|/g, "\\|");
}

function range(low: number | undefined, high: number | undefined, unit: string, above?: number): string {
	if (above !== undefined) return high === undefined ? `over ${above}${unit}` : `over ${above}${unit}, up to ${high}${unit}`;
	if (low !== undefined && high !== undefined) return low === high ? `exactly ${low}${unit}` : `${low} to ${high}${unit}`;
	if (low !== undefined) return `at least ${low}${unit}`;
	if (high !== undefined) return `up to ${high}${unit}`;
	return "";
}

function joined(main: string, limit: string): string {
	return limit === "" ? main : `${main}, ${limit}`;
}

/** What each item of a list must be, said of several. */
function plural(items: Schema): string {
	if (items.enum) return `any of ${items.enum.map(code).join(", ")}`;
	const one = describeType(items);
	const forms: Array<[string, string]> = [
		["whole number", "whole numbers"],
		["number", "numbers"],
		["text", "texts"],
	];
	for (const [singular, many] of forms) {
		if (one.startsWith(singular)) return `${many}${one.slice(singular.length)}`;
	}
	return one;
}

/** What a value must be, in a few words: its type and its limits. */
export function describeType(schema: Schema): string {
	if (schema.const !== undefined) return code(schema.const);
	if (schema.enum) return `one of ${schema.enum.map(code).join(", ")}`;
	const choices = schema.anyOf ?? schema.oneOf;
	if (choices) return choices.map(describeType).join(", or ");
	switch (schema.type) {
		case "number":
		case "integer": {
			const kind = schema.type === "integer" ? "whole number" : "number";
			// A whole number with no limits of its own is still given JavaScript's safe range.
			const low = schema.minimum === Number.MIN_SAFE_INTEGER ? undefined : schema.minimum;
			const high = schema.maximum === Number.MAX_SAFE_INTEGER ? undefined : schema.maximum;
			return joined(kind, range(low, high, "", schema.exclusiveMinimum));
		}
		case "string":
			return joined("text", range(schema.minLength, schema.maxLength, " characters"));
		case "boolean":
			return "true or false";
		case "array": {
			const items = schema.items ?? {};
			const count = range(schema.minItems, schema.maxItems, "");
			if ((items.type === "number" || items.type === "string") && schema.minItems !== undefined && schema.minItems === schema.maxItems) {
				return `${schema.minItems} ${items.type === "number" ? "numbers" : "texts"}`;
			}
			const of = items.type === "object" || items.oneOf ? "objects" : plural(items);
			return `list of ${of}${count === "" ? "" : ` (${count} items)`}`;
		}
		case "object":
			return "object";
		default:
			return "any";
	}
}

interface Row {
	name: string;
	type: string;
	required: boolean;
	description: string;
}

/** One row per argument, and one per field of an argument that is an object or a list of them. */
function rows(schema: Schema, prefix = ""): Row[] {
	const required = new Set(schema.required ?? []);
	const out: Row[] = [];
	for (const [name, property] of Object.entries(schema.properties ?? {})) {
		const full = `${prefix}${name}`;
		out.push({ name: full, type: describeType(property), required: required.has(name), description: property.description ?? "" });
		if (property.type === "object" && property.properties) out.push(...rows(property, `${full}.`));
		if (property.type === "array" && property.items?.type === "object" && property.items.properties) out.push(...rows(property.items, `${full}[].`));
	}
	return out;
}

function table(list: Row[], heading = "Argument"): string[] {
	if (list.length === 0) return [`No ${heading.toLowerCase()}s.`];
	return [
		`| ${heading} | Type | Required | Description |`,
		"|---|---|---|---|",
		...list.map((row) => `| \`${row.name}\` | ${cell(row.type)} | ${row.required ? "yes" : ""} | ${cell(row.description)} |`),
	];
}

/** A list argument whose items are one of several kinds of object, each named by a constant field. */
function variantsOf(schema: Schema): { field: string; argument: string; variants: Schema[] } | undefined {
	for (const [argument, property] of Object.entries(schema.properties ?? {})) {
		const variants = property.items?.oneOf;
		if (property.type !== "array" || !variants) continue;
		const field = Object.keys(variants[0]?.properties ?? {}).find((key) => variants.every((variant) => variant.properties?.[key]?.const !== undefined));
		if (field) return { field, argument, variants };
	}
	return undefined;
}

export function renderReference(tools: ListedTool[]): string {
	const lines: string[] = [
		"# Tool reference",
		"",
		"<!-- Written by `npm run docs:tools` from the tools the adapter offers. Do not edit by hand. -->",
		"",
		"These are the tools Keywright gives an AI app, with the descriptions and arguments the app is given, word for word. Every tool except `get_workspace` and `pair_studio` takes `studio_session`, the id of a Studio window from `get_workspace`. A tool that fails returns an error with a `code`, a `message` and often a `hint`; the codes are listed in [Errors and findings](errors.md).",
		"",
		...tools.map((tool) => `- [\`${tool.name}\`](#${tool.name})`),
		"",
		"## How agents are asked to work",
		"",
		"Besides the tools, an AI app is sent these instructions when it connects:",
		"",
		...SERVER_INSTRUCTIONS.split("\n").map((line) => (line === "" ? ">" : `> ${line}`)),
		"",
	];
	for (const tool of tools) {
		lines.push(`## ${tool.name}`, "");
		if (tool.annotations?.readOnlyHint) lines.push("*Reads only: changes nothing in Studio.*", "");
		lines.push(tool.description ?? "", "");
		const variants = variantsOf(tool.inputSchema);
		lines.push(...table(rows(tool.inputSchema)), "");
		if (!variants) continue;
		lines.push(
			`### Operations`,
			"",
			`Each item of \`${variants.argument}\` is one of these, chosen by its \`${variants.field}\`.`,
			"",
		);
		const names = variants.variants.map((variant) => String(variant.properties?.[variants.field]?.const));
		lines.push(names.map((name) => `[\`${name}\`](#${name})`).join(" · "), "");
		for (const [index, variant] of variants.variants.entries()) {
			const own = variant.properties?.[variants.field];
			lines.push(`#### ${names[index]}`, "", own?.description ?? "", "");
			const fields = rows(variant).filter((row) => row.name !== variants.field);
			lines.push(...table(fields, "Field"), "");
		}
	}
	return `${lines.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd()}\n`;
}
