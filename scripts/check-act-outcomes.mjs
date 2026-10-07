#!/usr/bin/env node
// Post-action classification: replaced vs closed vs stale root, never silent success.
import assert from "node:assert/strict";

const { currentPlatformBackend } = await import("../src/platform/index.ts");
const { terminalDesktopActionResult: rawTerminal, testing } = await import("../src/bridge.ts");

const target = { appName: "App", pid: 7, windowTitle: "Open", windowId: 0, windowRef: "@r1", nativeWindowRef: "ax:dlg" };
const terminalDesktopActionResult = (...args) => testing.runInOperation(() => rawTerminal(...args));
const rootsAfter = (roots) => {
	currentPlatformBackend.listRoots = async () => roots;
};
const text = (result) => result.content[0].text;

// Dialog dismissed, main window remains and a new root appeared -> replaced, successor named.
rootsAfter([{ pid: 7, rootRef: "ax:main", windowRef: "ax:main", windowId: 5 }]);
let result = await terminalDesktopActionResult(target, "s1", {
	strategy: "act",
	rootDelta: [
		{ change: "closed", kind: "dialog", ref: "ax:dlg", pid: 7 },
		{ change: "appeared", kind: "dialog", ref: "ax:new", title: "Confirm", pid: 7, isModal: true },
	],
}, new Error("Root is not available through Accessibility"));
assert.equal(result.details.status, "target_closed");
assert.equal(result.details.cause, "replaced");
assert.equal(result.details.successors[0].ref, "ax:new");
assert.match(text(result), /delivered/);
assert.match(text(result), /replaced by dialog "Confirm" \(modal\)/);

// Closed with no successor -> closed.
rootsAfter([{ pid: 7, rootRef: "ax:main", windowRef: "ax:main", windowId: 5 }]);
result = await terminalDesktopActionResult(target, "s1", { strategy: "act", rootDelta: [] }, new Error("x"));
assert.equal(result.details.cause, "closed");
assert.deepEqual(result.details.successors, []);

// Root still listed but observation says root unavailable -> root_stale, not success.
rootsAfter([{ pid: 7, rootRef: "ax:dlg", windowRef: "ax:dlg" }]);
result = await terminalDesktopActionResult(target, "s1", { strategy: "act" }, new Error("Root is not available through Accessibility"));
assert.equal(result.details.status, "post_action_observation_failed");
assert.equal(result.details.error.code, "root_stale");
assert.match(result.details.error.message, /find_roots/);
assert.equal(result.details.cause, undefined);

// Unrelated observation failure keeps its own code.
rootsAfter([{ pid: 7, rootRef: "ax:dlg", windowRef: "ax:dlg" }]);
result = await terminalDesktopActionResult(target, "s1", { strategy: "act" }, new Error("boom"));
assert.equal(result.details.error.code, "post_action_observation_failed");

// A different pid's root with the same ref never counts as the target.
rootsAfter([{ pid: 99, rootRef: "ax:dlg", windowRef: "ax:dlg" }]);
result = await terminalDesktopActionResult(target, "s1", { strategy: "act" }, new Error("x"));
assert.equal(result.details.status, "target_closed");

console.log("act outcome checks passed");
