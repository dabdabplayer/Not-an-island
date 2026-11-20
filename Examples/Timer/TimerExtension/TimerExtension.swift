import ExtensionFoundation
import ExtensionKit
import NotAnIslandKit
import SwiftUI

/// A countdown timer in the notch. While idle it only offers presets in the expanded notch;
/// once running it takes the compact wings (or the bubble) and shows the time left.
@main
struct TimerExtension: NotchActivityExtension {
    let controller: NotchActivityController
    let timer: CountdownTimer

    init() {
        let controller = NotchActivityController(isActive: true, sizes: CountdownTimer.idleSizes)
        self.controller = controller
        timer = CountdownTimer(controller: controller)
    }

    var compactLeading: some View {
        Image(systemName: "timer")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var compactTrailing: some View {
        TimeLeftText(timer: timer, size: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var minimal: some View {
        TimerRing(timer: timer)
    }

    var expanded: some View {
        TimerControls(timer: timer)
    }

    var banner: some View {
        Label("Time's up", systemImage: "bell.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The timer's state, shared by every presentation in the extension's process.
@MainActor
@Observable
final class CountdownTimer {
    static let presets: [Duration] = [.seconds(60), .seconds(5 * 60), .seconds(25 * 60)]

    /// Idle, only the expanded notch shows the timer, so it never takes the wings from anything else.
    static let idleSizes = NotchActivitySizes(
        expanded: CGSize(width: 320, height: 64),
        banner: CGSize(width: 200, height: 40)
    )
    static let runningSizes = NotchActivitySizes(
        compactSideWidth: 44,
        expanded: CGSize(width: 320, height: 64),
        minimal: CGSize(width: 24, height: 24),
        banner: CGSize(width: 200, height: 40)
    )

    private(set) var total: Duration = .zero
    private(set) var endDate: Date?
    /// Time left while paused.
    private(set) var pausedRemaining: Duration?

    @ObservationIgnored private let controller: NotchActivityController
    @ObservationIgnored private var finish: Task<Void, Never>?

    init(controller: NotchActivityController) {
        self.controller = controller
    }

    var isIdle: Bool { endDate == nil && pausedRemaining == nil }
    var isRunning: Bool { endDate != nil }

    func remaining(at date: Date) -> Duration {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return .zero }
        return .seconds(max(endDate.timeIntervalSince(date), 0))
    }

    func start(_ duration: Duration) {
        total = duration
        pausedRemaining = nil
        run(for: duration)
    }

    func pause() {
        guard isRunning else { return }
        pausedRemaining = remaining(at: .now)
        endDate = nil
        finish?.cancel()
    }

    func resume() {
        guard let pausedRemaining else { return }
        self.pausedRemaining = nil
        run(for: pausedRemaining)
    }

    func reset() {
        finish?.cancel()
        endDate = nil
        pausedRemaining = nil
        controller.sizes = Self.idleSizes
    }

    private func run(for duration: Duration) {
        endDate = .now + TimeInterval(duration.components.seconds)
        controller.sizes = Self.runningSizes
        finish?.cancel()
        finish = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            reset()
            controller.postBanner(for: .seconds(4))
        }
    }
}

struct TimeLeftText: View {
    let timer: CountdownTimer
    let size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(timer.remaining(at: context.date)))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(timer.isRunning ? .orange : .secondary)
        }
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The bubble: a ring that empties as time runs out.
struct TimerRing: View {
    let timer: CountdownTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = max(Double(timer.total.components.seconds), 1)
            let left = Double(timer.remaining(at: context.date).components.seconds)
            Circle()
                .trim(from: 0, to: left / total)
                .stroke(.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(4)
        }
    }
}

struct TimerControls: View {
    let timer: CountdownTimer

    var body: some View {
        HStack(spacing: 12) {
            if timer.isIdle {
                Image(systemName: "timer")
                    .foregroundStyle(.orange)
                ForEach(CountdownTimer.presets, id: \.self) { preset in
                    Button(TimeLeftText.format(preset)) { timer.start(preset) }
                }
            } else {
                TimeLeftText(timer: timer, size: 22)
                Spacer()
                Button(timer.isRunning ? "Pause" : "Resume", systemImage: timer.isRunning ? "pause.fill" : "play.fill") {
                    timer.isRunning ? timer.pause() : timer.resume()
                }
                Button("Cancel", systemImage: "xmark") { timer.reset() }
            }
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .tint(.orange)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
