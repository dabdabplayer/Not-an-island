import Foundation
import SwiftUI

/// The user's order for built-in features and extensions: the top active one takes the notch's
/// wings, the next becomes the bubble. Remembers activities that are currently absent, so a
/// re-enabled extension returns to its place; new ones join at the bottom.
@MainActor
@Observable
final class ActivityPriority {
    nonisolated static let defaultsKey = "activityPriority"

    private(set) var order: [String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// These activities in the user's order, adding any new ones at the bottom.
    func ordered(_ ids: [String]) -> [String] {
        let new = ids.filter { !order.contains($0) }
        if !new.isEmpty {
            save(order + new)
        }
        let present = Set(ids)
        return order.filter(present.contains)
    }

    /// Applies a drag in a list showing `shown`. Absent activities keep their positions; the shown
    /// ones are rearranged among the positions they occupy.
    func move(in shown: [String], fromOffsets source: IndexSet, toOffset destination: Int) {
        var rearranged = shown
        rearranged.move(fromOffsets: source, toOffset: destination)
        let shownSet = Set(shown)
        var next = rearranged.makeIterator()
        save(order.map { shownSet.contains($0) ? next.next() ?? $0 : $0 })
    }

    private func save(_ order: [String]) {
        self.order = order
        defaults.set(order, forKey: Self.defaultsKey)
    }
}
