import AppKit
import Testing
@testable import NotAnIsland

@MainActor
struct NotchBubbleTests {
    private let geometry = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        topInset: 32,
        leftAuxiliaryWidth: 645.5,
        rightAuxiliaryWidth: 645.5
    )!
    private let music = NotchActivityLayout(id: "music", metrics: NotchActivityMetrics(
        compactSideWidth: 36,
        expandedSectionSize: CGSize(width: 380, height: 140),
        minimalSize: CGSize(width: 26, height: 26)
    ))
    private let timer = NotchActivityLayout(id: "timer", metrics: NotchActivityMetrics(
        compactSideWidth: 50,
        expandedSectionSize: CGSize(width: 300, height: 60),
        minimalSize: CGSize(width: 26, height: 26)
    ))
    private let stats = NotchActivityLayout(id: "stats", metrics: NotchActivityMetrics(
        compactSideWidth: nil,
        expandedSectionSize: CGSize(width: 380, height: 44)
    ))

    private func state(expanded: Bool = false, focus: String? = nil, _ activities: [NotchActivityLayout]) -> NotchState {
        NotchState.make(isExpanded: expanded, focus: focus, activities: activities, momentSize: nil)
    }

    // MARK: Who gets the bubble

    @Test func secondActivityWithAMinimalViewBecomesTheBubble() {
        let state = state([music, timer])

        #expect(state.compactActivity == "music")
        #expect(state.bubble == NotchBubble(activity: "timer", size: CGSize(width: 26, height: 26)))
    }

    @Test func wingsOwnerIsNeverAlsoTheBubble() {
        #expect(state([music]).bubble == nil)
    }

    @Test func activityWithoutAMinimalViewIsSkippedForTheBubble() {
        #expect(state([music, stats]).bubble == nil)
        #expect(state([music, stats, timer]).bubble?.activity == "timer")
    }

    @Test func onlyOneBubble() {
        let third = NotchActivityLayout(id: "third", metrics: timer.metrics)
        #expect(state([music, timer, third]).bubble?.activity == "timer")
    }

    // MARK: Where the bubble sits

    @Test func bubbleSitsRightOfTheWingsCentredOnTheCameraBand() {
        let bubble = NotchWindowController.bubbleFrame(for: state([music, timer]), geometry: geometry)
        let wings = geometry.compactRect(sideWidth: 36)

        #expect(bubble == CGRect(
            x: wings.maxX + NotchGeometry.bubbleGap,
            y: geometry.notchRect.midY - 13,
            width: 26,
            height: 26
        ))
    }

    @Test func bubbleIsNeverTallerThanTheNotch() throws {
        let tall = NotchActivityLayout(id: "tall", metrics: NotchActivityMetrics(
            compactSideWidth: nil, expandedSectionSize: nil, minimalSize: CGSize(width: 80, height: 80)
        ))
        let bubble = try #require(NotchWindowController.bubbleFrame(for: state([music, tall]), geometry: geometry))

        #expect(bubble.height == geometry.notchRect.height)
        #expect(bubble.width <= geometry.notchRect.height * NotchGeometry.maximumBubbleAspect)
    }

    @Test func expandedNotchHasNoBubble() {
        #expect(NotchWindowController.bubbleFrame(for: state(expanded: true, [music, timer]), geometry: geometry) == nil)
    }

    @Test func panelCoversTheWingsAndTheBubble() throws {
        let compact = state([music, timer])
        let main = NotchWindowController.frame(for: compact, geometry: geometry)
        let bubble = try #require(NotchWindowController.bubbleFrame(for: compact, geometry: geometry))

        #expect(NotchWindowController.panelFrame(for: compact, geometry: geometry) == main.union(bubble))
    }

    // MARK: Focused expansion

    @Test func focusedExpansionShowsOnlyThatActivity() {
        let state = state(expanded: true, focus: "timer", [music, timer, stats])
        #expect(state.sections.map(\.activity) == ["timer"])
    }

    @Test func focusOnAnEndedActivityFallsBackToEverything() {
        let state = state(expanded: true, focus: "gone", [music, stats])
        #expect(state.sections.map(\.activity) == ["music", "stats"])
    }

    // The pointer stays where the bubble was, so the expanded notch must reach it or it would collapse at once.
    @Test func focusedExpansionStillCoversTheBubble() throws {
        let wide = NotchActivityLayout(id: "wide", metrics: NotchActivityMetrics(
            compactSideWidth: 150, expandedSectionSize: CGSize(width: 380, height: 140)
        ))
        let compact = state([wide, timer])
        let bubble = try #require(NotchWindowController.bubbleFrame(for: compact, geometry: geometry))
        let expanded = NotchWindowController.frame(for: state(expanded: true, focus: "timer", [wide, timer]), geometry: geometry)

        #expect(expanded.minX <= bubble.minX && expanded.maxX >= bubble.maxX)
        #expect(expanded.midX == geometry.notchRect.midX)
    }

    // MARK: Canvas

    @Test func canvasFitsTheBubbleEitherSideOfTheNotch() {
        let canvas = NotchWindowController.canvasSize(geometry: geometry, activities: [music.metrics, timer.metrics])
        let farthestBubble = geometry.compactRect(sideWidth: 50).maxX + NotchGeometry.bubbleGap + 26

        #expect(canvas.width / 2 >= farthestBubble - geometry.notchRect.midX)
    }

    @Test func contentIsCentredOnTheNotchWhenThePanelIsLopsided() {
        let frame = NotchWindowController.contentFrame(
            in: CGRect(x: 0, y: 0, width: 300, height: 32),
            centreX: 100,
            contentSize: CGSize(width: 400, height: 200)
        )
        #expect(frame.midX == 100)
    }
}

