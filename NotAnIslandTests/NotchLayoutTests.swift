import AppKit
import SwiftUI
import Testing
@testable import NotAnIsland

@MainActor
struct NotchLayoutTests {
    private let geometry = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        topInset: 32,
        leftAuxiliaryWidth: 645.5,
        rightAuxiliaryWidth: 645.5
    )!
    private let music = NotchActivityMetrics(compactSideWidth: 36, expandedSectionSize: CGSize(width: 380, height: 140))
    private let stats = NotchActivityMetrics(compactSideWidth: nil, expandedSectionSize: CGSize(width: 380, height: 44))

    /// Activities named by their position; nil marks an inactive one.
    private func layouts(_ activities: [NotchActivityMetrics?]) -> [NotchActivityLayout] {
        activities.enumerated().compactMap { index, metrics in
            metrics.map { NotchActivityLayout(id: "\(index)", metrics: $0) }
        }
    }

    private func frame(expanded: Bool, _ activities: [NotchActivityMetrics?], moment: CGSize? = nil) -> CGRect {
        let state = NotchState.make(isExpanded: expanded, activities: layouts(activities), momentSize: moment)
        return NotchWindowController.frame(for: state, geometry: geometry)
    }

    @Test func idleNotchCoversOnlyTheCamera() {
        #expect(frame(expanded: false, []) == geometry.notchRect)
        #expect(frame(expanded: false, [nil, nil]) == geometry.notchRect)
    }

    @Test func hoverWithNoSectionsUsesTheDefaultExpansion() {
        #expect(frame(expanded: true, [nil]) == geometry.expandedRect(scale: NotchWindowController.expansionScale))
    }

    @Test func firstActiveCompactActivityOwnsTheWings() {
        let other = NotchActivityMetrics(compactSideWidth: 50, expandedSectionSize: nil)
        let state = NotchState.make(isExpanded: false, activities: layouts([nil, music, other]), momentSize: nil)

        #expect(state.compactActivity == "1")
        #expect(frame(expanded: false, [nil, music, other]) == geometry.compactRect(sideWidth: 36))
    }

    @Test func activityWithoutACompactRoleNeverWidensTheNotch() {
        #expect(frame(expanded: false, [stats]) == geometry.notchRect)
    }

    @Test func expandedSectionsStackTopToBottom() {
        let state = NotchState.make(isExpanded: true, activities: layouts([music, stats]), momentSize: nil)

        #expect(state.sections.map(\.activity) == ["0", "1"])
        #expect(frame(expanded: true, [music, stats])
            == geometry.expandedRect(contentSize: CGSize(width: 380, height: 184)))
    }

    @Test func inactiveActivitiesAddNoSection() {
        #expect(frame(expanded: true, [nil, stats]) == geometry.expandedRect(contentSize: CGSize(width: 380, height: 44)))
    }

    @Test func expandedWidthIsTheWidestSection() {
        let narrow = NotchActivityMetrics(compactSideWidth: nil, expandedSectionSize: CGSize(width: 200, height: 30))
        #expect(frame(expanded: true, [narrow, stats]).width == 380)
    }

    @Test func momentHangsBelowTheCameraBand() {
        let moment = CGSize(width: 240, height: 44)
        #expect(frame(expanded: false, [], moment: moment) == geometry.expandedRect(contentSize: moment))
    }

    @Test func momentIsNeverNarrowerThanTheCompactWings() {
        let moment = CGSize(width: 200, height: 44)
        #expect(frame(expanded: false, [music], moment: moment).width == geometry.compactRect(sideWidth: 36).width)
    }

    // The SwiftUI canvas never resizes during an animation, so it must already fit the largest state.
    @Test func canvasFitsEveryState() {
        let canvas = NotchWindowController.canvasSize(geometry: geometry, activities: [music, stats])
        let largestMoment = geometry.expandedRect(contentSize: NotchMoment.maximumSize)

        #expect(canvas.width >= 380)
        #expect(canvas.height >= 32 + 184)
        #expect(canvas.width >= largestMoment.width)
        #expect(canvas.height >= largestMoment.height)
    }

    // The panel can never become key, so every click is a "first mouse" click; without this the
    // first click on a control would only be swallowed.
    @Test func hostingViewAcceptsFirstMouse() {
        let view = NotchHostingView(rootView: EmptyView())
        #expect(view.acceptsFirstMouse(for: nil))
    }
}

@MainActor
struct NotchMomentsTests {
    private final class Recorder {
        var changes: [UUID?] = []
        var delays: [Duration] = []
        var suppressed = false
    }

    private let recorder = Recorder()

    /// Sleeps return immediately; tests await `pendingEnd` instead of the wall clock.
    private func makeMoments(waitUntilCancelled: Bool = false) -> NotchMoments {
        let recorder = recorder
        let moments = NotchMoments(sleep: { duration in
            recorder.delays.append(duration)
            if waitUntilCancelled { try await Task.sleep(for: .seconds(3600)) }
        })
        moments.isSuppressed = { recorder.suppressed }
        moments.onChange = { recorder.changes.append($0?.id) }
        return moments
    }

    private func moment(width: CGFloat = 240) -> NotchMoment {
        NotchMoment(size: CGSize(width: width, height: 44), duration: .seconds(3), content: AnyView(EmptyView()))
    }

    @Test func presentedMomentShowsThenEndsAfterItsDuration() async {
        let moments = makeMoments()
        let shown = moment()
        moments.present(shown)

        #expect(moments.current?.id == shown.id)
        await moments.pendingEnd?.value

        #expect(moments.current == nil)
        #expect(recorder.delays == [.seconds(3)])
        #expect(recorder.changes == [shown.id, nil])
    }

    @Test func newMomentReplacesTheCurrentOne() async {
        // Neither moment may end on its own here; only the replacement cancels the first.
        let moments = makeMoments(waitUntilCancelled: true)
        let first = moment()
        let second = moment()
        moments.present(first)
        let firstEnd = moments.pendingEnd
        moments.present(second)
        await firstEnd?.value

        #expect(moments.current?.id == second.id)
        #expect(recorder.changes == [first.id, second.id])
    }

    @Test func momentIsDroppedWhileTheNotchIsExpanded() {
        recorder.suppressed = true
        let moments = makeMoments()
        moments.present(moment())

        #expect(moments.current == nil)
        #expect(recorder.changes.isEmpty)
    }

    @Test func dismissingEndsTheMomentImmediately() {
        let moments = makeMoments()
        moments.present(moment())
        moments.dismiss()

        #expect(moments.current == nil)
        #expect(recorder.changes.last == .some(nil))
    }

    @Test func oversizedMomentIsClampedToTheMaximum() {
        let huge = NotchMoment(size: CGSize(width: 2000, height: 500), duration: .seconds(3), content: AnyView(EmptyView()))
        #expect(huge.size == NotchMoment.maximumSize)
    }
}
