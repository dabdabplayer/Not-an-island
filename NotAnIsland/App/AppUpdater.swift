import Foundation
import Sparkle

/// Checks the latest GitHub release's appcast and installs signed updates, through Sparkle's standard dialogs.
@MainActor
@Observable
final class AppUpdater {
    private(set) var isStarted = false
    private(set) var canCheckForUpdates = false
    /// A scheduled update waiting for the person. Shown in Settings, because with no Dock icon
    /// Sparkle's alert can open unnoticed behind other windows.
    private(set) var availableUpdate: String?

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    @ObservationIgnored private let reminders = UpdateReminders()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: reminders)
        reminders.updater = self
    }

    /// Starts scheduled checks. Sparkle asks the person whether to check automatically on the second launch.
    func start() {
        guard !isStarted else { return }
        controller.startUpdater()
        isStarted = true
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // Sparkle changes this on the main thread.
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Checks now, or brings an update that was already found back into focus.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updateWillBeShown(version: String, userInitiated: Bool) {
        availableUpdate = userInitiated ? nil : version
    }

    func updateSessionEnded() {
        availableUpdate = nil
    }
}

/// Sparkle's user driver delegate. Sparkle calls it on the main thread, which `@preconcurrency` checks at run time.
@MainActor
private final class UpdateReminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    weak var updater: AppUpdater?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updater?.updateWillBeShown(version: update.displayVersionString, userInitiated: state.userInitiated)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updater?.updateSessionEnded()
    }

    func standardUserDriverWillFinishUpdateSession() {
        updater?.updateSessionEnded()
    }
}
