import AppKit
import ExtensionFoundation
import ExtensionKit
import NotAnIslandKit
import os
import SwiftUI

/// Finds the installed extensions for Not an Island's extension point that the user has enabled.
/// Extensions from other apps start disabled; people enable them in Settings.
@MainActor
@Observable
final class ExtensionDiscovery {
    nonisolated static let extensionPointID = NotchWire.extensionPointID
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "Extensions")

    private(set) var identities: [AppExtensionIdentity] = []
    /// Why discovery stopped, if it did.
    private(set) var failure: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var monitor: AnyObject?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            if #available(macOS 26.0, *) {
                await self?.monitorExtensions()
            } else {
                await self?.matchExtensions()
            }
        }
    }

    /// The first item for each ID, in order.
    nonisolated static func firstOfEach<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert(id($0)).inserted }
    }

    private func update(_ found: [AppExtensionIdentity]) {
        // Every installed copy of an app registers its extension; the notch shows each extension once.
        let identities = Self.firstOfEach(found, id: \.bundleIdentifier)
        guard identities != self.identities else { return }
        Self.logger.debug("Enabled extensions: \(identities.map(\.bundleIdentifier), privacy: .public)")
        self.identities = identities
    }

    private func fail(_ error: any Error) {
        Self.logger.error("Extension discovery failed: \(error, privacy: .public)")
        failure = error.localizedDescription
    }

    @available(macOS 26.0, *)
    private func monitorExtensions() async {
        do {
            let point = try AppExtensionPoint(identifier: "app.arysha.NotAnIsland.activity")
            let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: point)
            self.monitor = monitor
            observe(monitor)
        } catch {
            fail(error)
        }
    }

    @available(macOS 26.0, *)
    private func observe(_ monitor: AppExtensionPoint.Monitor) {
        let identities = withObservationTracking {
            monitor.identities
        } onChange: { [weak self] in
            // Fires before the change is applied; read the new value on the next main-actor turn.
            Task { @MainActor [weak self] in self?.observe(monitor) }
        }
        update(identities)
    }

    /// macOS 15 has no monitor; this sequence is its only way to follow installed extensions.
    private func matchExtensions() async {
        do {
            for try await identities in try AppExtensionIdentity.matching(appExtensionPointIDs: Self.extensionPointID) {
                update(identities)
            }
        } catch {
            fail(error)
        }
    }
}

/// An extension's content in the notch. Each presentation is a scene drawn by the extension's own
/// process, kept at a fixed size: the notch animates its own shape around it and never resizes it
/// mid-animation, which would lag behind the shape.
@MainActor
@Observable
final class ExtensionActivity: NotchActivity {
    /// Version 1 supports one activity per extension; the SDK names it this.
    nonisolated static let activityID = "default"
    nonisolated static let maximumCompactSideWidth: CGFloat = 80
    nonisolated static let maximumExpandedSize = CGSize(width: 480, height: 320)
    /// The notch geometry clamps the bubble further, to the camera band's height.
    nonisolated static let maximumMinimalSize = CGSize(width: 96, height: 32)
    nonisolated static let maximumBannerDuration: Duration = .seconds(10)

    let id: String
    let name: String
    private(set) var isActive = false
    /// How the extension's process is doing, for Settings.
    var sessionState = ExtensionSession.State.stopped
    private(set) var metrics = NotchActivityMetrics(compactSideWidth: nil, expandedSectionSize: nil)

    @ObservationIgnored private var bannerSize: CGSize?
    @ObservationIgnored private var isHoldingOpen = false
    @ObservationIgnored private let moments: NotchMoments
    @ObservationIgnored private let holdOpen: @MainActor (Bool) -> Void
    @ObservationIgnored private let send: @MainActor (HostMessage) -> Void
    @ObservationIgnored private let remoteView: @MainActor (NotchScene) -> AnyView

