// The Keywright skill, served through Keywright itself: the animator's guide in
// skills/keywright, by topic and section, for any AI app connected to Keywright. An app
// that can't fetch or install skills still gets it, and it is always the version that
// matches the tools.
//
// The skill's files are the one source. The single-file release has them written into it
// when it is made, so a copy downloaded on its own has them too; from a checkout they are
// read from the skills folder.

import { readFileSync } from "node:fs";
import { BridgeError } from "./broker/protocol.js";
import { skillPath } from "./layout.js";

declare const __KEYWRIGHT_GUIDE__: Record<string, string> | undefined;

/** The guide's topics, and the skill file each one is. */
export const TOPICS = {
	workflow: "SKILL.md",
	rig: "reference/rig.md",
	moves: "reference/moves.md",
	review: "reference/review.md",
} as const;
export type Topic = keyof typeof TOPICS;

/** A skill file, from the release or from the checkout. */
function skillFile(file: string): string {
	if (typeof __KEYWRIGHT_GUIDE__ !== "undefined" && __KEYWRIGHT_GUIDE__ && typeof __KEYWRIGHT_GUIDE__[file] === "string") {
		return __KEYWRIGHT_GUIDE__[file] as string;
	}
	return readFileSync(skillPath(file), "utf8");
}

/**
 * A topic as an agent reads it: the skill file without the header that tells an app when
 * to load it, with its links to the other files given as the get_guide topics they are.
 */
function topicText(topic: Topic): string {
	let text = skillFile(TOPICS[topic]);
	if (text.startsWith("---")) {
		const end = text.indexOf("\n---", 3);
		if (end !== -1) text = text.slice(end + 4).replace(/^\s+/, "");
	}
	return text.replace(/\[reference\/(\w+)\.md\]\(reference\/\w+\.md\)/g, 'get_guide topic "$1"').replace(/\[([^\]]+)\]\(\.\.\/SKILL\.md\)/g, 'get_guide topic "workflow"');
}

/** A topic's sections: its headings of the second level, each with its text up to the next. */
function sectionsOf(text: string): Array<{ title: string; text: string }> {
	const sections: Array<{ title: string; text: string }> = [];
	const lines = text.split("\n");
	let current: { title: string; lines: string[] } | undefined;
	for (const line of lines) {
		const heading = /^## (.+)$/.exec(line);
		if (heading) {
			if (current) sections.push({ title: current.title, text: current.lines.join("\n").trimEnd() });
			current = { title: (heading[1] as string).trim(), lines: [line] };
		} else if (current) {
			current.lines.push(line);
		}
	}
	if (current) sections.push({ title: current.title, text: current.lines.join("\n").trimEnd() });
	return sections;
}

/** The titles of a topic's sections, for asking for one alone. */
export function guideSections(topic: Topic): string[] {
	return sectionsOf(topicText(topic)).map((section) => section.title);
}

/**
 * A topic of the guide, or one section of it: the one whose heading is, or starts with,
 * `section`, ignoring case. Ends with the topic's sections and the other topics, so that
 * the part needed next can be asked for alone.
 */
export function guideText(topic: Topic, section?: string): string {
	const text = topicText(topic);
	const sections = sectionsOf(text);
	let body = text.trimEnd();
	if (section !== undefined) {
		const wanted = section.trim().toLowerCase();
		const found = sections.find((entry) => entry.title.toLowerCase() === wanted) ?? sections.find((entry) => entry.title.toLowerCase().startsWith(wanted));
		if (!found) {
			throw new BridgeError("INVALID_ARGUMENT", `The topic "${topic}" has no section "${section}".`, `Its sections: ${sections.map((entry) => entry.title).join("; ")}.`);
		}
		body = found.text;
	}
	const others = (Object.keys(TOPICS) as Topic[]).filter((name) => name !== topic).map((name) => `"${name}"`).join(", ");
	return `${body}\n\n(Keywright guide, topic "${topic}"${section !== undefined ? `, one section` : ""}. Its sections: ${sections.map((entry) => entry.title).join("; ")}. The other topics: ${others}.)\n`;
}

/** The guide's essentials: the short list at the top of the workflow, for every agent to see. */
export function guideEssentials(): string {
	const found = sectionsOf(topicText("workflow")).find((entry) => entry.title === "In short");
	return found ? found.text.replace(/^## In short\s*/, "").trim() : "";
}
