import AppKit
import CoreGraphics
import Foundation

@main
struct AgentCursorTests {
    @MainActor
    static func main() {
        testMotionLifecycle()
        testOverlayLifecycle()
    }

    @MainActor
    private static func testMotionLifecycle() {
        let renderer = AgentCursorRenderer()
        renderer.setInitialPosition(CGPoint(x: 100, y: 100))

        expect(!renderer.isAnimating, "renderer should start idle")

        renderer.moveTo(point: CGPoint(x: 500, y: 400))
        expect(renderer.isAnimating, "renderer should become active when motion starts")

        var now: CFTimeInterval = 0
        for _ in 0..<12_000 where renderer.isAnimating {
            now += 1.0 / 120.0
            renderer.tick(now: now)
        }

        expect(!renderer.isAnimating, "renderer should become idle after motion settles")

        renderer.moveTo(point: CGPoint(x: 800, y: 600))
        renderer.tick(now: now + 1.0 / 120.0)
        let stoppedPosition = renderer.position

        renderer.cancelAnimation()
        expect(!renderer.isAnimating, "cancelled motion should become idle")

        renderer.tick(now: now + 1)
        expect(renderer.position == stoppedPosition, "idle ticks should not change the cancelled position")

        renderer.setInitialPosition(CGPoint(x: 100, y: 100))
        renderer.moveTo(point: CGPoint(x: 300, y: 300))
        for _ in 0..<12 {
            now += 1.0 / 120.0
            renderer.tick(now: now)
        }
        let latestTarget = CGPoint(x: 900, y: 700)
        renderer.moveTo(point: latestTarget)
        for _ in 0..<12_000 where renderer.isAnimating {
            now += 1.0 / 120.0
            renderer.tick(now: now)
        }

        let endpointOffset = CGFloat(cos(Double.pi / 4) * 16)
        let expectedPosition = CGPoint(
            x: latestTarget.x + endpointOffset,
            y: latestTarget.y + endpointOffset
        )
        expect(distance(renderer.position, expectedPosition) < 0.001, "latest target should supersede in-flight motion")

        renderer.moveTo(point: CGPoint(x: 200, y: 200), label: "click", pulse: true)
        expect(renderer.label == "click", "motion should carry its action label")
        var sawPulse = false
        for _ in 0..<12_000 where renderer.isAnimating {
            now += 1.0 / 120.0
            renderer.tick(now: now)
            if renderer.pulseProgress != nil { sawPulse = true }
        }
        expect(sawPulse, "a pulsing motion should show the click ripple on arrival")
        expect(!renderer.isAnimating && renderer.pulseProgress == nil, "renderer should become idle after the ripple ends")
        expect(renderer.pulseCenter == CGPoint(x: 200, y: 200), "the ripple should center on the grounded point")

        renderer.moveTo(point: CGPoint(x: 400, y: 400), label: "type")
        for _ in 0..<12_000 where renderer.isAnimating {
            now += 1.0 / 120.0
            renderer.tick(now: now)
            expect(renderer.pulseProgress == nil, "non-click motion should not ripple")
        }
    }

    @MainActor
    private static func testOverlayLifecycle() {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let scheduler = ManualIdleHideScheduler()
        let cursor = AgentCursor(scheduleIdleHide: scheduler.schedule)

        cursor.animate(to: CGPoint(x: 300, y: 300), above: 0)
        guard let firstWindow = application.windows.first(where: {
            !existingWindows.contains(ObjectIdentifier($0)) && $0.isVisible
        }) else {
            fail("first action should create a visible overlay")
        }

        cursor.animate(to: CGPoint(x: 500, y: 500), above: 0)
        expect(scheduler.count == 2, "each action should replace the idle timeout")

        scheduler.fire(0)
        expect(firstWindow.isVisible, "a stale timeout should not hide the current overlay")
        expect(firstWindow.contentView != nil, "a stale timeout should not release the current view")

        scheduler.fire(1)
        expect(!AgentCursorRenderer.shared.isAnimating, "the current timeout should stop rendering")
        expect(!firstWindow.isVisible, "the current timeout should hide the overlay")
        expect(firstWindow.contentView == nil, "the current timeout should release the view tree")

        cursor.animate(to: CGPoint(x: 700, y: 700), above: 0)
        guard let recreatedWindow = application.windows.first(where: {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 !== firstWindow && $0.isVisible
        }) else {
            fail("a later action should recreate the overlay")
        }

        scheduler.fire(2)
        expect(!recreatedWindow.isVisible, "the recreated overlay should retain the idle lifecycle")
        expect(recreatedWindow.contentView == nil, "the recreated overlay should release its view tree")

        cursor.setHeld(true)
        cursor.animate(to: CGPoint(x: 400, y: 400), above: 0)
        guard let heldWindow = application.windows.first(where: {
            !existingWindows.contains(ObjectIdentifier($0)) && $0 !== firstWindow && $0 !== recreatedWindow && $0.isVisible
        }) else {
            fail("an action during a held run should show the overlay")
        }
        expect(scheduler.count == 3, "a held cursor should not schedule an idle hide")

        cursor.setHeld(false)
        expect(scheduler.count == 4 && scheduler.delays[3] == AgentCursor.releaseHideDelay, "releasing the hold should schedule the short hide")
        cursor.setHeld(true)
        scheduler.fire(3)
        expect(heldWindow.isVisible, "a release superseded by a new hold should not hide the overlay")

        cursor.setHeld(false)
        scheduler.fire(4)
        expect(!heldWindow.isVisible, "the run's end should hide the overlay")
        expect(heldWindow.contentView == nil, "the run's end should release the view tree")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

@MainActor
private final class ManualIdleHideScheduler {
    private var actions: [@MainActor () -> Void] = []

    var count: Int { actions.count }

    private(set) var delays: [Duration] = []

    func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        delays.append(delay)
        actions.append(action)
        return Task {}
    }

    func fire(_ index: Int) {
        actions[index]()
    }
}