    /// - Parameters:
    ///   - holdOpen: Keeps the notch expanded, as built-in content does while scrubbing.
    ///   - send: Delivers a message to the extension process.
    ///   - remoteView: The extension's scene for a presentation.
    init(
        id: String,
        name: String,
        moments: NotchMoments,
        holdOpen: @escaping @MainActor (Bool) -> Void,
        send: @escaping @MainActor (HostMessage) -> Void,
        remoteView: @escaping @MainActor (NotchScene) -> AnyView
    ) {
        self.id = id
        self.name = name
        self.moments = moments
        self.holdOpen = holdOpen
        self.send = send
        self.remoteView = remoteView
    }

    func handle(_ message: ExtensionMessage) {
        switch message {
        case .activityChanged(Self.activityID, let isActive, let sizes):
            metrics = NotchActivityMetrics(
                compactSideWidth: sizes.compactSideWidth.flatMap { Self.capped($0, to: Self.maximumCompactSideWidth) },
                expandedSectionSize: sizes.expanded.flatMap { Self.capped($0, to: Self.maximumExpandedSize) },
                minimalSize: sizes.minimal.flatMap { Self.capped($0, to: Self.maximumMinimalSize) }
            )
            bannerSize = sizes.banner.flatMap { Self.capped($0, to: NotchMoment.maximumSize) }
            self.isActive = isActive
        case .postBanner(Self.activityID, let seconds):
            guard let bannerSize, seconds > 0 else { return }
            moments.present(NotchMoment(
                size: bannerSize,
                duration: min(.seconds(seconds), Self.maximumBannerDuration),
                content: AnyView(remoteView(.banner).frame(width: bannerSize.width, height: bannerSize.height))
            ))
        case .holdOpen(Self.activityID, let held):
            isHoldingOpen = held
            holdOpen(held)
        case .activityChanged, .postBanner, .holdOpen:
            break
        }
    }

    /// The process ended: its presentations leave at once, and it can no longer hold the notch open.
    func extensionStopped() {
        isActive = false
        if isHoldingOpen {
            isHoldingOpen = false
            holdOpen(false)
        }
    }

    func compactLeadingView() -> AnyView {
        fixedWidth(.compactLeading, metrics.compactSideWidth)
    }

    func compactTrailingView() -> AnyView {
        fixedWidth(.compactTrailing, metrics.compactSideWidth)
    }

    func expandedView() -> AnyView {
        fixedSize(.expanded, metrics.expandedSectionSize)
    }

    func minimalView() -> AnyView {
        fixedSize(.minimal, metrics.minimalSize)
    }

    func notchDidChangeExpansion(_ isExpanded: Bool) {
        // Collapsed, the activity shows in the wings or as the bubble, whichever it has been given.
        send(.presentationsChanged(visible: isExpanded ? [.expanded] : [.compactLeading, .compactTrailing, .minimal]))
    }

    /// Empty or negative sizes mean the presentation isn't offered.
    private static func capped(_ value: CGFloat, to maximum: CGFloat) -> CGFloat? {
        value > 0 ? min(value, maximum) : nil
    }

    private static func capped(_ size: CGSize, to maximum: CGSize) -> CGSize? {
        guard size.width > 0, size.height > 0 else { return nil }
        return CGSize(width: min(size.width, maximum.width), height: min(size.height, maximum.height))
    }

    private func fixedWidth(_ scene: NotchScene, _ width: CGFloat?) -> AnyView {
        guard let width else { return AnyView(EmptyView()) }
        return AnyView(remoteView(scene).frame(width: width))
    }

    private func fixedSize(_ scene: NotchScene, _ size: CGSize?) -> AnyView {
        guard let size else { return AnyView(EmptyView()) }
        return AnyView(remoteView(scene).frame(width: size.width, height: size.height))
    }
}

/// An enabled extension: its activity in the notch and the session keeping its process running.
@MainActor
final class InstalledExtension {
    /// Lets the activity reach the session created after it.
    private final class SessionRelay {
        weak var session: ExtensionSession?
    }

    let identity: AppExtensionIdentity
    let activity: ExtensionActivity
    let session: ExtensionSession

