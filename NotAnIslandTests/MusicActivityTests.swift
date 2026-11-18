import AppKit
import Testing
@testable import NotAnIsland

/// Payloads recorded from Music's `com.apple.Music.playerInfo` broadcast on macOS 27.2.
enum MusicPayloads {
    static var playing: [AnyHashable: Any] {[
        "Album": "AUJLA SZN 1 - EP",
        "Artist": "Karan Aujla",
        "Composer": "Karan Aujla",
        "Genre": "Hip-Hop/Rap",
        "Library PersistentID": NSNumber(value: 6721994131125808035 as Int64),
        "Name": "Real Bad Man",
        "PersistentID": NSNumber(value: 8319969024022341699 as Int64),
        "Player State": "Playing",
        "Total Time": NSNumber(value: 169000),
    ]}
    static var stopped: [AnyHashable: Any] { ["Player State": "Stopped"] }

    static func with(state: String) -> [AnyHashable: Any] {
        var payload = playing
        payload["Player State"] = state
        return payload
    }
}

struct MusicPlayerInfoTests {
    @Test func parsesPlayingPayload() throws {
        let info = try #require(MusicPlayerInfo(userInfo: MusicPayloads.playing))

        #expect(info.state == .playing)
        #expect(info.name == "Real Bad Man")
        #expect(info.artist == "Karan Aujla")
        #expect(info.album == "AUJLA SZN 1 - EP")
        #expect(info.duration == 169)
        #expect(info.persistentID == 8319969024022341699)
    }

    @Test func stoppedPayloadHasNoTrack() throws {
        let info = try #require(MusicPlayerInfo(userInfo: MusicPayloads.stopped))

        #expect(info.state == .stopped)
        #expect(info.name == nil)
        #expect(info.persistentID == nil)
    }

    @Test func unrecognisedStateIsRejected() {
        #expect(MusicPlayerInfo(userInfo: MusicPayloads.with(state: "Rewinding")) == nil)
        #expect(MusicPlayerInfo(userInfo: [:]) == nil)
    }

    // Music's scripting dictionary reports the same ID as a hexadecimal string.
    @Test func persistentIDMatchesScriptingHexForm() {
        #expect(MusicPlayerInfo.persistentID(fromHex: "737677BF0B1AE843") == 8319969024022341699)
    }

    // Recorded live: the broadcast sends IDs as signed 64-bit numbers, so some arrive negative.
    @Test func negativeBroadcastIDKeepsItsBitPattern() throws {
        var payload = MusicPayloads.playing
        payload["PersistentID"] = NSNumber(value: -864073863381644030 as Int64)
        let info = try #require(MusicPlayerInfo(userInfo: payload))

        #expect(info.persistentID == MusicPlayerInfo.persistentID(fromHex: "F402316639700D02"))
    }
}

struct PlaybackPositionTests {
    private let anchor = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func advancesWhilePlaying() {
        let playback = PlaybackPosition(position: 30, anchor: anchor, isPlaying: true, duration: 169)
        #expect(playback.position(at: anchor.addingTimeInterval(12)) == 42)
    }

    @Test func holdsStillWhilePaused() {
        let playback = PlaybackPosition(position: 30, anchor: anchor, isPlaying: false, duration: 169)
        #expect(playback.position(at: anchor.addingTimeInterval(12)) == 30)
    }

    @Test func neverRunsPastTheEndOfTheTrack() {
        let playback = PlaybackPosition(position: 160, anchor: anchor, isPlaying: true, duration: 169)
        #expect(playback.position(at: anchor.addingTimeInterval(60)) == 169)
    }
}

/// Stands in for Music's Apple Events interface in tests.
actor FakeMusicScripting: MusicScripting {
    var permissionResult: MusicAutomationPermission = .granted
    var position: TimeInterval = 42
    var info: MusicPlayerInfo?
    private(set) var permissionRequests: [Bool] = []
    private(set) var positionFetches = 0
    private(set) var artworkFetches = 0
    private(set) var commands: [MusicCommand] = []
    private(set) var seeks: [TimeInterval] = []

    func setPermission(_ permission: MusicAutomationPermission) { permissionResult = permission }
    func setInfo(_ info: MusicPlayerInfo?) { self.info = info }

    func permission(processID: pid_t, askUser: Bool) async -> MusicAutomationPermission {
        permissionRequests.append(askUser)
        return permissionResult
    }

    func playerInfo(processID: pid_t) async throws -> MusicPlayerInfo {
        guard let info else { throw AppleEventError(code: -1728) }
        return info
    }

    func playerPosition(processID: pid_t) async throws -> TimeInterval {
        positionFetches += 1
        return position
    }

    func artwork(processID: pid_t, maxPixelSize: Int) async throws -> CGImage? {
        artworkFetches += 1
        return nil
    }

    func perform(_ command: MusicCommand, processID: pid_t) async throws {
        commands.append(command)
    }

    func setPlayerPosition(_ position: TimeInterval, processID: pid_t) async throws {
        seeks.append(position)
    }
}

