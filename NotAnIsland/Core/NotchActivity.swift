import os
import SwiftUI

/// Content a feature shows in the notch. The engine owns the window, geometry and transitions;
/// an activity only describes what to draw and how much room it needs. Activities are ordered by
/// priority: the first active one with compact content owns the compact wings, the next one with a
/// minimal view becomes the bubble beside them, and every active one with an expanded section is
/// stacked in the expanded notch.
@MainActor
protocol NotchActivity: AnyObject, Observable {
    /// Stable across launches; identifies the activity in layout state and the user's priority order.
    var id: String { get }
    /// Shown in Settings.
    var name: String { get }
    /// Whether the activity currently has something to show. Changes are observed by the engine.
    var isActive: Bool { get }
    var metrics: NotchActivityMetrics { get }

    /// Drawn to the left of the camera in the compact notch.
    func compactLeadingView() -> AnyView
    /// Drawn to the right of the camera in the compact notch.
    func compactTrailingView() -> AnyView
    /// This activity's section of the expanded notch.
    func expandedView() -> AnyView
    /// The bubble shown beside the wings while another activity owns them.
    func minimalView() -> AnyView

    func notchDidChangeExpansion(_ isExpanded: Bool)
}

extension NotchActivity {
    func compactLeadingView() -> AnyView { AnyView(EmptyView()) }
    func compactTrailingView() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(EmptyView()) }
    func minimalView() -> AnyView { AnyView(EmptyView()) }
    func notchDidChangeExpansion(_ isExpanded: Bool) {}
}

struct NotchActivityMetrics: Equatable, Sendable {
    /// Width added on each side of the notch for compact content; nil if the activity has none.
    var compactSideWidth: CGFloat?
    /// Size of the activity's section in the expanded notch; nil if it has none.
    var expandedSectionSize: CGSize?
    /// Size of the activity's bubble; nil if it has none.
    var minimalSize: CGSize? = nil
}

/// Every activity the notch can show, in the user's priority order. Observable, so the engine
/// follows activities being added, removed or reordered as well as their own changes.
@MainActor
@Observable
final class NotchActivities: @MainActor ExpressibleByArrayLiteral {
    var ordered: [any NotchActivity]

    init(_ ordered: [any NotchActivity]) {
        self.ordered = ordered
    }

    convenience init(arrayLiteral elements: any NotchActivity...) {
        self.init(elements)
    }

    subscript(id: String) -> (any NotchActivity)? {
        ordered.first { $0.id == id }
    }

    /// The active activities' metrics, in priority order.
    var activeLayouts: [NotchActivityLayout] {
        ordered.filter(\.isActive).map { NotchActivityLayout(id: $0.id, metrics: $0.metrics) }
    }
}

/// An active activity's metrics, as the layout sees it.
struct NotchActivityLayout: Equatable, Sendable {
    let id: String
    let metrics: NotchActivityMetrics
}

struct NotchSection: Equatable {
    var activity: String
    var size: CGSize
}

struct NotchBubble: Equatable {
    var activity: String
    var size: CGSize
}

/// What the notch is currently showing.
struct NotchState: Equatable {
    var isExpanded = false
    /// The activity the expanded notch shows alone, after the pointer entered its bubble.
    var focus: String?
    /// The activity whose content fills the compact wings.
    var compactActivity: String?
    var compactSideWidth: CGFloat = 0
    /// The compact bubble. Kept while expanded, since a focused expansion must still reach where it was.
    var bubble: NotchBubble?
    /// Expanded sections, top to bottom.
    var sections: [NotchSection] = []
    /// A transient banner hanging below the camera band.
    var momentSize: CGSize?

    /// - Parameters:
    ///   - focus: Expand only this activity, if it is active and has an expanded section.
    ///   - activities: The active activities, in priority order.
    static func make(isExpanded: Bool, focus: String? = nil, activities: [NotchActivityLayout], momentSize: CGSize?) -> NotchState {
        let compact = activities.lazy
            .compactMap { activity in activity.metrics.compactSideWidth.map { (activity.id, $0) } }
            .first
        let bubble = activities.lazy
            .filter { $0.id != compact?.0 }
            .compactMap { activity in activity.metrics.minimalSize.map { NotchBubble(activity: activity.id, size: $0) } }
            .first
        let allSections = activities.compactMap { activity in
            activity.metrics.expandedSectionSize.map { NotchSection(activity: activity.id, size: $0) }
        }
        let focused = allSections.filter { $0.activity == focus }
        return NotchState(
            isExpanded: isExpanded,
            focus: isExpanded && !focused.isEmpty ? focus : nil,
            compactActivity: compact?.0,
            compactSideWidth: compact?.1 ?? 0,
            bubble: bubble,
            sections: focused.isEmpty ? allSections : focused,
            momentSize: momentSize
        )
    }
}

/// A brief banner that drops below the camera band, such as a charging notice.
struct NotchMoment {
    static let maximumSize = CGSize(width: 320, height: 60)

    let id = UUID()
    let size: CGSize
    let duration: Duration
    let content: AnyView

    init(size: CGSize, duration: Duration, content: AnyView) {
        self.size = CGSize(width: min(size.width, Self.maximumSize.width), height: min(size.height, Self.maximumSize.height))
        self.duration = duration
        self.content = content
    }
}

/// Shows one moment at a time. A new moment replaces the current one; moments arriving while
/// the notch is expanded are dropped, since the panel is already open.
@MainActor
final class NotchMoments {
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "Notch")

    private(set) var current: NotchMoment?
    private(set) var pendingEnd: Task<Void, Never>?
    var isSuppressed: () -> Bool = { false }
    var onChange: (NotchMoment?) -> Void = { _ in }

    private let sleep: (Duration) async throws -> Void

    init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func present(_ moment: NotchMoment) {
        guard !isSuppressed() else {
            Self.logger.debug("Dropped a moment while the notch is expanded")
            return
        }
        pendingEnd?.cancel()
        current = moment
        onChange(moment)
        pendingEnd = Task { [weak self, sleep] in
            do {
                try await sleep(moment.duration)
            } catch {
                return  // Replaced or dismissed.
            }
            guard !Task.isCancelled, let self, current?.id == moment.id else { return }
            end()
        }
    }

    func dismiss() {
        guard current != nil else { return }
        end()
    }

    private func end() {
        pendingEnd?.cancel()
        pendingEnd = nil
        current = nil
        onChange(nil)
    }
}

/// Lets activity content keep the notch open during an interaction that may carry the pointer
/// outside it, such as scrubbing. A class, so SwiftUI compares it by identity rather than
/// treating an incomparable closure as changed on every update.
@MainActor
final class NotchHoldOpenAction: Sendable {
    private let action: @MainActor @Sendable (Bool) -> Void

    nonisolated init(_ action: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.action = action
    }

    func callAsFunction(_ held: Bool) {
        action(held)
    }

    nonisolated static let none = NotchHoldOpenAction { _ in }
}

extension EnvironmentValues {
    @Entry var notchHoldOpen = NotchHoldOpenAction.none
}
