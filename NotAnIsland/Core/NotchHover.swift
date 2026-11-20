import Foundation

/// Decides when the notch expands and collapses in response to the pointer.
/// Expands immediately on hover; collapses after a delay that shortens the faster the pointer left.
@MainActor
final class NotchHoverModel {
    nonisolated static let slowestCollapseDelay: Duration = .seconds(1)
    nonisolated static let fastestCollapseDelay: Duration = .milliseconds(100)
    /// Exit speeds, in points per second, at or below which the delay is longest and at or above which it is shortest.
    nonisolated static let slowExitSpeed: Double = 200
    nonisolated static let fastExitSpeed: Double = 2000

    private(set) var isExpanded = false
    /// The activity whose bubble the pointer entered; the expanded notch shows it alone.
    private(set) var focus: String?
    private(set) var pendingCollapse: Task<Void, Never>?
    private(set) var isHeldOpen = false
    var onExpansionChange: (Bool) -> Void = { _ in }

    private let sleep: (Duration) async throws -> Void
    private let isPointerInside: () -> Bool

    init(
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        isPointerInside: @escaping () -> Bool
    ) {
        self.sleep = sleep
        self.isPointerInside = isPointerInside
    }

    /// A nil speed means no movement was measured: the pointer crossed the notch within a single frame.
    nonisolated static func collapseDelay(forExitSpeed speed: Double?) -> Duration {
        guard let speed else { return fastestCollapseDelay }
        let progress = (speed - slowExitSpeed) / (fastExitSpeed - slowExitSpeed)
        if progress <= 0 { return slowestCollapseDelay }
        if progress >= 1 { return fastestCollapseDelay }
        return slowestCollapseDelay - (slowestCollapseDelay - fastestCollapseDelay) * progress
    }

    /// - Parameter focus: The activity whose bubble was entered, or nil for the notch itself.
    ///   Ignored while already expanded, so moving across the expanded notch keeps what it shows.
    func pointerEntered(focus: String? = nil) {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        guard !isExpanded else { return }
        self.focus = focus
        setExpanded(true)
    }

    func pointerExited(speed: Double?) {
        guard isExpanded, !isHeldOpen else { return }
        scheduleCollapse(after: Self.collapseDelay(forExitSpeed: speed))
    }

    /// Keeps the notch open during an interaction that may carry the pointer outside it, such as scrubbing.
    func setHeldOpen(_ held: Bool) {
        isHeldOpen = held
        if held {
            pendingCollapse?.cancel()
            pendingCollapse = nil
        } else if isExpanded, !isPointerInside() {
            scheduleCollapse(after: Self.slowestCollapseDelay)
        }
    }

    private func scheduleCollapse(after delay: Duration) {
        pendingCollapse?.cancel()
        pendingCollapse = Task { [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                return  // Cancelled because the pointer came back.
            }
            guard !Task.isCancelled, let self else { return }
            pendingCollapse = nil
            // Window resizes can deliver a spurious exit under a stationary pointer.
            guard !isPointerInside(), !isHeldOpen else { return }
            setExpanded(false)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        if !expanded {
            focus = nil
        }
        onExpansionChange(expanded)
    }
}

/// Measures how fast the pointer is moving, in points per second, from its most recent movement.
struct PointerSpeedTracker {
    /// Only movement this recent counts, so an earlier flick doesn't make a slow exit read as fast.
    static let window: TimeInterval = 0.05

    private var samples: [(location: CGPoint, time: TimeInterval)] = []

    mutating func record(_ location: CGPoint, at time: TimeInterval) {
        samples.append((location, time))
        while samples.count > 1, let oldest = samples.first, time - oldest.time > Self.window {
            samples.removeFirst()
        }
    }

    mutating func reset() {
        samples.removeAll()
    }

    func speed(exitingAt location: CGPoint, time: TimeInterval) -> Double? {
        // If the pointer rested before leaving, the last sample is older than the window and the speed reads as slow.
        guard let reference = samples.first(where: { time - $0.time <= Self.window }) ?? samples.last else { return nil }
        let elapsed = time - reference.time
        guard elapsed > 0 else { return nil }
        return hypot(location.x - reference.location.x, location.y - reference.location.y) / elapsed
    }
}
