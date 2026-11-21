import Foundation
import Testing
@testable import NotAnIsland

// The tests run inside the app, so Bundle.main is the shipped Info.plist.
struct UpdateConfigurationTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    // Sparkle compares build numbers. If they stopped following the version, no one would be offered an update.
    @Test func buildNumberIsTheVersion() throws {
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        #expect(info["CFBundleVersion"] as? String == version)
    }

    @Test func feedIsTheLatestReleasesAppcast() {
        #expect(info["SUFeedURL"] as? String == "https://github.com/dabdabplayer/Not-an-island/releases/latest/download/appcast.xml")
    }

    @Test func updatesMustBeSignedWithTheProjectsKey() {
        #expect(info["SUPublicEDKey"] as? String == "X+jfuXOqRakX9dq63RlPiVjC5q2XUcTAvfqeRj6331Y=")
    }
}

@MainActor
struct AppUpdaterTests {
    // Tests run inside the app; a started updater would check the network and could show its dialogs.
    @Test func doesNotCheckUntilStarted() {
        let updater = AppUpdater()
        #expect(!updater.isStarted)
        #expect(!updater.canCheckForUpdates)
    }

    // With no Dock icon, a scheduled update's alert can sit unseen behind other windows.
    @Test func scheduledUpdateIsAlsoShownInSettings() {
        let updater = AppUpdater()
        updater.updateWillBeShown(version: "0.1.2", userInitiated: false)
        #expect(updater.availableUpdate == "0.1.2")
    }

    @Test func checkingByHandNeedsNoReminder() {
        let updater = AppUpdater()
        updater.updateWillBeShown(version: "0.1.2", userInitiated: true)
        #expect(updater.availableUpdate == nil)
    }

    @Test func reminderClearsOnceThePersonDealsWithTheUpdate() {
        let updater = AppUpdater()
        updater.updateWillBeShown(version: "0.1.2", userInitiated: false)
        updater.updateSessionEnded()
        #expect(updater.availableUpdate == nil)
    }
}
