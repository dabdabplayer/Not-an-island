import ExtensionKit
import SwiftUI

struct SettingsView: View {
    let activities: NotchActivities
    let priority: ActivityPriority
    let updater: AppUpdater

    var body: some View {
        TabView {
            ExtensionsPane(activities: activities, priority: priority)
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
            UpdatesPane(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 560, height: 560)
    }
}

struct ExtensionsPane: View {
    let activities: NotchActivities
    let priority: ActivityPriority

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Order")
                    .font(.headline)
                Text("Drag to reorder. The highest active item fills the notch's wings, and the next one appears as a bubble beside them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                List {
                    ForEach(activities.ordered, id: \.id) { activity in
                        ActivityRow(activity: activity)
                    }
                    .onMove { source, destination in
                        priority.move(in: activities.ordered.map(\.id), fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.bordered)
                .frame(height: 170)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Installed Extensions")
                    .font(.headline)
                Text("Extensions come inside other apps. Switch one on to add it to the notch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // Apple's extension manager: the only way an extension from another app gets enabled.
                ExtensionBrowser()
            }
        }
        .padding(20)
    }
}

struct UpdatesPane: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Form {
            if let version = updater.availableUpdate {
                Section {
                    LabeledContent("Version \(version) is available") {
                        Button("Install…", action: updater.checkForUpdates)
                    }
                }
            }
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                LabeledContent("Version \(Self.version)") {
                    Button("Check Now", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                }
            } footer: {
                Text("Updates come from Not an Island's GitHub releases and are installed only if they're signed by the project.")
            }
        }
        .formStyle(.grouped)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}

private struct ActivityRow: View {
    let activity: any NotchActivity

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(activity.name)
            Spacer()
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        guard let activity = activity as? ExtensionActivity else { return "Built in" }
        switch activity.sessionState {
        case .running:
            return activity.isActive ? "Active" : "Idle"
        case .starting:
            return "Starting…"
        case .waitingToRelaunch:
            return "Restarting after a crash…"
        case .stopped:
            return "Stopped"
        case .incompatible:
            return "Needs a newer Not an Island"
        case .failed(let reason):
            return "Stopped responding: \(reason)"
        }
    }
}

private struct ExtensionBrowser: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> EXAppExtensionBrowserViewController {
        EXAppExtensionBrowserViewController()
    }

    func updateNSViewController(_ controller: EXAppExtensionBrowserViewController, context: Context) {}
}
