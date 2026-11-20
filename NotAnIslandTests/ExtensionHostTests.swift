import Foundation
import NotAnIslandKit
import SwiftUI
import Testing
@testable import NotAnIsland

@MainActor
private final class FakeChannel: ExtensionChannel {
    var sent: [HostMessage] = []
    var invalidated = false

    func send(_ message: HostMessage) {
        sent.append(message)
    }

    func invalidate() {
        invalidated = true
    }
}

/// Launches fake extension processes and lets tests deliver their messages and crashes.
@MainActor
private final class FakeLauncher {
    var launches = 0
    var failNextLaunch = false
    var channels: [FakeChannel] = []
    var events: [ExtensionEvents] = []

    func launch(_ events: ExtensionEvents) async throws -> any ExtensionChannel {
        launches += 1
        if failNextLaunch {
            failNextLaunch = false
            throw CocoaError(.featureUnsupported)
        }
        let channel = FakeChannel()
        channels.append(channel)
        self.events.append(events)
        return channel
    }

    func deliver(_ message: ExtensionMessage) throws {
        events.last?.message(try NotchWire.encode(message))
    }

    func crash() {
        events.last?.interrupted()
    }
}

@MainActor
struct ExtensionSessionTests {
    private final class Recorder {
        var messages: [ExtensionMessage] = []
        var stops = 0
        var delays: [Duration] = []
        var now = Date(timeIntervalSinceReferenceDate: 0)
    }

    private let launcher = FakeLauncher()
    private let recorder = Recorder()

    private func makeSession() -> ExtensionSession {
        let launcher = launcher
        let recorder = recorder
        return ExtensionSession(
            launch: { try await launcher.launch($0) },
            sleep: { recorder.delays.append($0) },
            now: { recorder.now },
            onMessage: { recorder.messages.append($0) },
            onStop: { recorder.stops += 1 }
        )
    }

    @Test func startingLaunchesAndGreetsTheExtension() async {
        let session = makeSession()
        await session.start()

        #expect(session.state == .running)
        #expect(launcher.channels.first?.sent == [.hello(protocolVersion: NotchWire.majorVersion)])
    }

    @Test func messagesReachTheActivity() async throws {
        let session = makeSession()
        await session.start()
        try launcher.deliver(.holdOpen(activityID: "default", held: true))
        await Task.yield()

        #expect(recorder.messages == [.holdOpen(activityID: "default", held: true)])
    }

    @Test func crashStopsTheActivityAndRelaunchesAfterABackoff() async {
        let session = makeSession()
        await session.start()
        launcher.crash()
        await Task.yield()

        #expect(recorder.stops == 1)
        await session.pendingRelaunch?.value

        #expect(recorder.delays == [ExtensionSession.relaunchDelays[0]])
        #expect(launcher.launches == 2)
        #expect(session.state == .running)
    }

    @Test func repeatedCrashesBackOffFurtherThenGiveUp() async {
        let session = makeSession()
        await session.start()
        for _ in ExtensionSession.relaunchDelays {
            launcher.crash()
            await Task.yield()
            await session.pendingRelaunch?.value
        }
        launcher.crash()
        await Task.yield()

        #expect(recorder.delays == ExtensionSession.relaunchDelays)
        #expect(session.pendingRelaunch == nil)
        guard case .failed = session.state else {
            Issue.record("expected the session to give up, got \(session.state)")
            return
        }
    }

    @Test func failingToLaunchCountsAsACrash() async {
        launcher.failNextLaunch = true
        let session = makeSession()
        await session.start()
        await session.pendingRelaunch?.value

        #expect(launcher.launches == 2)
        #expect(session.state == .running)
    }

    // An extension that ran fine for a while and then crashed once starts its backoff afresh.
    @Test func aLongRunResetsTheBackoff() async {
        let session = makeSession()
        await session.start()
        launcher.crash()
        await Task.yield()
        await session.pendingRelaunch?.value

        recorder.now += ExtensionSession.stableRunTime + 1
        launcher.crash()
        await Task.yield()
        await session.pendingRelaunch?.value

        #expect(recorder.delays == [ExtensionSession.relaunchDelays[0], ExtensionSession.relaunchDelays[0]])
    }

    // The process can report its end twice (interruption and invalidation); only one relaunch follows.
    @Test func duplicateInterruptionsRelaunchOnce() async {
        let session = makeSession()
        await session.start()
        launcher.crash()
        launcher.crash()
        await Task.yield()
        await session.pendingRelaunch?.value

        #expect(launcher.launches == 2)
        #expect(recorder.stops == 1)
    }

    @Test func newerExtensionIsMarkedIncompatibleAndIgnored() async throws {
        let session = makeSession()
        await session.start()
        let future = try JSONSerialization.data(withJSONObject: ["major": NotchWire.majorVersion + 1, "message": [:]])
        launcher.events.last?.message(future)
        await Task.yield()

        #expect(recorder.messages.isEmpty)
        #expect(session.state == .incompatible)
    }

    @Test func stoppingEndsTheProcessAndAnyRelaunch() async {
        let session = makeSession()
        await session.start()
        launcher.crash()
        await Task.yield()
        session.stop()

        #expect(session.pendingRelaunch == nil)
        #expect(launcher.channels.first?.invalidated == true)
        #expect(session.state == .stopped)
    }
}

