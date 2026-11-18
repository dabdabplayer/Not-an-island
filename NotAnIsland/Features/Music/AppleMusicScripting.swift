import AppKit
import CoreServices
import ImageIO
import os

func fourCharCode(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}

struct AppleEventError: Error, Equatable {
    static let notPermitted = -1743
    static let noSuchObject = -1728
    static let coercionFailed = -1700

    let code: Int
}

struct UndecodableArtworkError: Error {}

enum MusicAutomationPermission: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case unavailable
}

enum MusicCommand: Equatable, Sendable {
    case playPause
    case nextTrack
    /// Music's ⏮ behaviour: restart the track, or go to the previous one if already at the start.
    case backTrack

    var eventID: FourCharCode {
        switch self {
        case .playPause: fourCharCode("PlPs")
        case .nextTrack: fourCharCode("Next")
        case .backTrack: fourCharCode("Back")
        }
    }
}

/// Music's scriptable interface. Every call targets an already running Music process,
/// so nothing here can launch Music.
protocol MusicScripting: Sendable {
    /// Asking may show the system Automation prompt and wait for the user's answer.
    func permission(processID: pid_t, askUser: Bool) async -> MusicAutomationPermission
    func playerInfo(processID: pid_t) async throws -> MusicPlayerInfo
    func playerPosition(processID: pid_t) async throws -> TimeInterval
    func artwork(processID: pid_t, maxPixelSize: Int) async throws -> CGImage?
    func perform(_ command: MusicCommand, processID: pid_t) async throws
    func setPlayerPosition(_ position: TimeInterval, processID: pid_t) async throws
}

/// Builds Apple Events using the codes in Music's scripting dictionary (`sdef /System/Applications/Music.app`).
enum AppleMusicEvents {
    static func currentTrack() throws -> NSAppleEventDescriptor {
        try property("pTrk", of: .null())
    }

    static func property(_ code: String, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(want: "prop", form: "prop", selector: NSAppleEventDescriptor(typeCode: fourCharCode(code)), container: container)
    }

    static func element(_ classCode: String, index: Int32, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(want: classCode, form: "indx", selector: NSAppleEventDescriptor(int32: index), container: container)
    }

    static func event(class eventClass: String, id eventID: FourCharCode, processID: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: fourCharCode(eventClass),
            eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processID),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    /// An object specifier is an Apple Event record coerced to `typeObjectSpecifier`.
    private static func specifier(
        want: String,
        form: String,
        selector: NSAppleEventDescriptor,
        container: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode(want)), forKeyword: fourCharCode("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCharCode(form)), forKeyword: fourCharCode("form"))
        record.setDescriptor(selector, forKeyword: fourCharCode("seld"))
        record.setDescriptor(container, forKeyword: fourCharCode("from"))
        guard let specifier = record.coerce(toDescriptorType: fourCharCode("obj ")) else {
            throw AppleEventError(code: AppleEventError.coercionFailed)
        }
        return specifier
    }
}

/// Talks to Music over Apple Events on a private serial queue: sending blocks until Music replies,
/// and asking for permission blocks until the user answers.
final class AppleMusicScripting: MusicScripting {
    /// Without a timeout, an unresponsive Music would block each event for two minutes.
    private static let timeout: TimeInterval = 2
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "Music")

    private let queue = DispatchQueue(label: "app.arysha.NotAnIsland.music-scripting")

    func permission(processID: pid_t, askUser: Bool) async -> MusicAutomationPermission {
        await withCheckedContinuation { continuation in
            queue.async {
                let target = NSAppleEventDescriptor(processIdentifier: processID)
                guard let address = target.aeDesc else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                let wildcard = fourCharCode("****")
                let status = AEDeterminePermissionToAutomateTarget(address, wildcard, wildcard, askUser)
                let permission: MusicAutomationPermission = switch Int(status) {
                case Int(noErr): .granted
                case AppleEventError.notPermitted: .denied
                case Int(errAEEventWouldRequireUserConsent): .notDetermined
                default: .unavailable
                }
                if permission == .unavailable {
                    Self.logger.error("Couldn't determine Automation permission for Music: OSStatus \(status, privacy: .public)")
                }
                continuation.resume(returning: permission)
            }
        }
    }

    func playerInfo(processID: pid_t) async throws -> MusicPlayerInfo {
        try await run {
            let stateCode = try Self.get(AppleMusicEvents.property("pPlS", of: .null()), processID: processID).enumCodeValue
            let state: MusicPlayerInfo.State = switch stateCode {
            case fourCharCode("kPSS"): .stopped
            case fourCharCode("kPSp"): .paused
            // Playing, fast-forwarding and rewinding all mean the track is moving.
            default: .playing
            }
            guard state != .stopped else { return MusicPlayerInfo(state: .stopped) }

            let track = try AppleMusicEvents.currentTrack()
            func value(_ code: String) throws -> NSAppleEventDescriptor {
                try Self.get(AppleMusicEvents.property(code, of: track), processID: processID)
            }
            return MusicPlayerInfo(
                state: state,
                persistentID: try value("pPIS").stringValue.flatMap(MusicPlayerInfo.persistentID(fromHex:)),
                name: try value("pnam").stringValue,
                artist: try value("pArt").stringValue,
                album: try value("pAlb").stringValue,
                duration: try value("pDur").doubleValue
            )
        }
    }

    func playerPosition(processID: pid_t) async throws -> TimeInterval {
        try await run {
            try Self.get(AppleMusicEvents.property("pPos", of: .null()), processID: processID).doubleValue
        }
    }

    func artwork(processID: pid_t, maxPixelSize: Int) async throws -> CGImage? {
        try await run {
            let artwork = try AppleMusicEvents.element("cArt", index: 1, of: AppleMusicEvents.currentTrack())
            let data: Data
            do {
                data = try Self.get(AppleMusicEvents.property("pRaw", of: artwork), processID: processID).data
            } catch let error as AppleEventError where error.code == AppleEventError.noSuchObject {
                return nil  // The track has no artwork.
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  ] as CFDictionary)
            else {
                throw UndecodableArtworkError()
            }
            return image
        }
    }

    func perform(_ command: MusicCommand, processID: pid_t) async throws {
        try await run {
            _ = try Self.send(AppleMusicEvents.event(class: "hook", id: command.eventID, processID: processID))
        }
    }

    func setPlayerPosition(_ position: TimeInterval, processID: pid_t) async throws {
        try await run {
            let event = AppleMusicEvents.event(class: "core", id: fourCharCode("setd"), processID: processID)
            event.setParam(try AppleMusicEvents.property("pPos", of: .null()), forKeyword: fourCharCode("----"))
            event.setParam(NSAppleEventDescriptor(double: position), forKeyword: fourCharCode("data"))
            _ = try Self.send(event)
        }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func get(_ specifier: NSAppleEventDescriptor, processID: pid_t) throws -> NSAppleEventDescriptor {
        let event = AppleMusicEvents.event(class: "core", id: fourCharCode("getd"), processID: processID)
        event.setParam(specifier, forKeyword: fourCharCode("----"))
        guard let value = try send(event) else {
            throw AppleEventError(code: AppleEventError.noSuchObject)
        }
        return value
    }

    /// Returns the reply's direct result, surfacing both send failures and errors Music reports in its reply.
    private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
        } catch let error as NSError {
            throw AppleEventError(code: error.code)
        }
        if let code = reply.paramDescriptor(forKeyword: fourCharCode("errn"))?.int32Value, code != 0 {
            throw AppleEventError(code: Int(code))
        }
        return reply.paramDescriptor(forKeyword: fourCharCode("----"))
    }
}