@MainActor
struct MusicActivityTests {
    private let scripting = FakeMusicScripting()
    private let now = Date(timeIntervalSinceReferenceDate: 5000)

    private final class SleepRecorder {
        var delays: [Duration] = []
    }

    private let sleeps = SleepRecorder()

    /// Sleeps return immediately; tests await `pendingIdle` instead of the wall clock.
    private func makeActivity(musicRunning: Bool = true) -> MusicActivity {
        let now = now
        let sleeps = sleeps
        return MusicActivity(
            scripting: scripting,
            musicProcessID: { musicRunning ? 4242 : nil },
            now: { now },
            sleep: { sleeps.delays.append($0) }
        )
    }

    @Test func playingTrackBecomesActiveWithPositionAndArtwork() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.playing)
        await activity.pendingRefresh?.value

        #expect(activity.isActive)
        #expect(activity.isPlaying)
        #expect(activity.info?.name == "Real Bad Man")
        #expect(activity.permission == .granted)
        #expect(activity.playback == PlaybackPosition(position: 42, anchor: now, isPlaying: true, duration: 169))
        #expect(await scripting.permissionRequests == [true])
        #expect(await scripting.artworkFetches == 1)
    }

    @Test func pausingTheSameTrackDoesNotRefetchArtwork() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.playing)
        await activity.pendingRefresh?.value
        activity.handlePlayerInfo(MusicPayloads.with(state: "Paused"))
        await activity.pendingRefresh?.value

        #expect(activity.isActive)
        #expect(!activity.isPlaying)
        #expect(activity.playback?.isPlaying == false)
        #expect(await scripting.artworkFetches == 1)
        #expect(await scripting.positionFetches == 2)
    }

    @Test func stoppingClearsTheActivity() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.playing)
        await activity.pendingRefresh?.value
        activity.handlePlayerInfo(MusicPayloads.stopped)

        #expect(!activity.isActive)
        #expect(activity.info == nil)
        #expect(activity.playback == nil)
    }

    @Test func musicQuittingClearsTheActivity() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.playing)
        await activity.pendingRefresh?.value
        activity.musicDidQuit()

        #expect(!activity.isActive)
        #expect(activity.info == nil)
    }

    // Track details come from the broadcast, which needs no permission; only position,
    // artwork and controls need Automation access.
    @Test func deniedAutomationStillShowsTrackDetails() async {
        await scripting.setPermission(.denied)
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.playing)
        await activity.pendingRefresh?.value

        #expect(activity.isActive)
        #expect(activity.info?.name == "Real Bad Man")
        #expect(activity.permission == .denied)
        #expect(activity.playback == nil)
        #expect(await scripting.positionFetches == 0)
        #expect(await scripting.artworkFetches == 0)
    }

    @Test func neverTalksToMusicWhenItIsNotRunning() async {
        let activity = makeActivity(musicRunning: false)
        activity.handlePlayerInfo(MusicPayloads.playing)
        await activity.pendingRefresh?.value

        #expect(await scripting.permissionRequests.isEmpty)
        #expect(await scripting.positionFetches == 0)
    }

    @Test func seekingMovesTheProgressImmediately() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.playing)
        await activity.pendingRefresh?.value
        activity.seek(to: 100)
        await activity.pendingCommand?.value

        #expect(activity.playback?.position(at: now) == 100)
        #expect(await scripting.seeks == [100])
    }

    @Test func controlsSendTheMatchingCommands() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.playing)
        await activity.pendingRefresh?.value

        activity.playPause()
        await activity.pendingCommand?.value
        activity.nextTrack()
        await activity.pendingCommand?.value
        activity.previousTrack()
        await activity.pendingCommand?.value

        #expect(await scripting.commands == [.playPause, .nextTrack, .backTrack])
    }

    // At launch, Music may already be playing; nothing is broadcast until something changes.
    // Asking is deferred until music is actually shown, so launch never triggers a permission prompt.
    @Test func launchPicksUpCurrentPlaybackWithoutPrompting() async throws {
        let current = try #require(MusicPlayerInfo(userInfo: MusicPayloads.playing))
        await scripting.setInfo(current)
        let activity = makeActivity()
        await activity.loadInitialState()
        await activity.pendingRefresh?.value

        #expect(activity.isActive)
        #expect(activity.info?.name == "Real Bad Man")
        #expect(await scripting.permissionRequests.first == false)
    }

    @Test func launchWithoutPermissionWaitsForTheNextBroadcast() async throws {
        await scripting.setPermission(.notDetermined)
        let current = try #require(MusicPlayerInfo(userInfo: MusicPayloads.playing))
        await scripting.setInfo(current)
        let activity = makeActivity()
        await activity.loadInitialState()

        #expect(!activity.isActive)
        #expect(await scripting.permissionRequests == [false])
    }
}

