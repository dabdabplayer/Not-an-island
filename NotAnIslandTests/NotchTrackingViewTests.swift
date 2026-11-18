import AppKit
import Testing
@testable import NotAnIsland

@MainActor
struct NotchTrackingViewTests {
    private func enterExitEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }

    @Test func tracksPointerEvenWhileAppIsInactive() throws {
        let view = NotchTrackingView()
        let area = try #require(view.trackingAreas.first)

        #expect(area.owner === view)
        #expect(area.options.contains(.mouseEnteredAndExited))
        #expect(area.options.contains(.mouseMoved))
        #expect(area.options.contains(.activeAlways))
        #expect(area.options.contains(.inVisibleRect))
    }

    // AppKit delivers tracking events to the owner by these exact Objective-C selectors.
    @Test func forwardsAppKitEnterAndExitSelectors() throws {
        let view = NotchTrackingView()
        var events: [String] = []
        view.onPointerEntered = { events.append("entered") }
        view.onPointerExited = { _ in events.append("exited") }

        let entered = #selector(NSResponder.mouseEntered(with:))
        let exited = #selector(NSResponder.mouseExited(with:))
        #expect(NSStringFromSelector(entered) == "mouseEntered:")
        #expect(NSStringFromSelector(exited) == "mouseExited:")

        view.perform(entered, with: try enterExitEvent(.mouseEntered))
        view.perform(exited, with: try enterExitEvent(.mouseExited))

        #expect(events == ["entered", "exited"])
    }
}

@MainActor
struct NotchTrackingViewSpeedTests {
    private func event(_ type: NSEvent.EventType, x: Double, time: TimeInterval) throws -> NSEvent {
        if type == .mouseMoved {
            return try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: x, y: 0), modifierFlags: [], timestamp: time,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ))
        }
        return try #require(NSEvent.enterExitEvent(
            with: type, location: CGPoint(x: x, y: 0), modifierFlags: [], timestamp: time,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
    }

    @Test func reportsExitSpeedFromMovementInsideTheNotch() throws {
        let view = NotchTrackingView()
        var reported: Double?? = .none
        view.onPointerExited = { reported = .some($0) }

        view.mouseEntered(with: try event(.mouseEntered, x: 0, time: 10))
        view.mouseMoved(with: try event(.mouseMoved, x: 10, time: 10.01))
        view.mouseMoved(with: try event(.mouseMoved, x: 20, time: 10.02))
        view.mouseExited(with: try event(.mouseExited, x: 30, time: 10.03))

        let exit = try #require(reported, "exit was not reported")
        let speed = try #require(exit, "exit speed was not measured")
        #expect(abs(speed - 1000) < 1)
    }
}
