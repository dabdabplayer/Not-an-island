import ExtensionFoundation
import ExtensionKit
import Foundation
import SwiftUI

/// A Not an Island extension: SwiftUI views for each presentation, and a controller that tells the
/// notch when the activity is active.
///
/// ```swift
/// @main
/// struct TimerExtension: NotchActivityExtension {
///     let controller = NotchActivityController(sizes: NotchActivitySizes(compactSideWidth: 40))
///     var compactLeading: some View { Image(systemName: "timer") }
///     var compactTrailing: some View { Text("4:59") }
/// }
/// ```
///
/// Each view is drawn at the fixed size declared in the controller's `sizes`; a presentation whose
/// size is nil is not shown. Views can read the controller from the environment:
/// `@Environment(NotchActivityController.self) var controller`.
@MainActor
public protocol NotchActivityExtension: AppExtension where Configuration == AppExtensionSceneConfiguration {
    associatedtype CompactLeading: View = EmptyView
    associatedtype CompactTrailing: View = EmptyView
    associatedtype Minimal: View = EmptyView
    associatedtype Expanded: View = EmptyView
    associatedtype Banner: View = EmptyView

    /// Shared by every presentation; the extension runs as a single process.
    var controller: NotchActivityController { get }

    @ViewBuilder var compactLeading: CompactLeading { get }
    @ViewBuilder var compactTrailing: CompactTrailing { get }
    @ViewBuilder var minimal: Minimal { get }
    @ViewBuilder var expanded: Expanded { get }
    @ViewBuilder var banner: Banner { get }
}

extension NotchActivityExtension where CompactLeading == EmptyView {
    public var compactLeading: EmptyView { EmptyView() }
}

extension NotchActivityExtension where CompactTrailing == EmptyView {
    public var compactTrailing: EmptyView { EmptyView() }
}

extension NotchActivityExtension where Minimal == EmptyView {
    public var minimal: EmptyView { EmptyView() }
}

extension NotchActivityExtension where Expanded == EmptyView {
    public var expanded: EmptyView { EmptyView() }
}

extension NotchActivityExtension where Banner == EmptyView {
    public var banner: EmptyView { EmptyView() }
}

extension NotchActivityExtension {
    public var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(NotchScenes(activity: self), configuration: NotchConnection(controller: controller))
    }
}

/// Reports the activity's state to the notch and follows what the notch shows.
@MainActor
@Observable
public final class NotchActivityController {
    /// Version 1 supports one activity per extension.
    nonisolated static let activityID = "default"

    /// Whether there is something to show. An inactive activity takes no room in the notch.
    public var isActive: Bool {
        didSet {
            if isActive != oldValue { reportState() }
        }
    }

    public var sizes: NotchActivitySizes {
        didSet {
            if sizes != oldValue { reportState() }
        }
    }

    /// The presentations currently on screen; pause work for the others.
    public private(set) var visiblePresentations: Set<NotchScene> = []
    public private(set) var isConnected = false

    @ObservationIgnored private var send: ((ExtensionMessage) -> Void)?

    public init(isActive: Bool = false, sizes: NotchActivitySizes) {
        self.isActive = isActive
        self.sizes = sizes
    }

    /// Shows the banner scene, at `sizes.banner`, for this long.
    public func postBanner(for duration: Duration) {
        let components = duration.components
        let seconds = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
        send?(.postBanner(activityID: Self.activityID, duration: seconds))
    }

    /// Keeps the notch expanded during an interaction that may carry the pointer outside it, such as
    /// dragging a slider. Release it when the interaction ends.
    public func holdOpen(_ held: Bool) {
        send?(.holdOpen(activityID: Self.activityID, held: held))
    }

    func connect(send: @escaping (ExtensionMessage) -> Void) {
        self.send = send
        isConnected = true
        reportState()
    }

    func disconnect() {
        send = nil
        isConnected = false
        visiblePresentations = []
    }

    func handle(_ message: HostMessage) {
        switch message {
        case .hello:
            break
        case .presentationsChanged(let visible):
            visiblePresentations = visible
        }
    }

    private func reportState() {
        send?(.activityChanged(activityID: Self.activityID, isActive: isActive, sizes: sizes))
    }
}

/// One scene per presentation, each with the controller in its environment.
struct NotchScenes<Activity: NotchActivityExtension>: AppExtensionScene {
    let activity: Activity

    @AppExtensionSceneBuilder var body: some AppExtensionScene {
        PrimitiveAppExtensionScene(id: NotchScene.compactLeading.rawValue) {
            activity.compactLeading.environment(activity.controller)
        }
        PrimitiveAppExtensionScene(id: NotchScene.compactTrailing.rawValue) {
            activity.compactTrailing.environment(activity.controller)
        }
        PrimitiveAppExtensionScene(id: NotchScene.minimal.rawValue) {
            activity.minimal.environment(activity.controller)
        }
        PrimitiveAppExtensionScene(id: NotchScene.expanded.rawValue) {
            activity.expanded.environment(activity.controller)
        }
        PrimitiveAppExtensionScene(id: NotchScene.banner.rawValue) {
            activity.banner.environment(activity.controller)
        }
    }
}

/// Accepts Not an Island's connection to the extension process and relays messages both ways.
struct NotchConnection: AppExtensionConfiguration {
    let controller: NotchActivityController

    nonisolated func accept(connection: NSXPCConnection) -> Bool {
        let controller = controller
        connection.exportedInterface = NSXPCInterface(with: NotchMessageChannel.self)
        connection.exportedObject = NotchMessageReceiver { data in
            guard let message = try? NotchWire.decode(HostMessage.self, from: data) else { return }
            Task { @MainActor in controller.handle(message) }
        }
        connection.remoteObjectInterface = NSXPCInterface(with: NotchMessageChannel.self)
        connection.invalidationHandler = {
            Task { @MainActor in controller.disconnect() }
        }
        connection.resume()
        let host = NotchMessageSender(connection: connection)
        Task { @MainActor in
            controller.connect { message in host.send(message) }
        }
        return true
    }
}

/// Receives the other side's messages on XPC's queue.
final class NotchMessageReceiver: NSObject, NotchMessageChannel, Sendable {
    private let handler: @Sendable (Data) -> Void

    init(_ handler: @escaping @Sendable (Data) -> Void) {
        self.handler = handler
    }

    func receive(_ message: Data) {
        handler(message)
    }
}

/// Sends messages over an XPC connection. NSXPCConnection and its proxies are thread-safe,
/// which the compiler can't see.
final class NotchMessageSender: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func send<Message: Codable>(_ message: Message) {
        guard let data = try? NotchWire.encode(message),
              let proxy = connection.remoteObjectProxy as? NotchMessageChannel
        else { return }
        proxy.receive(data)
    }
}