    init(identity: AppExtensionIdentity, moments: NotchMoments, holdOpen: @escaping @MainActor (Bool) -> Void) {
        let relay = SessionRelay()
        let scenes = RemoteSceneCache()
        let activity = ExtensionActivity(
            id: identity.bundleIdentifier,
            name: identity.localizedName,
            moments: moments,
            holdOpen: holdOpen,
            send: { relay.session?.send($0) },
            remoteView: { scene in AnyView(RemoteSceneView(identity: identity, scene: scene, cache: scenes)) }
        )
        session = ExtensionSession(
            launch: { try await launchExtension(identity, events: $0) },
            onMessage: { [weak activity] in activity?.handle($0) },
            onStop: { [weak activity] in activity?.extensionStopped() }
        )
        session.onStateChange = { [weak activity] in activity?.sessionState = $0 }
        relay.session = session
        self.identity = identity
        self.activity = activity
    }
}

/// A running extension process, as the session sees it.
@MainActor
protocol ExtensionChannel: AnyObject {
    func send(_ message: HostMessage)
    func invalidate()
}

/// What a launched process reports back. Called on XPC's queues.
struct ExtensionEvents: Sendable {
    let message: @Sendable (Data) -> Void
    let interrupted: @Sendable () -> Void
}

/// Keeps one extension's process running while it is enabled: launches it, relays its messages,
/// and relaunches it with a growing delay after a crash, giving up after repeated failures.
@MainActor
final class ExtensionSession {
    enum State: Equatable {
        case stopped, starting, running, waitingToRelaunch, incompatible
        case failed(String)
    }

    nonisolated static let relaunchDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]
    /// A process that ran at least this long before crashing starts its backoff afresh.
    nonisolated static let stableRunTime: TimeInterval = 60

    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "Extensions")

    private(set) var state = State.stopped {
        didSet {
            if state != oldValue { onStateChange(state) }
        }
    }
    var onStateChange: @MainActor (State) -> Void = { _ in }
    private(set) var pendingRelaunch: Task<Void, Never>?

    private var channel: (any ExtensionChannel)?
    /// Identifies the current process, so late reports from an earlier one are ignored.
    private var generation = 0
    private var failures = 0
    private var startedAt: Date?

    private let launch: @MainActor (ExtensionEvents) async throws -> any ExtensionChannel
    private let sleep: (Duration) async throws -> Void
    private let now: () -> Date
    private let onMessage: @MainActor (ExtensionMessage) -> Void
    private let onStop: @MainActor () -> Void

    init(
        launch: @escaping @MainActor (ExtensionEvents) async throws -> any ExtensionChannel,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init,
        onMessage: @escaping @MainActor (ExtensionMessage) -> Void,
        onStop: @escaping @MainActor () -> Void
    ) {
        self.launch = launch
        self.sleep = sleep
        self.now = now
        self.onMessage = onMessage
        self.onStop = onStop
    }

    func start() async {
        pendingRelaunch?.cancel()
        pendingRelaunch = nil
        generation += 1
        let generation = generation
        state = .starting
        let events = ExtensionEvents(
            message: { [weak self] data in
                Task { @MainActor in self?.received(data, generation: generation) }
            },
            interrupted: { [weak self] in
                Task { @MainActor in self?.ended(generation: generation, reason: "The extension stopped unexpectedly.") }
            }
        )
        do {
            let channel = try await launch(events)
            guard generation == self.generation, state == .starting else {
                channel.invalidate()
                return
            }
            self.channel = channel
            startedAt = now()
            state = .running
            channel.send(.hello(protocolVersion: NotchWire.majorVersion))
        } catch {
            ended(generation: generation, reason: error.localizedDescription)
        }
    }

    func stop() {
        generation += 1
        pendingRelaunch?.cancel()
        pendingRelaunch = nil
        channel?.invalidate()
        channel = nil
        state = .stopped
    }

    func send(_ message: HostMessage) {
        channel?.send(message)
    }

    private func received(_ data: Data, generation: Int) {
        guard generation == self.generation, state == .running else { return }
        do {
            onMessage(try NotchWire.decode(ExtensionMessage.self, from: data))
        } catch NotchWire.Error.newerVersion(let major) {
            Self.logger.error("Extension speaks protocol \(major), newer than \(NotchWire.majorVersion)")
            channel?.invalidate()
            channel = nil
            state = .incompatible
            onStop()
        } catch {
            Self.logger.error("Dropped an unreadable extension message: \(error, privacy: .public)")
        }
    }

    private func ended(generation: Int, reason: String) {
        guard generation == self.generation, state == .running || state == .starting else { return }
        channel?.invalidate()
        channel = nil
        onStop()

        if let startedAt, now().timeIntervalSince(startedAt) >= Self.stableRunTime {
            failures = 0
        }
        startedAt = nil
        guard failures < Self.relaunchDelays.count else {
            Self.logger.error("Gave up on an extension: \(reason, privacy: .public)")
            state = .failed(reason)
            return
        }
        let delay = Self.relaunchDelays[failures]
        failures += 1
        state = .waitingToRelaunch
        pendingRelaunch = Task { [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                return  // Stopped meanwhile.
            }
            guard let self, !Task.isCancelled else { return }
            pendingRelaunch = nil
            await start()
        }
    }
}