@MainActor
struct ExtensionActivityTests {
    private final class Recorder {
        var heldOpen: [Bool] = []
        var sent: [HostMessage] = []
    }

    private let recorder = Recorder()
    private let moments = NotchMoments(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })

    private func makeActivity() -> ExtensionActivity {
        let recorder = recorder
        return ExtensionActivity(
            id: "com.example.timer",
            name: "Timer",
            moments: moments,
            holdOpen: { recorder.heldOpen.append($0) },
            send: { recorder.sent.append($0) },
            remoteView: { _ in AnyView(EmptyView()) }
        )
    }

    @Test func startsInactiveUntilTheExtensionReports() {
        #expect(!makeActivity().isActive)
    }

    @Test func reportedStateBecomesTheActivitysMetrics() {
        let activity = makeActivity()
        activity.handle(.activityChanged(activityID: "default", isActive: true, sizes: NotchActivitySizes(
            compactSideWidth: 40,
            expanded: CGSize(width: 300, height: 80),
            minimal: CGSize(width: 24, height: 24)
        )))

        #expect(activity.isActive)
        #expect(activity.metrics == NotchActivityMetrics(
            compactSideWidth: 40,
            expandedSectionSize: CGSize(width: 300, height: 80),
            minimalSize: CGSize(width: 24, height: 24)
        ))
    }

    @Test func oversizedPresentationsAreCapped() {
        let activity = makeActivity()
        activity.handle(.activityChanged(activityID: "default", isActive: true, sizes: NotchActivitySizes(
            compactSideWidth: 900,
            expanded: CGSize(width: 2000, height: 2000),
            minimal: CGSize(width: 500, height: 500)
        )))

        #expect(activity.metrics.compactSideWidth == ExtensionActivity.maximumCompactSideWidth)
        #expect(activity.metrics.expandedSectionSize == ExtensionActivity.maximumExpandedSize)
        #expect(activity.metrics.minimalSize == ExtensionActivity.maximumMinimalSize)
    }

    @Test func negativeSizesMeanNoPresentation() {
        let activity = makeActivity()
        activity.handle(.activityChanged(activityID: "default", isActive: true, sizes: NotchActivitySizes(
            compactSideWidth: -5,
            expanded: CGSize(width: 0, height: 80)
        )))

        #expect(activity.metrics.compactSideWidth == nil)
        #expect(activity.metrics.expandedSectionSize == nil)
    }

    // Version 1 has one activity per extension; anything else is from a newer SDK and is ignored.
    @Test func otherActivityIDsAreIgnored() {
        let activity = makeActivity()
        activity.handle(.activityChanged(activityID: "second", isActive: true, sizes: NotchActivitySizes(compactSideWidth: 40)))

        #expect(!activity.isActive)
    }

    @Test func bannerIsShownAtTheDeclaredSize() {
        let activity = makeActivity()
        activity.handle(.activityChanged(activityID: "default", isActive: true, sizes: NotchActivitySizes(
            banner: CGSize(width: 240, height: 44)
        )))
        activity.handle(.postBanner(activityID: "default", duration: 4))

        #expect(moments.current?.size == CGSize(width: 240, height: 44))
        #expect(moments.current?.duration == .seconds(4))
    }

    @Test func bannerWithoutADeclaredSizeIsIgnored() {
        let activity = makeActivity()
        activity.handle(.postBanner(activityID: "default", duration: 4))

        #expect(moments.current == nil)
    }

    @Test func bannerDurationIsCapped() {
        let activity = makeActivity()
        activity.handle(.activityChanged(activityID: "default", isActive: true, sizes: NotchActivitySizes(
            banner: CGSize(width: 240, height: 44)
        )))
        activity.handle(.postBanner(activityID: "default", duration: 600))

        #expect(moments.current?.duration == ExtensionActivity.maximumBannerDuration)
    }

    @Test func holdOpenIsForwardedAndReleasedWhenTheExtensionStops() {
        let activity = makeActivity()
        activity.handle(.holdOpen(activityID: "default", held: true))
        activity.extensionStopped()

        #expect(recorder.heldOpen == [true, false])
    }

    @Test func stoppingHidesTheActivity() {
        let activity = makeActivity()
        activity.handle(.activityChanged(activityID: "default", isActive: true, sizes: NotchActivitySizes(compactSideWidth: 40)))
        activity.extensionStopped()

        #expect(!activity.isActive)
    }

    @Test func tellsTheExtensionWhatIsOnScreen() {
        let activity = makeActivity()
        activity.notchDidChangeExpansion(true)
        activity.notchDidChangeExpansion(false)

        #expect(recorder.sent == [
            .presentationsChanged(visible: [.expanded]),
            .presentationsChanged(visible: [.compactLeading, .compactTrailing, .minimal]),
        ])
    }
}

struct ExtensionDiscoveryTests {
    // Two copies of the same app (say, in Applications and Downloads) register the same extension twice.
    @Test func duplicateCopiesOfAnExtensionAppearOnce() {
        let found = ["com.example.timer", "com.example.coffee", "com.example.timer"]
        #expect(ExtensionDiscovery.firstOfEach(found, id: \.self) == ["com.example.timer", "com.example.coffee"])
    }
}
