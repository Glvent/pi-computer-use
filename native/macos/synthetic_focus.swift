import AppKit
import ApplicationServices
import Foundation

/// Lets pid-targeted input reach a background window without changing the frontmost app.
///
/// AppKit and Chromium drop synthesized clicks (and Chromium keystrokes) for windows they
/// don't consider key. The target process is sent the WindowServer event records a real
/// activation produces: "application activated" and "make key window". Only the target
/// receives them, so the user's frontmost app keeps keyboard focus and physical input.
/// When the private SkyLight function is missing the controller reports itself unavailable
/// and delivery proceeds without it.
///
/// One helper serves every Pi session, so there is one focus target. An input lease spans
/// focusing and the caller's input: another connection's focus change or a release can't
/// land between them.
final class SyntheticFocusController {
	/// Release delay when no agent run is registered, e.g. a run whose registration failed.
	private static let unownedReleaseDelay: TimeInterval = 10

	private let inputLease = NSRecursiveLock()
	private let stateLock = NSLock()
	private var target: SyntheticFocusTarget?
	private var focusGeneration: UInt64 = 0
	private var activeClients = Set<UUID>()

	var isAvailable: Bool { SkyLight.canPostEventRecords }

	/// Focuses the target and takes the input lease; on success the caller must call
	/// `endInput()` after its input. Sent before every action rather than cached: the
	/// target's own activation state changes whenever the user activates and leaves it.
	func beginInput(pid: Int32, windowId: UInt32, frontmostPid: Int32?) throws {
		guard isAvailable else {
			throw BridgeFailure(message: "SkyLight event records are unavailable on this macOS version", code: "synthetic_focus_unavailable")
		}
		inputLease.lock()
		do {
			try focus(pid: pid, windowId: windowId, frontmostPid: frontmostPid)
		} catch {
			inputLease.unlock()
			throw error
		}
	}

	func endInput() {
		inputLease.unlock()
	}

	/// Tracks agent runs reported over persistent client connections; focus is released
	/// when the last run ends, so the target stops drawing as the key window. Closing a
	/// connection that never reported a run (every one-shot command does) releases nothing.
	func setRunActive(_ active: Bool, for clientID: UUID) {
		inputLease.lock()
		defer { inputLease.unlock() }
		stateLock.lock()
		defer { stateLock.unlock() }
		if active {
			activeClients.insert(clientID)
		} else if activeClients.remove(clientID) != nil && activeClients.isEmpty {
			releaseLocked()
		}
	}

	private func focus(pid: Int32, windowId: UInt32, frontmostPid: Int32?) throws {
		stateLock.lock()
		defer { stateLock.unlock() }
		if let previous = target, previous.pid != pid, syntheticFocusShouldDeactivate(target: previous, frontmostPid: frontmostPid) {
			try? SkyLight.post(syntheticDeactivationRecord(windowId: previous.windowId), to: previous.pid)
		}
		for record in syntheticFocusRecords(windowId: windowId) {
			try SkyLight.post(record, to: pid)
		}
		target = SyntheticFocusTarget(pid: pid, windowId: windowId)
		focusGeneration &+= 1
		if activeClients.isEmpty {
			let generation = focusGeneration
			DispatchQueue.global().asyncAfter(deadline: .now() + Self.unownedReleaseDelay) { [weak self] in
				self?.releaseIfUnowned(generation: generation)
			}
		}
	}

	private func releaseIfUnowned(generation: UInt64) {
		inputLease.lock()
		defer { inputLease.unlock() }
		stateLock.lock()
		defer { stateLock.unlock() }
		guard generation == focusGeneration, activeClients.isEmpty else { return }
		releaseLocked()
	}

	/// Caller holds both locks.
	private func releaseLocked() {
		guard let previous = target else { return }
		target = nil
		// The user may have brought the target forward since; deactivating it then would
		// take keyboard focus away from them.
		guard syntheticFocusShouldDeactivate(target: previous, frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier) else { return }
		try? SkyLight.post(syntheticDeactivationRecord(windowId: previous.windowId), to: previous.pid)
	}
}

/// Private SkyLight and HIServices functions, resolved at runtime so a macOS release that
/// drops one disables the feature instead of preventing the helper from loading.
enum SkyLight {
	private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
	private typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
	private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

	/// kCPSUserGenerated: the switch is treated like one the user made.
	private static let userGenerated: UInt32 = 0x200
	private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
	private static let postEventRecordTo = handle.flatMap { dlsym($0, "SLPSPostEventRecordTo") }.map { unsafeBitCast($0, to: PostEventRecordTo.self) }
	private static let setFrontProcessWithOptions = handle.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }.map { unsafeBitCast($0, to: SetFrontProcessWithOptions.self) }
	// RTLD_DEFAULT: GetProcessForPID lives in HIServices, already linked through ApplicationServices.
	private static let getProcessForPID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map { unsafeBitCast($0, to: GetProcessForPID.self) }

	static var canPostEventRecords: Bool { postEventRecordTo != nil && getProcessForPID != nil }
	static var canSetFrontProcess: Bool { setFrontProcessWithOptions != nil && canPostEventRecords }

	static func post(_ record: [UInt8], to pid: Int32) throws {
		guard let postEventRecordTo else {
			throw BridgeFailure(message: "SLPSPostEventRecordTo is unavailable on this macOS version", code: "synthetic_focus_unavailable")
		}
		var psn = try processSerialNumber(pid)
		var bytes = record
		let status = bytes.withUnsafeMutableBufferPointer { postEventRecordTo(&psn, $0.baseAddress!) }
		guard status == .success else {
			throw BridgeFailure(message: "SLPSPostEventRecordTo failed with \(status.rawValue)", code: "synthetic_focus_failed")
		}
	}

	/// Brings the app forward with the given window key, without the cooperative-activation
	/// consent `NSRunningApplication.activate()` needs from the app that is currently active.
	static func setFrontProcess(pid: Int32, windowId: UInt32) throws {
		guard let setFrontProcessWithOptions else {
			throw BridgeFailure(message: "_SLPSSetFrontProcessWithOptions is unavailable on this macOS version", code: "focus_restore_unavailable")
		}
		var psn = try processSerialNumber(pid)
		let status = setFrontProcessWithOptions(&psn, windowId, userGenerated)
		guard status == .success else {
			throw BridgeFailure(message: "_SLPSSetFrontProcessWithOptions failed with \(status.rawValue)", code: "focus_restore_failed")
		}
		if windowId > 0 {
			for record in keyWindowRecords(windowId: windowId) { try post(record, to: pid) }
		}
	}

	private static func processSerialNumber(_ pid: Int32) throws -> ProcessSerialNumber {
		var psn = ProcessSerialNumber()
		guard let getProcessForPID, getProcessForPID(pid, &psn) == noErr else {
			throw BridgeFailure(message: "No process serial number for pid \(pid)", code: "app_not_found")
		}
		return psn
	}
}
