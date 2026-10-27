import AppKit
import Foundation

/// Undoes focus steals by apps the agent drives in the background.
///
/// Background input can still make the target activate itself: a click that opens a window,
/// a keystroke that triggers `NSApp.activate`, or Chromium reacting to its synthetic focus.
/// While an action runs and for `tail` seconds after it, a target that comes to the front is
/// sent back behind the app the user had in front, unless the user switched to it. Each steal
/// is reported once, in the next root delta for that target.
final class FocusGuard {
	private static let tail: TimeInterval = 1.5
	/// Activation can be seen twice: by the notification and by the action's own poll.
	private static let restoreDebounce: TimeInterval = 0.3
	private static let maxPendingEvents = 8

	private let lock = NSLock()
	private var arms: [Int32: FocusGuardArm] = [:]
	private var inFlight: [Int32: Int] = [:]
	private var foregroundInFlight: [Int32: Int] = [:]
	private var lastRestoreAt: [Int32: TimeInterval] = [:]
	private var pending: [Int32: [[String: Any]]] = [:]
	private var observer: NSObjectProtocol?

	init() {
		// Delivered on the main run loop, which only runs in `serve` mode, the mode the
		// extension uses. In stdin mode only the action's own root-delta poll checks.
		observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] notification in
			let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
			_ = self?.check(frontmostPid: app?.processIdentifier)
		}
	}

	deinit {
		if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
	}

	/// Arms the guard for one background action. Nothing is armed when the target already
	/// is the frontmost app, since it can't steal what it has.
	func beginAction(targetPid: Int32) -> Bool {
		guard let user = NSWorkspace.shared.frontmostApplication, user.processIdentifier != targetPid else { return false }
		let now = Date().timeIntervalSinceReferenceDate
		lock.lock()
		defer { lock.unlock() }
		let overlapping = (inFlight[targetPid] ?? 0) > 0
		inFlight[targetPid, default: 0] += 1
		// Overlapping actions share the arm and its click baseline. A fresh action group
		// starts a new one, so a click between actions can't disable the guard for good.
		if !overlapping || arms[targetPid] == nil {
			arms[targetPid] = FocusGuardArm(targetPid: targetPid, userPid: user.processIdentifier, userWindowId: frontWindowId(pid: user.processIdentifier), armedAt: now, until: nil)
		}
		return true
	}

	func endAction(targetPid: Int32) {
		lock.lock()
		defer { lock.unlock() }
		let remaining = max(0, (inFlight[targetPid] ?? 1) - 1)
		inFlight[targetPid] = remaining == 0 ? nil : remaining
		if remaining == 0 { arms[targetPid]?.until = Date().timeIntervalSinceReferenceDate + Self.tail }
	}

	/// Deliberate foreground work on the target (escalation, `focusWindow`) must not be undone,
	/// including by another session's background action that overlaps it.
	func beginForeground(targetPid: Int32) {
		lock.lock()
		defer { lock.unlock() }
		foregroundInFlight[targetPid, default: 0] += 1
		arms[targetPid] = nil
	}

	/// The target is legitimately in front now; earlier background arms must not send it back.
	func endForeground(targetPid: Int32) {
		lock.lock()
		defer { lock.unlock() }
		let remaining = max(0, (foregroundInFlight[targetPid] ?? 1) - 1)
		foregroundInFlight[targetPid] = remaining == 0 ? nil : remaining
		arms[targetPid] = nil
	}

	/// Returns true when this call sent a stealing target back.
	func check(frontmostPid: Int32?) -> Bool {
		let now = Date().timeIntervalSinceReferenceDate
		let lastUserMouseDownAt = now - lastHardwareEventAge([.leftMouseDown, .rightMouseDown, .otherMouseDown])
		let lastUserModifierChangeAt = now - lastHardwareEventAge([.flagsChanged])
		lock.lock()
		defer { lock.unlock() }
		var restored = false
		for (targetPid, arm) in arms where foregroundInFlight[targetPid] == nil {
			switch focusStealVerdict(arm: arm, frontmostPid: frontmostPid, now: now, lastUserMouseDownAt: lastUserMouseDownAt, lastUserModifierChangeAt: lastUserModifierChangeAt) {
			case .ignore("expired"):
				arms[targetPid] = nil
			case .ignore:
				continue
			case .restore:
				if let last = lastRestoreAt[targetPid], now - last < Self.restoreDebounce { continue }
				lastRestoreAt[targetPid] = now
				restored = restore(arm) || restored
			}
		}
		return restored
	}

	func drainEvents(targetPid: Int32) -> [[String: Any]] {
		lock.lock()
		defer { lock.unlock() }
		return pending.removeValue(forKey: targetPid) ?? []
	}

	/// Caller holds `lock`.
	private func restore(_ arm: FocusGuardArm) -> Bool {
		let userApp = NSRunningApplication(processIdentifier: arm.userPid)
		var event: [String: Any] = [
			"change": "focusStolen",
			"kind": "app",
			"title": NSRunningApplication(processIdentifier: arm.targetPid)?.localizedName ?? "Unknown App",
			"pid": Int(arm.targetPid),
			"restoredTo": userApp?.localizedName ?? "Unknown App",
		]
		var restored = false
		if userApp == nil || userApp?.isTerminated == true {
			event["error"] = "app_not_found"
		} else {
			do {
				try SkyLight.setFrontProcess(pid: arm.userPid, windowId: arm.userWindowId)
				restored = true
			} catch let failure as BridgeFailure {
				// Works only when the stealing app yields activation, but costs nothing to try.
				restored = userApp?.activate() ?? false
				event["error"] = failure.code
			} catch {
				restored = userApp?.activate() ?? false
			}
		}
		event["restored"] = restored
		var events = pending[arm.targetPid] ?? []
		events.append(event)
		pending[arm.targetPid] = Array(events.suffix(Self.maxPendingEvents))
		return restored
	}

	/// Synthesized pid-targeted events don't reach the HID system state, so this is the user's input.
	private func lastHardwareEventAge(_ types: [CGEventType]) -> TimeInterval {
		types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
	}

	private func frontWindowId(pid: Int32) -> UInt32 {
		let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
		let front = windows.first {
			($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
		}
		return (front?[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
	}
}
