import AppKit
import SwiftUI

@main
struct NotAnIslandApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // SwiftUI requires at least one scene; the notch itself is an AppKit panel owned by Core.
        Settings {
            SettingsView(activities: appDelegate.activities, priority: appDelegate.priority)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let moments = NotchMoments()
    private let music = MusicActivity()
    private lazy var system = SystemActivity(moments: moments)
    private lazy var bluetooth = BluetoothMonitor(moments: moments)
    let priority = ActivityPriority()
    private(set) lazy var activities = NotchActivities(builtIns)
    private var builtIns: [any NotchActivity] { [music, system] }
    private lazy var notchController = NotchWindowController(activities: activities, moments: moments)
    private let extensionDiscovery = ExtensionDiscovery()
    private var extensions: [String: InstalledExtension] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests build their own objects. Started here, the live features would ask for Bluetooth
        // access, which blocks launch on a CI machine with nobody to answer. Set by the scheme's Test action.
        guard ProcessInfo.processInfo.environment["NOT_AN_ISLAND_HOSTING_TESTS"] == nil else { return }
        notchController.start()
        music.start()
        system.start()
        bluetooth.start()
        extensionDiscovery.start()
        updateActivities()
    }

    /// Keeps the notch's activities in step with the enabled extensions and the user's order.
    /// Each extension keeps its process and connected views for as long as it stays enabled.
    private func updateActivities() {
        let (identities, _) = withObservationTracking {
            (extensionDiscovery.identities, priority.order)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateActivities() }
        }
        let enabled = Set(identities.map(\.bundleIdentifier))
        for (id, installed) in extensions where !enabled.contains(id) {
            installed.session.stop()
            extensions[id] = nil
        }
        for identity in identities where extensions[identity.bundleIdentifier] == nil {
            let installed = InstalledExtension(identity: identity, moments: moments) { [weak self] held in
                self?.notchController.setHeldOpen(held)
            }
            extensions[identity.bundleIdentifier] = installed
            Task { await installed.session.start() }
        }
        let available = builtIns + identities.compactMap { extensions[$0.bundleIdentifier]?.activity as (any NotchActivity)? }
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        activities.ordered = priority.ordered(available.map(\.id)).compactMap { byID[$0] }
    }

    // With no Dock icon, opening the app again is the only way back after "Hide Not an Island".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.unhide(nil)
        return true
    }
}
