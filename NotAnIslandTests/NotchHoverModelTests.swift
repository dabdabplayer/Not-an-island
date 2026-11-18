import Testing
@testable import NotAnIsland

@MainActor
struct NotchHoverModelTests {
    private final class Recorder {
        var changes: [Bool] = []
        var requestedDelays: [Duration] = []
        var pointerInside = false
    }

    private let recorder = Recorder()

    /// Sleeps return immediately so tests control timing by awaiting `pendingCollapse` instead of the wall clock.
    private func makeModel() -> NotchHoverModel {
        let recorder = recorder
        let model = NotchHoverModel(
            sleep: { recorder.requestedDelays.append($0) },
            isPointerInside: { recorder.pointerInside }
        )
        model.onExpansionChange = { recorder.changes.append($0) }
        return model
    }

    @Test func startsCollapsed() {
        #expect(!makeModel().isExpanded)
    }

    @Test func pointerEnteringExpandsOnce() {
        let model = makeModel()
        model.pointerEntered()
        model.pointerEntered()

        #expect(model.isExpanded)
        #expect(recorder.changes == [true])
    }

    @Test func pointerExitingWhileCollapsedDoesNothing() {
        let model = makeModel()
        model.pointerExited(speed: 500)

        #expect(model.pendingCollapse == nil)
        #expect(recorder.changes.isEmpty)
    }

    @Test func pointerExitingCollapsesOnlyAfterTheDelay() async {
        let model = makeModel()
        model.pointerEntered()
        model.pointerExited(speed: 500)

        #expect(model.isExpanded)

        await model.pendingCollapse?.value

        #expect(!model.isExpanded)
        #expect(recorder.requestedDelays == [NotchHoverModel.collapseDelay(forExitSpeed: 500)])
        #expect(recorder.changes == [true, false])
    }

    @Test func slowExitWaitsTheFullSecond() {
        #expect(NotchHoverModel.collapseDelay(forExitSpeed: 200) == .seconds(1))
        #expect(NotchHoverModel.collapseDelay(forExitSpeed: 50) == .seconds(1))
    }

    @Test func fastExitCollapsesAlmostImmediately() {
        #expect(NotchHoverModel.collapseDelay(forExitSpeed: 2000) == .milliseconds(100))
        #expect(NotchHoverModel.collapseDelay(forExitSpeed: 6000) == .milliseconds(100))
    }

    // No movement samples means the pointer crossed the notch within a single frame.
    @Test func unmeasuredExitCountsAsFast() {
        #expect(NotchHoverModel.collapseDelay(forExitSpeed: nil) == .milliseconds(100))
    }

    @Test func delayShrinksSteadilyBetweenSlowAndFast() {
        let midway = NotchHoverModel.collapseDelay(forExitSpeed: 1100)
        #expect(abs((midway - .milliseconds(550)) / .milliseconds(1)) < 1)

        let speeds: [Double] = [200, 500, 800, 1100, 1400, 1700, 2000]
        let delays = speeds.map { NotchHoverModel.collapseDelay(forExitSpeed: $0) }
        #expect(delays == delays.sorted(by: >))
    }

    @Test func pointerReturningBeforeTheDelayCancelsCollapse() async {
        let model = makeModel()
        model.pointerEntered()
        model.pointerExited(speed: 500)
        let cancelledCollapse = model.pendingCollapse
        model.pointerEntered()

        await cancelledCollapse?.value

        #expect(model.isExpanded)
        #expect(model.pendingCollapse == nil)
        #expect(recorder.changes == [true])
    }

    @Test func staysExpandedIfPointerIsStillInsideWhenDelayEnds() async {
        let model = makeModel()
        model.pointerEntered()
        model.pointerExited(speed: 500)
        recorder.pointerInside = true

        await model.pendingCollapse?.value

        #expect(model.isExpanded)
        #expect(recorder.changes == [true])
    }

    @Test func heldOpenNotchIgnoresPointerLeaving() {
        let model = makeModel()
        model.pointerEntered()
        model.setHeldOpen(true)
        model.pointerExited(speed: 5000)

        #expect(model.pendingCollapse == nil)
        #expect(model.isExpanded)
    }

    @Test func releasingHoldWithPointerOutsideCollapsesAfterTheSlowDelay() async {
        let model = makeModel()
        model.pointerEntered()
        model.setHeldOpen(true)
        model.pointerExited(speed: 5000)
        model.setHeldOpen(false)

        await model.pendingCollapse?.value

        #expect(!model.isExpanded)
        #expect(recorder.requestedDelays == [NotchHoverModel.slowestCollapseDelay])
    }

    @Test func releasingHoldWithPointerInsideStaysExpanded() {
        let model = makeModel()
        model.pointerEntered()
        model.setHeldOpen(true)
        recorder.pointerInside = true
        model.setHeldOpen(false)

        #expect(model.pendingCollapse == nil)
        #expect(model.isExpanded)
    }

    @Test func holdingOpenCancelsAPendingCollapse() async {
        let model = makeModel()
        model.pointerEntered()
        model.pointerExited(speed: 500)
        let cancelled = model.pendingCollapse
        model.setHeldOpen(true)

        await cancelled?.value

        #expect(model.isExpanded)
    }
}
