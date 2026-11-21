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
        view.onPointerEntered = { _ in events.append("entered") }
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

// The panel stays large until a collapse finishes. Only the shape being animated to may expand the
// notch, or a pointer moving back towards it reopens it from far below the visible notch.
@MainActor
struct NotchHoverRegionTests {
    private let geometry = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        topInset: 32,
        leftAuxiliaryWidth: 645.5,
        rightAuxiliaryWidth: 645.5
    )!
    private let system = NotchActivityLayout(id: "system", metrics: NotchActivityMetrics(
        compactSideWidth: nil,
        expandedSectionSize: CGSize(width: 380, height: 44)
    ))
    private let timer = NotchActivityLayout(id: "timer", metrics: NotchActivityMetrics(
        compactSideWidth: 40,
        expandedSectionSize: CGSize(width: 300, height: 60),
        minimalSize: CGSize(width: 26, height: 26)
    ))

    @Test func collapsingTracksOnlyTheCompactNotch() {
        let expanded = NotchState.make(isExpanded: true, activities: [system], momentSize: nil)
        let collapsed = NotchState.make(isExpanded: false, activities: [system], momentSize: nil)
        let panel = NotchWindowController.panelFrame(for: expanded, geometry: geometry)

        let regions = NotchWindowController.hoverRegions(for: collapsed, geometry: geometry, panelOrigin: panel.origin)

        #expect(regions.notch == geometry.notchRect.offsetBy(dx: -panel.minX, dy: -panel.minY))
        #expect(regions.bubble == nil)
    }

    @Test func bubbleIsTrackedWhereItWillBe() throws {
        let music = NotchActivityLayout(id: "music", metrics: NotchActivityMetrics(
            compactSideWidth: 36,
            expandedSectionSize: CGSize(width: 380, height: 140)
        ))
        let compact = NotchState.make(isExpanded: false, activities: [music, timer], momentSize: nil)
        let origin = CGPoint(x: 500, y: 800)
        let bubble = try #require(NotchWindowController.bubbleFrame(for: compact, geometry: geometry))

        let regions = NotchWindowController.hoverRegions(for: compact, geometry: geometry, panelOrigin: origin)

        #expect(regions.bubble == NotchTrackingView.Bubble(activity: "timer", rect: bubble.offsetBy(dx: -500, dy: -800)))
    }

    @Test func trackingViewTracksOnlyTheGivenNotch() throws {
        let view = NotchTrackingView(frame: CGRect(x: 0, y: 0, width: 380, height: 140))
        view.notch = CGRect(x: 100, y: 108, width: 180, height: 32)

        let area = try #require(view.trackingAreas.first)
        #expect(view.trackingAreas.count == 1)
        #expect(area.rect == CGRect(x: 100, y: 108, width: 180, height: 32))
        #expect(!area.options.contains(.inVisibleRect))
    }
}
