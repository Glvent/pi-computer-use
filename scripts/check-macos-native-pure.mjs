#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

if (process.platform !== "darwin") {
	console.log("macos native pure checks skipped (not macOS)");
	process.exit(0);
}
const source = readFileSync(new URL("../native/macos/bridge.swift", import.meta.url), "utf8");
const match = source.match(/\/\/ BEGIN PURE[^\n]*\n([\s\S]*?)\/\/ END PURE/);
if (!match) throw new Error("PURE region not found in bridge.swift");

const main = `
import Foundation
import CoreGraphics
var failures = 0
func check(_ ok: Bool, _ name: String) { if !ok { failures += 1; print("FAIL: \\(name)") } }

check(!classifyModal(axModal: false, sheetCount: 0, role: "AXWindow", subrole: "AXDialog"), "AXModal=0 + AXDialog is nonmodal (Fusion sidebar)")
check(classifyModal(axModal: true, sheetCount: 0, role: "AXWindow", subrole: "AXStandardWindow"), "AXModal=1 is modal")
check(classifyModal(axModal: true, sheetCount: 0, role: "AXWindow", subrole: "AXDialog"), "AXModal=1 + AXDialog is modal")
check(classifyModal(axModal: false, sheetCount: 1, role: "AXWindow", subrole: "AXStandardWindow"), "sheet child is modal")
check(classifyModal(axModal: nil, sheetCount: 0, role: "AXSheet", subrole: ""), "AXSheet is modal")
check(classifyModal(axModal: nil, sheetCount: 0, role: "AXWindow", subrole: "AXDialog"), "unreported AXModal + AXDialog falls back to modal")
check(!classifyModal(axModal: nil, sheetCount: 0, role: "AXWindow", subrole: "AXStandardWindow"), "plain window nonmodal")
check(!classifyModal(axModal: false, sheetCount: 0, role: "AXWindow", subrole: "AXSystemDialog"), "explicit AXModal=0 wins over any dialog subrole")

check(resolveCaptureTarget(windowId: 12, wantsImage: true) == .capture(windowId: 12), "paired + image captures")
check(resolveCaptureTarget(windowId: 12, wantsImage: false) == .semanticOnly, "paired semantic skips capture")
check(resolveCaptureTarget(windowId: nil, wantsImage: false) == .semanticOnly, "unpaired semantic ok")
check(resolveCaptureTarget(windowId: nil, wantsImage: true) == .notCapturable, "unpaired visual errors")
check(resolveCaptureTarget(windowId: 0, wantsImage: true) == .notCapturable, "window 0 never captured")

check(syntheticFocusDecision(delivery: "pid", policy: "background_only", targetPid: 10, windowId: 7, frontmostPid: 20) == .apply, "background pid input to another app gets synthetic focus")
check(syntheticFocusDecision(delivery: "pid", policy: "background", targetPid: 10, windowId: 7, frontmostPid: 20) == .apply, "default background attempt gets synthetic focus")
check(syntheticFocusDecision(delivery: "pid", policy: "background_only", targetPid: 10, windowId: 7, frontmostPid: 10) == .skip("target_is_frontmost"), "frontmost target keeps the user's key window")
check(syntheticFocusDecision(delivery: "hid", policy: "foreground", targetPid: 10, windowId: 7, frontmostPid: 20) == .skip("not_pid_delivery"), "foreground delivery needs no synthetic focus")
check(syntheticFocusDecision(delivery: "pid", policy: "ax_only", targetPid: 10, windowId: 7, frontmostPid: 20) == .skip("not_pid_delivery"), "strict headless never posts records")
check(syntheticFocusDecision(delivery: "pid", policy: "background_only", targetPid: 10, windowId: 0, frontmostPid: 20) == .skip("no_window"), "unpaired root has no window to make key")
check(syntheticFocusDecision(delivery: "pid", policy: "background_only", targetPid: 10, windowId: 7, frontmostPid: nil) == .skip("frontmost_unknown"), "unknown frontmost app is not risked")
check(syntheticFocusShouldDeactivate(target: SyntheticFocusTarget(pid: 10, windowId: 7), frontmostPid: 20), "background target is deactivated on release")
check(!syntheticFocusShouldDeactivate(target: SyntheticFocusTarget(pid: 10, windowId: 7), frontmostPid: 10), "target the user brought forward keeps its focus")

let records = syntheticFocusRecords(windowId: 0x01020304)
check(records.count == 3 && records.allSatisfy { $0.count == 0xf8 && $0[0x04] == 0xf8 && Array($0[0x3c..<0x40]) == [0x04, 0x03, 0x02, 0x01] }, "records carry size and little-endian window id")
check(records[0][0x08] == 0x0d && records[0][0x8a] == 0x01, "first record activates the application")
check(records[1][0x08] == 0x01 && records[2][0x08] == 0x02 && records[1][0x3a] == 0x10 && records[1][0x20..<0x30].allSatisfy { $0 == 0xff }, "key-window records post both phases")
check(keyWindowRecords(windowId: 0x01020304) == Array(records.dropFirst()), "focus restore reuses the key-window records without the activation record")
let release = syntheticDeactivationRecord(windowId: 7)
check(release[0x08] == 0x0d && release[0x8a] == 0x02 && release[0x3c] == 7, "release record deactivates the application")

let relative = windowRelativeEventLocation(screenPoint: CGPoint(x: 192, y: 355), windowOrigin: CGPoint(x: 22, y: 53), mainDisplayHeight: 884)
check(relative.x == 170 && relative.y == 582, "window event location flips against the main display so cgEvent yields (170, 302)")

let pipMax = CGSize(width: 360, height: 270)
check(pipPanelSize(windowSize: CGSize(width: 1440, height: 900), maxSize: pipMax) == CGSize(width: 360, height: 225), "wide window fits the max width")
check(pipPanelSize(windowSize: CGSize(width: 600, height: 1200), maxSize: pipMax) == CGSize(width: 135, height: 270), "tall window fits the max height")
check(pipPanelSize(windowSize: CGSize(width: 200, height: 100), maxSize: pipMax) == CGSize(width: 200, height: 100), "small window isn't scaled up")
check(pipPanelSize(windowSize: .zero, maxSize: pipMax) == pipMax, "empty window size falls back to the max size")
let pipScreen = CGRect(x: 0, y: 25, width: 1440, height: 850)
check(pipPanelFrame(size: CGSize(width: 360, height: 225), anchor: CGPoint(x: 1424, y: 41), visibleFrame: pipScreen) == CGRect(x: 1064, y: 41, width: 360, height: 225), "bottom-right corner stays at the anchor")
check(pipPanelFrame(size: CGSize(width: 360, height: 225), anchor: CGPoint(x: 100, y: 800), visibleFrame: pipScreen) == CGRect(x: 0, y: 650, width: 360, height: 225), "panel is clamped inside the visible frame")
check(pipShouldShow(runActive: true, targetPid: 10, frontmostPid: 20), "background target shows the PIP")
check(!pipShouldShow(runActive: true, targetPid: 10, frontmostPid: 10), "frontmost target is already in view")
check(!pipShouldShow(runActive: false, targetPid: 10, frontmostPid: 20) && !pipShouldShow(runActive: true, targetPid: nil, frontmostPid: 20), "no run or no target hides the PIP")
check(pipCardMaxSize(saved: CGSize(width: 360, height: 270), visibleSize: CGSize(width: 1440, height: 875)) == CGSize(width: 360, height: 270), "saved size that fits is kept")
check(pipCardMaxSize(saved: CGSize(width: 2400, height: 1500), visibleSize: CGSize(width: 1440, height: 875)) == CGSize(width: 1296, height: 787.5), "size saved on a large display fits a smaller one")
let resizeCard = CGRect(x: 100, y: 100, width: 320, height: 200)
check(pipResizeEdges(at: CGPoint(x: 421, y: 200), card: resizeCard, band: 8, corner: 18) == [.right], "right edge band")
check(pipResizeEdges(at: CGPoint(x: 95, y: 95), card: resizeCard, band: 8, corner: 18) == [.left, .bottom], "bottom-left corner")
check(pipResizeEdges(at: CGPoint(x: 410, y: 296), card: resizeCard, band: 8, corner: 18) == [.right, .top], "corner zone is wider than the edge band")
check(pipResizeEdges(at: CGPoint(x: 260, y: 200), card: resizeCard, band: 8, corner: 18).isEmpty && pipResizeEdges(at: CGPoint(x: 60, y: 200), card: resizeCard, band: 8, corner: 18).isEmpty, "card interior and far margin don't resize")
let resizeMax = CGSize(width: 1000, height: 1000)
check(pipResizedCardFrame(start: resizeCard, delta: CGVector(dx: 80, dy: 0), edges: .right, minWidth: 160, maxSize: resizeMax) == CGRect(x: 100, y: 100, width: 400, height: 250), "right edge grows with the aspect ratio")
check(pipResizedCardFrame(start: resizeCard, delta: CGVector(dx: -80, dy: 0), edges: [.left, .bottom], minWidth: 160, maxSize: resizeMax) == CGRect(x: 20, y: 50, width: 400, height: 250), "bottom-left corner keeps the top-right corner fixed")
check(pipResizedCardFrame(start: resizeCard, delta: CGVector(dx: 0, dy: 50), edges: .top, minWidth: 160, maxSize: resizeMax) == CGRect(x: 100, y: 100, width: 400, height: 250), "top edge resizes by height")
check(pipResizedCardFrame(start: resizeCard, delta: CGVector(dx: -500, dy: 0), edges: .right, minWidth: 160, maxSize: resizeMax).width == 160, "minimum width")
check(pipResizedCardFrame(start: resizeCard, delta: CGVector(dx: 5000, dy: 0), edges: .right, minWidth: 160, maxSize: CGSize(width: 2000, height: 500)) == CGRect(x: 100, y: 100, width: 800, height: 500), "maximum size holds the aspect ratio")
let glowSamples = stride(from: 0.0, through: 48.0, by: 0.5).map { pipGlowIntensity(distance: $0, padding: 48) }
check(zip(glowSamples, glowSamples.dropFirst()).allSatisfy { $0 > $1 || ($0 == 0 && $1 == 0) }, "glow falls off monotonically")
check(glowSamples[0] > 0.9 && glowSamples[0] <= 1, "glow is brightest at the card edge")
check(pipGlowIntensity(distance: 24, padding: 48) > 0.1, "glow haze still carries halfway across the margin")
check(pipGlowIntensity(distance: 47.5, padding: 48) < 0.002 && pipGlowIntensity(distance: 48, padding: 48) == 0, "glow reaches 0 before the window edge")
check(pipGlowIntensity(distance: -3, padding: 48) == pipGlowIntensity(distance: 0, padding: 48), "glow under the card matches the edge")
let glowCard = CGRect(x: 0, y: 0, width: 100, height: 60)
check(pipRoundedRectDistance(point: CGPoint(x: 50, y: 30), rect: glowCard, radius: 12) == -30, "card center is inside")
check(pipRoundedRectDistance(point: CGPoint(x: 110, y: 30), rect: glowCard, radius: 12) == 10, "side distance is straight")
check(abs(pipRoundedRectDistance(point: CGPoint(x: -10, y: -10), rect: glowCard, radius: 12) - (hypot(22, 22) - 12)) < 1e-9, "corner distance follows the rounding")

let emojiRange = textSelectionRange(in: "👋 hi there", matching: "there")
check(emojiRange?.location == 6 && emojiRange?.length == 5, "selection ranges count UTF-16 units like AXSelectedTextRange")
check(textSelectionRange(in: "abc", matching: "x") == nil && textSelectionRange(in: "abc", matching: "") == nil, "missing or empty text selects nothing")
check(screenIsLocked(session: ["CGSSessionScreenIsLocked": true]), "locked session is detected")
check(!screenIsLocked(session: ["kCGSSessionOnConsoleKey": true]), "unlocked session omits the lock key")
check(!screenIsLocked(session: nil), "missing session dictionary isn't treated as locked")
check(["look", "act", "actBatch", "axReadText"].allSatisfy(commandsRequiringUnlockedScreen.contains) && !commandsRequiringUnlockedScreen.contains("diagnostics") && !commandsRequiringUnlockedScreen.contains("setActivityGlow"), "UI commands need an unlocked screen; lifecycle commands don't")

let armed = FocusGuardArm(targetPid: 10, userPid: 20, userWindowId: 5, armedAt: 100, until: nil)
var tailing = armed
tailing.until = 102
check(focusStealVerdict(arm: armed, frontmostPid: 10, now: 101, lastUserMouseDownAt: 90, lastUserModifierChangeAt: 99) == .restore, "target activating mid-action is sent back")
check(focusStealVerdict(arm: tailing, frontmostPid: 10, now: 101.5, lastUserMouseDownAt: nil, lastUserModifierChangeAt: nil) == .restore, "target activating just after the action is sent back")
check(focusStealVerdict(arm: tailing, frontmostPid: 10, now: 102.5, lastUserMouseDownAt: nil, lastUserModifierChangeAt: nil) == .ignore("expired"), "activation after the tail is left alone")
check(focusStealVerdict(arm: armed, frontmostPid: 10, now: 101, lastUserMouseDownAt: 100.5, lastUserModifierChangeAt: nil) == .ignore("user_input"), "a click since arming means the user switched")
check(focusStealVerdict(arm: armed, frontmostPid: 10, now: 101, lastUserMouseDownAt: nil, lastUserModifierChangeAt: 100.7) == .ignore("user_input"), "Cmd-Tab to the target is the user's switch")
check(focusStealVerdict(arm: armed, frontmostPid: 30, now: 101, lastUserMouseDownAt: nil, lastUserModifierChangeAt: nil) == .ignore("other_app"), "only the driven target counts as a steal")
check(focusStealVerdict(arm: armed, frontmostPid: 20, now: 101, lastUserMouseDownAt: nil, lastUserModifierChangeAt: nil) == .ignore("user_app_front"), "user's app in front needs nothing")
check(focusStealVerdict(arm: armed, frontmostPid: nil, now: 101, lastUserMouseDownAt: nil, lastUserModifierChangeAt: nil) == .ignore("user_app_front"), "unknown frontmost app is not acted on")

if failures > 0 { exit(1) }
print("macos native pure checks passed")
`;
const dir = mkdtempSync(path.join(tmpdir(), "pcu-pure-"));
try {
	writeFileSync(path.join(dir, "main.swift"), match[1] + main);
	execFileSync("swiftc", ["-O", "-o", path.join(dir, "t"), path.join(dir, "main.swift")], { stdio: "inherit" });
	process.stdout.write(execFileSync(path.join(dir, "t"), { encoding: "utf8" }));
} finally {
	rmSync(dir, { recursive: true, force: true });
}
