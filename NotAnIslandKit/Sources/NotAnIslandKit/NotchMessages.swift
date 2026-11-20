import CoreGraphics
import Foundation

/// The presentations an extension can provide. Each is a scene with this ID, drawn at the fixed
/// size the extension declares; the notch animates around it and never resizes it mid-animation.
public enum NotchScene: String, CaseIterable, Codable, Sendable {
    /// Left of the camera while the activity owns the compact wings.
    case compactLeading = "compact-leading"
    /// Right of the camera while the activity owns the compact wings.
    case compactTrailing = "compact-trailing"
    /// The bubble beside the wings while another activity owns them.
    case minimal
    /// The activity's section of the expanded notch.
    case expanded
    /// A brief banner below the camera.
    case banner
}

/// How much room each presentation needs. A nil size means the extension doesn't offer that presentation.
/// The host caps every size to what fits in the notch.
public struct NotchActivitySizes: Codable, Equatable, Sendable {
    public var compactSideWidth: CGFloat?
    public var expanded: CGSize?
    public var minimal: CGSize?
    public var banner: CGSize?

    public init(compactSideWidth: CGFloat? = nil, expanded: CGSize? = nil, minimal: CGSize? = nil, banner: CGSize? = nil) {
        self.compactSideWidth = compactSideWidth
        self.expanded = expanded
        self.minimal = minimal
        self.banner = banner
    }
}

/// Sent from an extension to Not an Island. Every message names its activity; version 1 supports
/// one activity per extension, and the ID leaves room for more without breaking extensions.
public enum ExtensionMessage: Codable, Equatable, Sendable {
    case activityChanged(activityID: String, isActive: Bool, sizes: NotchActivitySizes)
    /// Shows the banner scene for this long, at the banner size last declared.
    case postBanner(activityID: String, duration: TimeInterval)
    /// Keeps the notch expanded during an interaction that may leave it, such as dragging a slider.
    case holdOpen(activityID: String, held: Bool)
}

/// Sent from Not an Island to an extension.
public enum HostMessage: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int)
    /// Which presentations are on screen, so the extension can pause work nobody can see.
    case presentationsChanged(visible: Set<NotchScene>)
}

/// The versioned wire format both sides use.
public enum NotchWire {
    /// Bumped only for changes old peers can't understand; additions keep the same major version.
    public static let majorVersion = 1
    public static let extensionPointID = "app.arysha.NotAnIsland.activity"

    public enum Error: Swift.Error, Equatable {
        case newerVersion(Int)
    }

    private struct Envelope<Message: Codable>: Codable {
        let major: Int
        let message: Message
    }

    private struct Header: Decodable {
        let major: Int
    }

    public static func encode<Message: Codable>(_ message: Message) throws -> Data {
        try JSONEncoder().encode(Envelope(major: majorVersion, message: message))
    }

    public static func decode<Message: Codable>(_ type: Message.Type, from data: Data) throws -> Message {
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.major <= majorVersion else { throw Error.newerVersion(header.major) }
        return try JSONDecoder().decode(Envelope<Message>.self, from: data).message
    }
}

/// The XPC interface both sides export: each sends encoded messages to the other's `receive`.
@objc public protocol NotchMessageChannel {
    func receive(_ message: Data)
}