@MainActor
struct NotchBubbleHoverTests {
    private final class Recorder {
        var changes: [Bool] = []
    }

    private let recorder = Recorder()

    private func makeModel() -> NotchHoverModel {
        let recorder = recorder
        let model = NotchHoverModel(sleep: { _ in }, isPointerInside: { false })
        model.onExpansionChange = { recorder.changes.append($0) }
        return model
    }

    @Test func enteringTheBubbleExpandsFocusedOnItsActivity() {
        let model = makeModel()
        model.pointerEntered(focus: "timer")

        #expect(model.isExpanded)
        #expect(model.focus == "timer")
    }

    @Test func enteringTheNotchExpandsEverything() {
        let model = makeModel()
        model.pointerEntered()

        #expect(model.focus == nil)
    }

    @Test func collapsingClearsTheFocus() async {
        let model = makeModel()
        model.pointerEntered(focus: "timer")
        model.pointerExited(speed: 500)
        await model.pendingCollapse?.value

        #expect(!model.isExpanded)
        #expect(model.focus == nil)
    }

    // Once expanded from the bubble, moving across the expanded notch keeps showing that activity.
    @Test func reenteringWhileExpandedKeepsTheFocus() {
        let model = makeModel()
        model.pointerEntered(focus: "timer")
        model.pointerExited(speed: 100)
        model.pointerEntered()

        #expect(model.focus == "timer")
        #expect(recorder.changes == [true])
    }
}

@MainActor
struct NotchBubbleTrackingTests {
    @Test func withoutABubbleTheWholePanelIsTracked() throws {
        let view = NotchTrackingView(frame: CGRect(x: 0, y: 0, width: 200, height: 32))
        #expect(view.trackingAreas.count == 1)
        #expect(try #require(view.trackingAreas.first).options.contains(.inVisibleRect))
    }

    @Test func bubbleGetsItsOwnRegionAndTheGapIsNotTracked() throws {
        let view = NotchTrackingView(frame: CGRect(x: 0, y: 0, width: 300, height: 32))
        view.bubble = NotchTrackingView.Bubble(activity: "timer", rect: CGRect(x: 270, y: 3, width: 26, height: 26))

        let areas = view.trackingAreas
        #expect(areas.count == 2)
        let bubble = try #require(areas.first { $0.userInfo?[NotchTrackingView.bubbleKey] as? String == "timer" })
        let main = try #require(areas.first { $0 !== bubble })
        #expect(bubble.rect == CGRect(x: 270, y: 3, width: 26, height: 26))
        #expect(main.rect.maxX == 270 - NotchGeometry.bubbleGap)
    }
}
