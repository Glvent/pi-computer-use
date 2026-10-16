import assert from "node:assert/strict";
import { applyOutputEnvelope, boundToolError, clearStoredOutputs, MODEL_TEXT_MAX_BYTES, readStoredOutput } from "../src/output.ts";
import { controlLine, renderInteractiveControls, searchOutlineRanked, serializeOutlineSearchMatch } from "../src/outline.ts";

clearStoredOutputs();
const oversized = "🙂".repeat(30_000);
const bounded = applyOutputEnvelope("evaluate_browser", { content: [{ type: "text", text: oversized }], details: {} });
const visible = bounded.content[0].text;
assert.ok(Buffer.byteLength(visible, "utf8") <= MODEL_TEXT_MAX_BYTES, "model-facing text exceeds the hard ceiling");
const ref = visible.match(/"(@o\d+)"/)?.[1];
const offset = Number(visible.match(/offset: (\d+)/)?.[1]);
assert.ok(ref && Number.isFinite(offset), "truncated output must provide a continuation");
const page = readStoredOutput(ref, offset);
assert.ok(page?.text.length, "continuation page must exist");
assert.equal(readStoredOutput(ref, offset)?.text, page.text, "continuation pages must be immutable");
assert.doesNotThrow(() => new TextEncoder().encode(page.text), "continuation must preserve utf-8");
const unaligned = readStoredOutput(ref, offset + 1);
assert.ok(unaligned && !unaligned.text.startsWith("�"), "arbitrary offsets must align to utf-8 boundaries");
const lineBounded = applyOutputEnvelope("observe_ui", { content: [{ type: "text", text: "x\n".repeat(3_000) }], details: {} });
assert.ok(lineBounded.content[0].text.split("\n").length <= 2_000, "model-facing text exceeds the line ceiling");
const boundedError = boundToolError("evaluate_browser", new Error("x".repeat(100_000)));
assert.ok(Buffer.byteLength(boundedError.message, "utf8") <= MODEL_TEXT_MAX_BYTES, "tool errors must obey the text ceiling");

const node = (ref, title, role = "AXButton") => ({ ref, role, subrole: "", identifier: "", title, description: "", value: "", actions: ["AXPress"], canPress: true, canFocus: false, canSetValue: false, canScroll: false, canIncrement: false, canDecrement: false, isTextInput: false, focused: false, offscreen: false, pictureOnly: false, truncated: false, text: [], children: [] });
const root = node("@e1", "root", "AXWindow");
root.children = [node("@e2", "Save"), node("@e3", "Save changes"), node("@e4", "Autosave"), node("@e5", "Svae")];
for (const child of root.children) child.parent = root;
const outline = { lookId: "look", root, nodes: [root, ...root.children], refToWireRef: new Map(), wireRefToRef: new Map() };
const ranked = searchOutlineRanked(outline, "save", "button", "press", 12);
assert.deepEqual(ranked.matches.map((match) => match.matchReason), ["exact", "prefix", "substring", "fuzzy"]);
assert.equal(ranked.totalMatches, 4);
const serializedMatch = serializeOutlineSearchMatch(ranked.matches[0]);
assert.equal("node" in serializedMatch, false, "agent-facing matches must not expose cyclic outline nodes");
assert.doesNotThrow(
	() => JSON.stringify({ tool: "wait_for", target: serializedMatch }),
	"successful wait_for details must be session-serializable",
);

const passive = (ref, role, fields = {}) => ({ ...node(ref, "", role), actions: [], canPress: false, ...fields });
const tree = (parent, children) => {
	parent.children = children;
	for (const child of children) child.parent = parent;
	return parent;
};
const field = passive("@e9", "AXTextField", { title: "Name", value: "Ada", canSetValue: true, isTextInput: true, focused: true });
const controlsRoot = tree(passive("@e1", "AXWindow", { title: "Doc" }), [
	tree(passive("@e2", "AXGroup", { actions: ["AXShowMenu"] }), [
		passive("@e3", "AXStaticText", { title: "Hello" }),
		node("@e4", ""),
		tree(node("@e5", "Save"), [node("@e6", "Save")]),
	]),
	passive("@e7", "AXHelpTag", { title: "tip" }),
	{ ...node("@e8", "Logo", "AXImage"), pictureOnly: true },
	field,
	node("@e10", "Line1\nLine2"),
	tree(passive("@e11", "AXSheet"), [node("@e12", "OK")]),
]);
const controlsNodes = [];
const collect = (current) => {
	controlsNodes.push(current);
	for (const child of current.children) collect(child);
};
collect(controlsRoot);
const controlsOutline = { lookId: "look", root: controlsRoot, nodes: controlsNodes, refToWireRef: new Map(), wireRefToRef: new Map() };
const controls = renderInteractiveControls(controlsOutline);
assert.deepEqual(controls.renderedRefs, ["@e9", "@e12", "@e5", "@e10"], "compact view must list sheet/focused controls first and drop containers, tooltips, text, pictureOnly, unlabeled and duplicate controls");
assert.equal(controls.omittedUnlabeled, 1);
assert.equal(controls.controlCount, 4);
assert.equal(controls.nodeCount, 12);
assert.equal(controls.truncated, false);
assert.equal(controls.text.split("\n").length, 4, "multi-line labels must stay on one line");
assert.equal(controlLine(field), '@e9 textfield "Name" = "Ada" [focused]');
assert.equal(controlLine({ ...field, title: "" }), '@e9 textfield "Ada" [focused]', "a value used as the label must not repeat");
for (const line of controls.text.split("\n")) {
	const [ref, role] = line.split(" ");
	assert.ok(searchOutlineRanked(controlsOutline, undefined, role).matches.some((match) => match.ref === ref), `role ${role} must work as a search_ui filter`);
}
const cappedControls = renderInteractiveControls(controlsOutline, 2);
assert.equal(cappedControls.truncated, true);
assert.deepEqual(cappedControls.renderedRefs, ["@e9", "@e12"]);
assert.match(cappedControls.text.split("\n").at(-1), /2 more controls not shown/);
clearStoredOutputs();

console.log("Bounded output, ranked search, and compact controls checks passed.");
