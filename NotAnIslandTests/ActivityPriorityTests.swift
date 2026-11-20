import Foundation
import Testing
@testable import NotAnIsland

@MainActor
struct ActivityPriorityTests {
    private let defaults: UserDefaults

    init() throws {
        let name = "ActivityPriorityTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
    }

    @Test func newActivitiesGoToTheBottomInTheOrderTheyArrive() {
        let priority = ActivityPriority(defaults: defaults)
        #expect(priority.ordered(["builtin.music", "builtin.system", "com.example.timer"])
            == ["builtin.music", "builtin.system", "com.example.timer"])
    }

    @Test func movingRearrangesAndIsRemembered() {
        let priority = ActivityPriority(defaults: defaults)
        let shown = priority.ordered(["builtin.music", "builtin.system", "com.example.timer"])
        priority.move(in: shown, fromOffsets: [2], toOffset: 0)

        #expect(priority.ordered(shown) == ["com.example.timer", "builtin.music", "builtin.system"])
        #expect(ActivityPriority(defaults: defaults).ordered(shown) == ["com.example.timer", "builtin.music", "builtin.system"])
    }

    // Turning an extension off and on again brings it back where the user put it.
    @Test func absentActivitiesKeepTheirPlace() {
        let priority = ActivityPriority(defaults: defaults)
        let all = ["builtin.music", "com.example.timer", "builtin.system"]
        priority.move(in: priority.ordered(all), fromOffsets: [1], toOffset: 0)

        #expect(priority.ordered(["builtin.music", "builtin.system"]) == ["builtin.music", "builtin.system"])
        #expect(priority.ordered(all) == ["com.example.timer", "builtin.music", "builtin.system"])
    }

    // Moving within the visible list never reorders hidden entries relative to each other.
    @Test func movingAroundAnAbsentActivityKeepsItsSlot() {
        let priority = ActivityPriority(defaults: defaults)
        _ = priority.ordered(["a", "gone", "b", "c"])
        priority.move(in: ["a", "b", "c"], fromOffsets: [2], toOffset: 0)

        #expect(priority.ordered(["a", "gone", "b", "c"]) == ["c", "gone", "a", "b"])
    }
}
