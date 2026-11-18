import AppKit
import SwiftUI

@main
struct NotAnIslandApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // SwiftUI requires at least one scene; the notch itself is an AppKit panel owned by Core.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let moments = NotchMoments()
    private let music = MusicActivity()
    private lazy var system = SystemActivity(moments: moments)
    private lazy var bluetooth = BluetoothMonitor(moments: moments)
    /// Music comes first: it owns the compact wings and the top of the expanded notch.
    private lazy var notchController = NotchWindowController(activities: [music, system], moments: moments)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notchController.start()
        music.start()
        system.start()
        bluetooth.start()
    }

    // With no Dock icon, opening the app again is the only way back after "Hide Not an Island".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.unhide(nil)
        return true
    }
}