@MainActor
struct MusicIdleTests {
    private let scripting = FakeMusicScripting()

    private final class SleepRecorder {
        var delays: [Duration] = []
    }

    private let sleeps = SleepRecorder()

    private func makeActivity() -> MusicActivity {
        let sleeps = sleeps
        return MusicActivity(
            scripting: scripting,
            musicProcessID: { 4242 },
            now: { Date(timeIntervalSinceReferenceDate: 0) },
            sleep: { sleeps.delays.append($0) }
        )
    }

    @Test func playingIsNeverIdle() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.playing)
        await activity.pendingIdle?.value

        #expect(!activity.isIdle)
        #expect(activity.metrics.compactSideWidth == MusicActivity.activeSideWidth)
    }

    @Test func pausedMusicGoesIdleAfterTheDelay() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.with(state: "Paused"))

        #expect(!activity.isIdle)
        await activity.pendingIdle?.value

        #expect(activity.isIdle)
        #expect(sleeps.delays == [MusicActivity.idleDelay])
        #expect(activity.metrics.compactSideWidth == MusicActivity.idleSideWidth)
        #expect(MusicActivity.idleSideWidth < MusicActivity.activeSideWidth)
    }

    @Test func idleDelayIsBetweenTwoAndThreeSeconds() {
        #expect(MusicActivity.idleDelay >= .seconds(2))
        #expect(MusicActivity.idleDelay <= .seconds(3))
    }

    @Test func resumingBeforeTheDelayCancelsIdle() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.with(state: "Paused"))
        let cancelled = activity.pendingIdle
        activity.handlePlayerInfo(MusicPayloads.playing)
        await cancelled?.value

        #expect(!activity.isIdle)
    }

    @Test func resumingWakesAnIdleNotch() async {
        let activity = makeActivity()
        activity.handlePlayerInfo(MusicPayloads.with(state: "Paused"))
        await activity.pendingIdle?.value
        activity.handlePlayerInfo(MusicPayloads.playing)

        #expect(!activity.isIdle)
        #expect(activity.metrics.compactSideWidth == MusicActivity.activeSideWidth)
    }
}

struct AppleMusicEventTests {
    @Test func propertyOfCurrentTrackIsAnObjectSpecifier() throws {
        let specifier = try AppleMusicEvents.property("pnam", of: AppleMusicEvents.currentTrack())

        #expect(specifier.descriptorType == fourCharCode("obj "))
        let record = try #require(specifier.coerce(toDescriptorType: fourCharCode("reco")))
        #expect(record.forKeyword(fourCharCode("want"))?.typeCodeValue == fourCharCode("prop"))
        #expect(record.forKeyword(fourCharCode("seld"))?.typeCodeValue == fourCharCode("pnam"))
        #expect(record.forKeyword(fourCharCode("from"))?.descriptorType == fourCharCode("obj "))
    }

    @Test func commandsUseMusicDictionaryCodes() {
        #expect(MusicCommand.playPause.eventID == fourCharCode("PlPs"))
        #expect(MusicCommand.nextTrack.eventID == fourCharCode("Next"))
        #expect(MusicCommand.backTrack.eventID == fourCharCode("Back"))
    }
}
