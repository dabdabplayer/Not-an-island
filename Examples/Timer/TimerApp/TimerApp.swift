import SwiftUI

/// The container app. An extension ships inside an app; this one only explains how to turn it on.
@main
struct TimerApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Timer for Not an Island")
                    .font(.title2.bold())
                Text("This app carries a Not an Island extension. To use it, open Not an Island's Settings from the notch's menu, choose Extensions, and switch on Timer.")
                Text("You can quit this app afterwards; the timer runs in the notch.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 420)
        }
        .windowResizability(.contentSize)
    }
}
