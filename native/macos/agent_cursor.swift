import AppKit
import SwiftUI

/// Visual-only cursor; native action delivery remains authoritative.
@MainActor
final class AgentCursor {
    typealias IdleHideScheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> Task<Void, Never>

    static let idleHideDelay: Duration = .seconds(8)
    static let releaseHideDelay: Duration = .milliseconds(1500)

    static let shared = AgentCursor(scheduleIdleHide: scheduleDefaultIdleHide)

    private var overlay: AgentCursorOverlayWindow?
    /// Global (top-left origin) frame of the display the cursor was last drawn on.
    private var displayFrame: CGRect?
    private var idleHideTask: Task<Void, Never>?
    private var idleGeneration: UInt = 0
    private let scheduleIdleHide: IdleHideScheduler
    /// While held, the cursor stays parked after its last action instead of hiding on idle.
    private(set) var isHeld = false

    init(scheduleIdleHide: @escaping IdleHideScheduler) {
        self.scheduleIdleHide = scheduleIdleHide
    }

    /// `point` is in global display coordinates with a top-left origin, as used by CGEvent and AX.
    func animate(to point: CGPoint, above windowId: UInt32, label: String? = nil, pulse: Bool = false) {
        idleHideTask?.cancel()
        idleHideTask = nil
        idleGeneration &+= 1

        let renderer = AgentCursorRenderer.shared
        let display = Self.display(containing: point)
        if display.global != displayFrame {
            // The renderer draws in display-local coordinates; restart its path on a new display.
            displayFrame = display.global
            renderer.setInitialPosition(CGPoint(x: -200, y: -200))
        }

        let window = ensureWindow(frame: display.appKit)
        if window.frame != display.appKit { window.setFrame(display.appKit, display: true) }
        if !window.isVisible { window.orderFrontRegardless() }
        window.order(.above, relativeTo: Int(windowId))

        let local = CGPoint(x: point.x - display.global.minX, y: point.y - display.global.minY)
        if renderer.position.x < -100 {
            renderer.setInitialPosition(CGPoint(
                x: min(max(local.x - 140, 2), display.global.width - 2),
                y: min(max(local.y - 140, 2), display.global.height - 2)
            ))
        }
        renderer.moveTo(point: local, label: label, pulse: pulse)

        if !isHeld { scheduleHide(after: Self.idleHideDelay) }
    }

    /// Holds the cursor on screen for an agent run; releasing it hides the cursor shortly after.
    func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        if held {
            idleHideTask?.cancel()
            idleHideTask = nil
            idleGeneration &+= 1
        } else if overlay != nil {
            scheduleHide(after: Self.releaseHideDelay)
        }
    }

    private func scheduleHide(after delay: Duration) {
        idleHideTask?.cancel()
        idleGeneration &+= 1
        let generation = idleGeneration
        idleHideTask = scheduleIdleHide(delay) { [weak self] in
            guard let self, let window = overlay else { return }
            guard generation == idleGeneration, !isHeld else { return }

            AgentCursorRenderer.shared.cancelAnimation()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            overlay = nil
            idleHideTask = nil
        }
    }

    private static func scheduleDefaultIdleHide(_ delay: Duration, _ hide: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    /// The display containing `point`, as both its global top-left frame and its AppKit frame.
    private static func display(containing point: CGPoint) -> (global: CGRect, appKit: NSRect) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let displays = NSScreen.screens.map { screen in
            let frame = screen.frame
            return (global: CGRect(x: frame.minX, y: primaryMaxY - frame.maxY, width: frame.width, height: frame.height), appKit: frame)
        }
        return displays.first { $0.global.contains(point) } ?? displays.first ?? (global: .zero, appKit: .zero)
    }

    private func ensureWindow(frame: NSRect) -> AgentCursorOverlayWindow {
        if let overlay { return overlay }
        let window = AgentCursorOverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: AgentCursorView())
        overlay = window
        return window
    }
}

/// Tracks which helper clients are in an active agent run; the cursor is held while any is.
final class AgentCursorHoldController {
    private let stateLock = NSLock()
    private var activeClients = Set<UUID>()