/// Launches an extension's process and opens its message channel over XPC.
@MainActor
func launchExtension(_ identity: AppExtensionIdentity, events: ExtensionEvents) async throws -> any ExtensionChannel {
    let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: events.interrupted))
    let connection = try process.makeXPCConnection()
    connection.exportedInterface = NSXPCInterface(with: NotchMessageChannel.self)
    connection.exportedObject = HostMessageReceiver(events.message)
    connection.remoteObjectInterface = NSXPCInterface(with: NotchMessageChannel.self)
    connection.interruptionHandler = events.interrupted
    connection.invalidationHandler = events.interrupted
    connection.resume()
    return XPCExtensionChannel(process: process, connection: connection)
}

@MainActor
private final class XPCExtensionChannel: ExtensionChannel {
    private let process: AppExtensionProcess
    private let connection: NSXPCConnection

    init(process: AppExtensionProcess, connection: NSXPCConnection) {
        self.process = process
        self.connection = connection
    }

    func send(_ message: HostMessage) {
        guard let data = try? NotchWire.encode(message),
              let proxy = connection.remoteObjectProxy as? NotchMessageChannel
        else { return }
        proxy.receive(data)
    }

    func invalidate() {
        connection.invalidationHandler = nil
        connection.invalidate()
        process.invalidate()
    }
}

/// Receives an extension's messages on XPC's queue.
private final class HostMessageReceiver: NSObject, NotchMessageChannel, Sendable {
    private let handler: @Sendable (Data) -> Void

    init(_ handler: @escaping @Sendable (Data) -> Void) {
        self.handler = handler
    }

    func receive(_ message: Data) {
        handler(message)
    }
}

/// Keeps each panel's remote views connected while they are off screen, so expanding and
/// collapsing never reconnects to the extension or flashes an empty view.
@MainActor
final class RemoteSceneCache {
    private struct Key: Hashable {
        let surface: ObjectIdentifier
        let scene: NotchScene
    }

    private var controllers: [Key: EXHostViewController] = [:]

    func controller(for identity: AppExtensionIdentity, scene: NotchScene, surface: ObjectIdentifier) -> EXHostViewController {
        let key = Key(surface: surface, scene: scene)
        if let controller = controllers[key] {
            return controller
        }
        let controller = EXHostViewController()
        controller.placeholderView = NSView()
        controller.configuration = EXHostViewController.Configuration(appExtension: identity, sceneID: scene.rawValue)
        controllers[key] = controller
        return controller
    }
}

extension EnvironmentValues {
    /// Identifies the panel a view is drawn in; each panel needs its own copies of remote views.
    @Entry var notchSurface: ObjectIdentifier?
}

struct RemoteSceneView: NSViewControllerRepresentable {
    let identity: AppExtensionIdentity
    let scene: NotchScene
    let cache: RemoteSceneCache

    func makeNSViewController(context: Context) -> EXHostViewController {
        let surface = context.environment.notchSurface ?? ObjectIdentifier(cache)
        let controller = cache.controller(for: identity, scene: scene, surface: surface)
        // A cached controller may still be attached to the hierarchy SwiftUI just tore down.
        controller.view.removeFromSuperview()
        return controller
    }

    func updateNSViewController(_ controller: EXHostViewController, context: Context) {}
}
