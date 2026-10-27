#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const project = mkdtempSync(path.join(os.tmpdir(), "pcu-config-"));
// Keep the user's global config out of the checks.
process.env.PI_CODING_AGENT_DIR = path.join(project, "agent");
for (const key of Object.keys(process.env)) if (key.startsWith("PI_COMPUTER_USE_")) delete process.env[key];

const { blockedAppEntry, loadComputerUseConfig } = await import("../src/config.ts");
const { testing } = await import("../src/bridge.ts");
const writeProjectConfig = (value) => {
	mkdirSync(path.join(project, ".pi"), { recursive: true });
	writeFileSync(path.join(project, ".pi", "computer-use.json"), JSON.stringify(value));
};

try {
	assert.ok(loadComputerUseConfig(project).sources[0].path.startsWith(project), "global config is isolated");
	assert.equal(blockedAppEntry("Terminal", "com.apple.Terminal"), "com.apple.Terminal", "terminals are blocked by default");
	assert.equal(blockedAppEntry("1Password", "COM.1PASSWORD.1PASSWORD"), "com.1password.1password", "matching ignores case");
	assert.equal(blockedAppEntry("Notes", "com.apple.Notes"), undefined, "ordinary apps stay controllable");
	assert.throws(() => testing.assertTargetAllowed({ appName: "Terminal", bundleId: "com.apple.Terminal" }), (error) => error.code === "app_blocked" && /blocked_apps entry 'com.apple.Terminal'/.test(error.message));
	testing.assertTargetAllowed({ appName: "Notes", bundleId: "com.apple.Notes" });

	writeProjectConfig({ blocked_apps: ["Notes"] });
	loadComputerUseConfig(project);
	assert.equal(blockedAppEntry("Notes", "com.apple.Notes"), "Notes", "app names match too");
	assert.equal(blockedAppEntry("Terminal", "com.apple.Terminal"), undefined, "a configured list replaces the defaults");
	assert.equal(blockedAppEntry("SecurityAgent", "com.apple.SecurityAgent"), "com.apple.SecurityAgent", "system security apps can't be unblocked");

	writeProjectConfig({ blocked_apps: [] });
	loadComputerUseConfig(project);
	assert.equal(blockedAppEntry("Terminal", "com.apple.Terminal"), undefined, "an empty list unblocks everything but system security apps");
	assert.equal(blockedAppEntry("loginwindow", "com.apple.loginwindow"), "com.apple.loginwindow");

	assert.equal(loadComputerUseConfig(project).config.pip_view, false, "the PIP view is off by default");
	writeProjectConfig({ pip_view: true });
	assert.equal(loadComputerUseConfig(project).config.pip_view, true, "pip_view can be enabled");

	writeProjectConfig({ blocked_apps: "Terminal" });
	const loaded = loadComputerUseConfig(project);
	assert.match(loaded.sources.at(-1).error ?? "", /blocked_apps must be an array/, "an invalid list is reported, not ignored");
	assert.equal(blockedAppEntry("Terminal", "com.apple.Terminal"), "com.apple.Terminal", "a rejected project file leaves the defaults in force");
} finally {
	rmSync(project, { recursive: true, force: true });
}

console.log("config checks passed");