    func setActive(_ active: Bool, for clientID: UUID) {
        stateLock.lock()
        if active {
            activeClients.insert(clientID)
        } else {
            activeClients.remove(clientID)
        }
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let held = isHeld
            MainActor.assumeIsolated { AgentCursor.shared.setHeld(held) }
        }
    }

    func disconnect(_ clientID: UUID) {
        setActive(false, for: clientID)
    }

    var isHeld: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !activeClients.isEmpty
    }
}

/// Single-display, click-through overlay that can never take focus; it moves to the target's display.
private final class AgentCursorOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }
}

@MainActor
private struct AgentCursorView: View {
    @Bindable private var renderer = AgentCursorRenderer.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !renderer.isAnimating)) { context in
            Canvas { graphics, _ in
                renderer.tick(now: context.date.timeIntervalSinceReferenceDate)
                drawCursor(in: graphics)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private func drawCursor(in graphics: GraphicsContext) {
        let point = renderer.position
        guard point.x > -100 else { return }

        let bloom = Color(nsColor: NSColor(red: 1, green: 0x78 / 255, blue: 0x18 / 255, alpha: 1))
        if let progress = renderer.pulseProgress {
            let eased = 1 - pow(1 - progress, 3)
            let center = renderer.pulseCenter
            let ring = 6 + 26 * eased
            let ringRect = CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)
            graphics.fill(Path(ellipseIn: ringRect), with: .color(bloom.opacity(0.18 * (1 - progress))))
            graphics.stroke(Path(ellipseIn: ringRect), with: .color(bloom.opacity(0.9 * (1 - progress))), lineWidth: 0.5 + 2.5 * (1 - progress))
        }

        let radius: CGFloat = 22
        graphics.fill(
            Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [bloom.opacity(0.55), bloom.opacity(0.15), bloom.opacity(0)]),
                center: point,
                startRadius: 0,
                endRadius: radius
            )
        )

        let points = [
            CGPoint(x: 14, y: 0),
            CGPoint(x: -8, y: -9),
            CGPoint(x: -3, y: 0),
            CGPoint(x: -8, y: 9),
        ]
        var shape = Path()
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let entry = CGPoint(x: current.x + (previous.x - current.x) * 0.16, y: current.y + (previous.y - current.y) * 0.16)
            let exit = CGPoint(x: current.x + (next.x - current.x) * 0.16, y: current.y + (next.y - current.y) * 0.16)
            if index == points.startIndex { shape.move(to: entry) } else { shape.addLine(to: entry) }
            shape.addQuadCurve(to: exit, control: current)
        }
        shape.closeSubpath()

        let transformed = shape.applying(
            CGAffineTransform(translationX: point.x, y: point.y)
                .rotated(by: CGFloat(renderer.heading + .pi))
        )
        graphics.fill(
            transformed,
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 1, green: 0xD0 / 255, blue: 0x76 / 255),
                    Color(red: 1, green: 0x78 / 255, blue: 0x18 / 255),
                    Color(red: 0xE8 / 255, green: 0x4A / 255, blue: 0x0C / 255),
                ]),
                startPoint: CGPoint(x: point.x + 14, y: point.y - 9),
                endPoint: CGPoint(x: point.x - 8, y: point.y + 9)
            )
        )
        graphics.stroke(transformed, with: .color(.white), lineWidth: 2)

        if let label = renderer.label {
            let text = graphics.resolve(Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.white))
            let size = text.measure(in: CGSize(width: 240, height: 40))
            let pill = CGRect(x: point.x + 14, y: point.y + 12, width: size.width + 14, height: size.height + 6)
            let pillColor = Color(red: 0xE8 / 255, green: 0x4A / 255, blue: 0x0C / 255)
            graphics.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(pillColor.opacity(0.92)))
            graphics.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.white.opacity(0.85)), lineWidth: 1)
            graphics.draw(text, in: pill.insetBy(dx: 7, dy: 3))
        }
    }
}
