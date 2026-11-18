import AppKit
import os
import SwiftUI

/// Music's player state and current track, from its `com.apple.Music.playerInfo` broadcast
/// or from its scripting interface.
struct MusicPlayerInfo: Equatable, Sendable {
    enum State: String, Sendable {
        case playing = "Playing"
        case paused = "Paused"
        case stopped = "Stopped"
    }

    var state: State
    var persistentID: UInt64?
    var name: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval?

    init(
        state: State,
        persistentID: UInt64? = nil,
        name: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.state = state
        self.persistentID = persistentID
        self.name = name
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// Returns nil for payloads without a recognised player state.
    init?(userInfo: [AnyHashable: Any]) {
        guard let rawState = userInfo["Player State"] as? String, let state = State(rawValue: rawState) else { return nil }
        self.init(
            state: state,
            persistentID: (userInfo["PersistentID"] as? NSNumber)?.uint64Value,
            name: userInfo["Name"] as? String,
            artist: userInfo["Artist"] as? String,
            album: userInfo["Album"] as? String,
            duration: (userInfo["Total Time"] as? NSNumber).map { $0.doubleValue / 1000 }
        )
    }

    /// The broadcast sends the ID as a number; the scripting interface as a hexadecimal string.
    static func persistentID(fromHex hex: String) -> UInt64? {
        UInt64(hex, radix: 16)
    }
}

/// A known playback position, advanced locally while playing so progress needs no polling.
struct PlaybackPosition: Equatable, Sendable {
    var position: TimeInterval
    var anchor: Date
    var isPlaying: Bool
    var duration: TimeInterval?

    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let advanced = position + date.timeIntervalSince(anchor)
        return duration.map { min(advanced, $0) } ?? advanced
    }
}

