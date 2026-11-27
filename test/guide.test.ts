import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { guideEssentials, guideSections, guideText, TOPICS, type Topic } from "../src/guide.js";

const skill = (file: string) => readFileSync(new URL(`../../skills/keywright/${file}`, import.meta.url), "utf8");

test("the workflow is the skill without its header, its links given as get_guide topics", () => {
	const text = guideText("workflow");
	assert.match(text, /^# Animating with Keywright/);
	assert.equal(text.includes("name: keywright"), false, "no header for apps");
	assert.ok(text.includes('get_guide topic "rig"') && text.includes('get_guide topic "moves"'));
	assert.equal(/\]\(reference\//.test(text), false, "no links to files the agent can't open");
	assert.match(text, /The other topics: "rig", "moves", "review"/);
});

test("every topic is its skill file, word for word", () => {
	for (const topic of Object.keys(TOPICS) as Topic[]) {
		const text = guideText(topic);
		const body = skill(TOPICS[topic]).replace(/^---[\s\S]*?\n---\s*/, "").split("\n").find((line) => line.startsWith("- ") || line.startsWith("Times") || line.startsWith("Keywright") || line.startsWith("## ") || line.startsWith("An R15"));
		assert.ok(body && text.includes(body.replace(/\[reference\/(\w+)\.md\]\(reference\/\w+\.md\)/g, 'get_guide topic "$1"')), topic);
	}
});

test("a section comes alone, found by its heading or the start of it", () => {
	assert.ok(guideSections("moves").includes("Run cycle"));
	const run = guideText("moves", "RUN");
	assert.match(run, /^## Run cycle/);
	assert.equal(run.includes("## Idle"), false);
	assert.match(run, /Its sections: Strikes: punches and kicks; /, "with the others listed");
	assert.throws(() => guideText("moves", "Backflip"), /no section "Backflip"/);
});

test("the essentials are the short list at the top of the workflow", () => {
	const essentials = guideEssentials();
	assert.match(essentials, /^- Read `inspect_rig`/);
	assert.match(essentials, /close the Animation Editor/);
	assert.equal(essentials.includes("## "), false);
});
