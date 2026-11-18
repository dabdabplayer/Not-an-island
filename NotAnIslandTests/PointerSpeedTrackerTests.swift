import CoreGraphics
import Testing
@testable import NotAnIsland

struct PointerSpeedTrackerTests {
    @Test func noSamplesMeansSpeedIsUnknown() {
        #expect(PointerSpeedTracker().speed(exitingAt: CGPoint(x: 10, y: 0), time: 1) == nil)
    }

    @Test func measuresSteadyMovementInPointsPerSecond() throws {
        var tracker = PointerSpeedTracker()
        // 8 pt every 8 ms = 1000 pt/s.
        for step in 0..<10 {
            tracker.record(CGPoint(x: Double(step) * 8, y: 0), at: Double(step) * 0.008)
        }

        let speed = try #require(tracker.speed(exitingAt: CGPoint(x: 80, y: 0), time: 0.08))
        #expect(abs(speed - 1000) < 1)
    }

    @Test func onlyRecentMovementCounts() throws {
        var tracker = PointerSpeedTracker()
        // A fast flick long ago, then a slow drift of 1 pt every 10 ms (100 pt/s) right before leaving.
        tracker.record(CGPoint(x: 0, y: 0), at: 0)
        tracker.record(CGPoint(x: 500, y: 0), at: 0.01)
        for step in 1...10 {
            tracker.record(CGPoint(x: 500 + Double(step), y: 0), at: 1 + Double(step) * 0.01)
        }

        let speed = try #require(tracker.speed(exitingAt: CGPoint(x: 511, y: 0), time: 1.11))
        #expect(abs(speed - 100) < 1)
    }

    @Test func pointerThatRestedThenLeftReadsAsSlow() throws {
        var tracker = PointerSpeedTracker()
        tracker.record(CGPoint(x: 0, y: 0), at: 0)

        let speed = try #require(tracker.speed(exitingAt: CGPoint(x: 20, y: 0), time: 2))
        #expect(speed == 10)
    }

    @Test func resetForgetsEarlierMovement() {
        var tracker = PointerSpeedTracker()
        tracker.record(CGPoint(x: 0, y: 0), at: 0)
        tracker.reset()

        #expect(tracker.speed(exitingAt: CGPoint(x: 10, y: 0), time: 0.01) == nil)
    }
}