/// Shows and controls what's playing in Music.
@MainActor
@Observable
final class MusicActivity: NSObject, NotchActivity {
    nonisolated static let bundleIdentifier = "com.apple.Music"
    private static let playerInfoNotification = Notification.Name("com.apple.Music.playerInfo")
    private static let artworkPixelSize = 160
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "Music")

    /// How long music must stay paused before the compact notch dims and narrows.
    nonisolated static let idleDelay: Duration = .milliseconds(2500)
    nonisolated static let activeSideWidth: CGFloat = 36
    nonisolated static let idleSideWidth: CGFloat = 28
    nonisolated static let expandedWidth: CGFloat = 380
    nonisolated static let expandedHeight: CGFloat = 140
    nonisolated static let outputRowHeight: CGFloat = 30
    nonisolated static let maxVisibleOutputRows = 4
    nonisolated static let outputPickerSpacing: CGFloat = 8
    /// Used until artwork arrives, and for tracks without any.
    private static let neutralColors: [NSColor] = [.white, NSColor(white: 0.75, alpha: 1)]

    private(set) var info: MusicPlayerInfo?
    private(set) var playback: PlaybackPosition?
    private(set) var artwork: CGImage?
    /// Colours for the waveform bars' gradient, taken from the artwork.
    private(set) var artworkColors: [NSColor] = MusicActivity.neutralColors
    private(set) var permission: MusicAutomationPermission = .notDetermined
    /// Paused long enough that the compact notch steps back.
    private(set) var isIdle = false
    private(set) var isOutputPickerOpen = false
    /// Where the sound plays; the expanded notch lets the user switch it.
    @ObservationIgnored let outputs: AudioOutputs

    @ObservationIgnored private(set) var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private(set) var pendingCommand: Task<Void, Never>?
    @ObservationIgnored private(set) var pendingIdle: Task<Void, Never>?
    @ObservationIgnored private var artworkTrackID: UInt64?
    @ObservationIgnored private let scripting: any MusicScripting
    @ObservationIgnored private let musicProcessID: @MainActor () -> pid_t?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async throws -> Void

    var isActive: Bool { info.map { $0.state != .stopped } ?? false }
    var isPlaying: Bool { info?.state == .playing }

    var metrics: NotchActivityMetrics {
        NotchActivityMetrics(
            compactSideWidth: isIdle ? Self.idleSideWidth : Self.activeSideWidth,
            expandedSectionSize: CGSize(
                width: Self.expandedWidth,
                height: Self.expandedHeight + (isOutputPickerOpen ? Self.outputPickerHeight(rows: outputs.devices.count) : 0)
            )
        )
    }

    /// The extra room the output list takes below the controls; long lists scroll.
    nonisolated static func outputPickerHeight(rows: Int) -> CGFloat {
        outputPickerSpacing + CGFloat(min(max(rows, 1), maxVisibleOutputRows)) * outputRowHeight
    }

    init(
        scripting: any MusicScripting = AppleMusicScripting(),
        musicProcessID: @escaping @MainActor () -> pid_t? = {
            NSRunningApplication.runningApplications(withBundleIdentifier: MusicActivity.bundleIdentifier)
                .first?.processIdentifier
        },
        outputs: AudioOutputs = AudioOutputs(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.scripting = scripting
        self.outputs = outputs
        self.musicProcessID = musicProcessID
        self.now = now
        self.sleep = sleep
        super.init()
    }

    func start() {
        // This agent app is never active, and AppKit holds back distributed notifications for inactive apps.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playerInfoDidChange(_:)),
            name: Self.playerInfoNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        outputs.start()
        Task { await loadInitialState() }
    }

    @objc private func playerInfoDidChange(_ notification: Notification) {
        handlePlayerInfo(notification.userInfo ?? [:])
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if application?.bundleIdentifier == Self.bundleIdentifier {
            musicDidQuit()
        }
    }

    func handlePlayerInfo(_ userInfo: [AnyHashable: Any]) {
        guard let update = MusicPlayerInfo(userInfo: userInfo) else {
            let state = String(describing: userInfo["Player State"])
            Self.logger.error("Ignoring Music broadcast with unrecognised player state: \(state, privacy: .public)")
            return
        }
        // Music is now being shown, so this is the moment to ask for Automation access if needed.
        apply(update, askForPermission: true)
    }

    func musicDidQuit() {
        apply(MusicPlayerInfo(state: .stopped), askForPermission: false)
    }

    /// Music may already be playing at launch, and it broadcasts nothing until something changes.
    /// Only reads Music if access was granted before, so launching never shows a permission prompt.
    func loadInitialState() async {
        guard let processID = musicProcessID() else { return }
        permission = await scripting.permission(processID: processID, askUser: false)
        guard permission == .granted else { return }
        do {
            apply(try await scripting.playerInfo(processID: processID), askForPermission: false)
        } catch {
            report(error, while: "reading Music's current track")
        }
    }

    // MARK: Controls

    func playPause() {
        send(.playPause)
    }

    func nextTrack() {
        send(.nextTrack)
    }

    func previousTrack() {
        send(.backTrack)
    }

    func seek(to position: TimeInterval) {
        guard let processID = musicProcessID(), let current = playback else { return }
        playback = PlaybackPosition(position: position, anchor: now(), isPlaying: current.isPlaying, duration: current.duration)
        let scripting = scripting
        pendingCommand = Task {
            do {
                try await scripting.setPlayerPosition(position, processID: processID)
            } catch {
                report(error, while: "seeking in Music")
            }
        }
    }

    func toggleOutputPicker() {
        isOutputPickerOpen.toggle()
    }

    func selectOutput(_ device: AudioOutputDevice) {
        outputs.select(device)
        isOutputPickerOpen = false
    }

    // MARK: NotchActivity

    func compactLeadingView() -> AnyView {
        AnyView(MusicCompactArtwork(music: self))
    }

    func compactTrailingView() -> AnyView {
        AnyView(MusicCompactVisualizer(music: self))
    }

    func expandedView() -> AnyView {
        AnyView(MusicExpandedView(music: self))
    }

    func notchDidChangeExpansion(_ isExpanded: Bool) {
        if !isExpanded {
            isOutputPickerOpen = false
        }
        // Correct any drift in the locally advanced position whenever the progress becomes visible.
        if isExpanded, isActive, permission == .granted {
            refresh(askForPermission: false, includeArtwork: false)
        }
    }

    // MARK: Private

    private func apply(_ update: MusicPlayerInfo, askForPermission: Bool) {
        updateIdle(for: update.state)
        guard update.state != .stopped else {
            info = nil
            playback = nil
            artwork = nil
            artworkColors = Self.neutralColors
            artworkTrackID = nil
            return
        }

        let trackChanged = update.persistentID != info?.persistentID
        info = update
        if trackChanged {
            playback = nil
            artwork = nil
            artworkColors = Self.neutralColors
        } else if let current = playback {
            let date = now()
            playback = PlaybackPosition(
                position: current.position(at: date),
                anchor: date,
                isPlaying: update.state == .playing,
                duration: update.duration
            )
        }
        refresh(askForPermission: askForPermission, includeArtwork: artworkTrackID != update.persistentID)
    }

    private func updateIdle(for state: MusicPlayerInfo.State) {
        pendingIdle?.cancel()
        pendingIdle = nil
        guard state == .paused else {
            isIdle = false
            return
        }
        guard !isIdle else { return }
        let sleep = sleep
        pendingIdle = Task {
            do {
                try await sleep(Self.idleDelay)
            } catch {
                return  // Cancelled because playback resumed or stopped.
            }
            guard !Task.isCancelled, info?.state == .paused else { return }
            isIdle = true
        }
    }

    /// Reads position and, when the track changed, artwork. The broadcast never includes either.
    private func refresh(askForPermission: Bool, includeArtwork: Bool) {
        guard let processID = musicProcessID() else { return }
        let trackID = info?.persistentID
        let scripting = scripting
        pendingRefresh = Task {
            permission = await scripting.permission(processID: processID, askUser: askForPermission)
            guard permission == .granted else { return }
            do {
                let position = try await scripting.playerPosition(processID: processID)
                guard let info, info.persistentID == trackID else { return }
                playback = PlaybackPosition(
                    position: position,
                    anchor: now(),
                    isPlaying: info.state == .playing,
                    duration: info.duration
                )

                guard includeArtwork else { return }
                let image = try await scripting.artwork(processID: processID, maxPixelSize: Self.artworkPixelSize)
                guard self.info?.persistentID == trackID else { return }
                artwork = image
                artworkColors = image.map(ArtworkPalette.colors(of:)) ?? Self.neutralColors
                let hexColors = artworkColors.map(Self.hex).joined(separator: " ")
                Self.logger.debug("Waveform colours for \(self.info?.name ?? "?", privacy: .public): \(hexColors, privacy: .public)")
                artworkTrackID = trackID
            } catch {
                report(error, while: "reading playback from Music")
            }
        }
    }

    private func send(_ command: MusicCommand) {
        guard let processID = musicProcessID() else { return }
        let scripting = scripting
        pendingCommand = Task {
            do {
                try await scripting.perform(command, processID: processID)
            } catch {
                report(error, while: "sending \(command) to Music")
            }
        }
    }

    private static func hex(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X", Int(srgb.redComponent * 255), Int(srgb.greenComponent * 255), Int(srgb.blueComponent * 255))
    }

    private func report(_ error: any Error, while action: String) {
        if (error as? AppleEventError)?.code == AppleEventError.notPermitted {
            permission = .denied
        }
        Self.logger.error("Failed \(action, privacy: .public): \(String(describing: error), privacy: .public)")
    }
}
