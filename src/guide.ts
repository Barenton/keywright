// The Keywright skill, served through Keywright itself: the animator's guide in
// skills/keywright, by topic, for any AI app connected to Keywright. An app that can't
// fetch or install skills still gets it, and it is always the version that matches the
// tools.
//
// The skill's files are the one source. The single-file release has them written into it
// when it is made, so a copy downloaded on its own has them too; from a checkout they are
// read from the skills folder.

import { readFileSync } from "node:fs";
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
 * A topic of the guide as an agent reads it through get_guide: the skill file without the
 * header that tells an app when to load it, with its links to the other files given as the
 * get_guide topics they are.
 */
export function guideText(topic: Topic): string {
	let text = skillFile(TOPICS[topic]);
	if (text.startsWith("---")) {
		const end = text.indexOf("\n---", 3);
		if (end !== -1) text = text.slice(end + 4).replace(/^\s+/, "");
	}
	text = text.replace(/\[reference\/(\w+)\.md\]\(reference\/\w+\.md\)/g, 'get_guide topic "$1"').replace(/\[([^\]]+)\]\(\.\.\/SKILL\.md\)/g, 'get_guide topic "workflow"');
	const others = (Object.keys(TOPICS) as Topic[]).filter((name) => name !== topic).map((name) => `"${name}"`).join(", ");
	return `${text.trimEnd()}\n\n(Keywright guide, topic "${topic}". The others: ${others}.)\n`;
}
