import Foundation
import Testing
@testable import NotAnIsland

struct BatteryMomentDetectorTests {
    private func reading(_ percent: Int, onAC: Bool = false, charged: Bool = false) -> PowerReading {
        PowerReading(percent: percent, isOnAC: onAC, isCharging: onAC && !charged, isCharged: charged)
    }

    @Test func launchOnlyRecordsTheCurrentState() {
        var detector = BatteryMomentDetector()
        #expect(detector.update(reading(5)) == nil)
    }

    @Test func pluggingInAnnouncesCharging() {
        var detector = BatteryMomentDetector()
        _ = detector.update(reading(64))
        #expect(detector.update(reading(64, onAC: true)) == .chargerConnected(percent: 64))
    }

    @Test func unpluggingAnnouncesBattery() {
        var detector = BatteryMomentDetector()
        _ = detector.update(reading(64, onAC: true))
        #expect(detector.update(reading(64)) == .chargerDisconnected(percent: 64))
    }

    @Test func lowBatteryIsAnnouncedOncePerThreshold() {
        var detector = BatteryMomentDetector()
        _ = detector.update(reading(22))
        #expect(detector.update(reading(21)) == nil)
        #expect(detector.update(reading(20)) == .lowBattery(percent: 20, isCritical: false))
        #expect(detector.update(reading(19)) == nil)
        #expect(detector.update(reading(20)) == nil)
        #expect(detector.update(reading(19)) == nil)
        #expect(detector.update(reading(10)) == .lowBattery(percent: 10, isCritical: true))
        #expect(detector.update(reading(9)) == nil)
    }

    @Test func droppingPastBothThresholdsAtOnceAnnouncesTheCriticalOne() {
        var detector = BatteryMomentDetector()
        _ = detector.update(reading(25))
        #expect(detector.update(reading(9)) == .lowBattery(percent: 9, isCritical: true))
        #expect(detector.update(reading(8)) == nil)
    }

    @Test func pluggingInResetsLowBatteryWarnings() {
        var detector = BatteryMomentDetector()
        _ = detector.update(reading(21))
        _ = detector.update(reading(20))
        _ = detector.update(reading(20, onAC: true))
        _ = detector.update(reading(21))
        #expect(detector.update(reading(20)) == .lowBattery(percent: 20, isCritical: false))
    }

    @Test func reachingFullChargeOnPowerIsAnnounced() {
        var detector = BatteryMomentDetector()
        _ = detector.update(reading(99, onAC: true))
        #expect(detector.update(reading(100, onAC: true, charged: true)) == .fullyCharged)
        #expect(detector.update(reading(100, onAC: true, charged: true)) == nil)
    }

    // macOS may hold the charge below 100% (Optimized Charging or a charge limit) and still report it as charged.
    @Test func chargeLimitCountsAsFullyCharged() {
        var detector = BatteryMomentDetector()
        _ = detector.update(reading(79, onAC: true))
        #expect(detector.update(reading(80, onAC: true, charged: true)) == .fullyCharged)
    }

    @Test func macWithoutABatteryNeverAnnouncesAnything() {
        var detector = BatteryMomentDetector()
        #expect(detector.update(nil) == nil)
        #expect(detector.update(nil) == nil)
    }
}

struct SystemStatsMathTests {
    @Test func cpuUsageIsBusyShareOfElapsedTicks() {
        let earlier = CPUTicks(busy: 1000, total: 4000)
        let later = CPUTicks(busy: 1300, total: 5000)
        #expect(SystemStats.cpuUsage(from: earlier, to: later) == 0.3)
    }

    @Test func cpuUsageNeedsTicksToHaveElapsed() {
        let ticks = CPUTicks(busy: 1000, total: 4000)
        #expect(SystemStats.cpuUsage(from: ticks, to: ticks) == nil)
    }

    @Test func networkRateIsBytesPerSecond() {
        let rate = SystemStats.rate(from: 1_000_000, to: 3_400_000, seconds: 2)
        #expect(rate == 1_200_000)
    }

    // An interface going down resets its counters; that sample is unknown rather than negative.
    @Test func networkCounterResetGivesNoRate() {
        #expect(SystemStats.rate(from: 5_000_000, to: 1_000, seconds: 2) == nil)
        #expect(SystemStats.rate(from: 1_000, to: 2_000, seconds: 0) == nil)
    }

    // Matches Activity Monitor's "Memory Used": app memory (internal minus purgeable) + wired + compressed.
    @Test func memoryUsedMatchesActivityMonitor() {
        let used = SystemStats.memoryUsed(
            internalPages: 300_000,
            purgeablePages: 20_000,
            wiredPages: 100_000,
            compressedPages: 50_000,
            pageSize: 16_384
        )
        #expect(used == 430_000 * 16_384)
    }

    @Test func ratesAreFormattedCompactly() {
        #expect(SystemStats.formattedRate(0) == "0 KB/s")
        #expect(SystemStats.formattedRate(950) == "1 KB/s")
        #expect(SystemStats.formattedRate(48_000) == "48 KB/s")
        #expect(SystemStats.formattedRate(1_200_000) == "1.2 MB/s")
        #expect(SystemStats.formattedRate(3_400_000_000) == "3.4 GB/s")
    }

    @Test func memoryIsFormattedAsUsedOfTotal() {
        let gibibyte: UInt64 = 1 << 30
        let reading = MemoryReading(usedBytes: gibibyte * 74 / 10, totalBytes: gibibyte * 16)
        #expect(SystemStats.formattedMemory(reading) == "7.4 / 16 GB")
    }
}

/// Supplies recorded readings in place of the system calls.
@MainActor
final class FakeSystemSensors: SystemSensors {
    var cpu: [CPUTicks] = []
    var network: [NetworkBytes] = []
    var memoryReading = MemoryReading(usedBytes: 8 << 30, totalBytes: 16 << 30)
    private(set) var reads = 0

    func cpuTicks() -> CPUTicks? {
        reads += 1
        return cpu.isEmpty ? nil : cpu.removeFirst()
    }

    func memory() -> MemoryReading? { memoryReading }

    func networkBytes() -> NetworkBytes? {
        network.isEmpty ? nil : network.removeFirst()
    }
}

@MainActor
struct SystemActivitySamplingTests {
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 0)
    }

    private let sensors = FakeSystemSensors()
    private let clock = Clock()

    private func makeActivity() -> SystemActivity {
        let clock = clock
        return SystemActivity(
            sensors: sensors,
            power: nil,
            moments: NotchMoments(),
            now: { clock.now },
            // Suspends until cancelled, like the real sleep, so the loop never spins in tests.
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
    }

    @Test func compactNotchNeverSamples() {
        _ = makeActivity()
        #expect(sensors.reads == 0)
    }

    @Test func expandingSamplesImmediatelyAndCollapsingStops() async {
        let activity = makeActivity()
        activity.notchDidChangeExpansion(true)

        #expect(sensors.reads == 1)
        let sampling = activity.pendingSampling
        #expect(sampling != nil)

        activity.notchDidChangeExpansion(false)
        await sampling?.value
        #expect(activity.pendingSampling == nil)
        #expect(sensors.reads == 1)
    }

    @Test func ratesNeedTwoSamples() {
        sensors.cpu = [CPUTicks(busy: 100, total: 1000), CPUTicks(busy: 400, total: 2000)]
        sensors.network = [NetworkBytes(received: 0, sent: 0), NetworkBytes(received: 2_000_000, sent: 200_000)]
        let activity = makeActivity()

        activity.sampleNow()
        #expect(activity.stats.cpuUsage == nil)
        #expect(activity.stats.downloadRate == nil)
        #expect(activity.stats.memory != nil)

        clock.now = clock.now.addingTimeInterval(2)
        activity.sampleNow()
        #expect(activity.stats.cpuUsage == 0.3)
        #expect(activity.stats.downloadRate == 1_000_000)
        #expect(activity.stats.uploadRate == 100_000)
    }

    // Reopening shows the last reading straight away instead of a dash, until a fresh one replaces it.
    @Test func reopeningKeepsTheLastReadingUntilANewOne() {
        sensors.cpu = [
            CPUTicks(busy: 100, total: 1000), CPUTicks(busy: 400, total: 2000),  // first glance: 30%
            CPUTicks(busy: 500, total: 3000), CPUTicks(busy: 1500, total: 4000),  // second glance: 100%
        ]
        sensors.network = [
            NetworkBytes(received: 0, sent: 0), NetworkBytes(received: 2_000_000, sent: 0),
            NetworkBytes(received: 9_000_000, sent: 0), NetworkBytes(received: 9_400_000, sent: 0),
        ]
        let activity = makeActivity()
        activity.notchDidChangeExpansion(true)
        clock.now = clock.now.addingTimeInterval(2)
        activity.sampleNow()
        activity.notchDidChangeExpansion(false)

        clock.now = clock.now.addingTimeInterval(60)
        activity.notchDidChangeExpansion(true)
        #expect(activity.stats.cpuUsage == 0.3)
        #expect(activity.stats.downloadRate == 1_000_000)

        clock.now = clock.now.addingTimeInterval(2)
        activity.sampleNow()
        #expect(activity.stats.cpuUsage == 1)
        #expect(activity.stats.downloadRate == 200_000)
    }

    // A reading that fails mid-glance shows a dash rather than leaving an old figure looking current.
    @Test func failedReadingShowsADash() {
        sensors.cpu = [CPUTicks(busy: 100, total: 1000), CPUTicks(busy: 400, total: 2000)]
        let activity = makeActivity()
        activity.sampleNow()
        clock.now = clock.now.addingTimeInterval(2)
        activity.sampleNow()
        #expect(activity.stats.cpuUsage == 0.3)

        clock.now = clock.now.addingTimeInterval(2)
        activity.sampleNow()  // No CPU ticks left: the read fails.
        #expect(activity.stats.cpuUsage == nil)
    }

    @Test func alwaysOffersAStatsSectionButNoCompactWings() {
        let activity = makeActivity()
        #expect(activity.isActive)
        #expect(activity.metrics.compactSideWidth == nil)
        #expect(activity.metrics.expandedSectionSize != nil)
    }
}

/// Reads this Mac's real sensors to catch mistakes in the system-call plumbing.
@MainActor
struct SystemSensorSmokeTests {
    private let sensors = MachSystemSensors()

    @Test func cpuTicksAdvance() async throws {
        let first = try #require(sensors.cpuTicks())
        try await Task.sleep(for: .milliseconds(100))
        let second = try #require(sensors.cpuTicks())

        #expect(second.total > first.total)
        #expect(first.busy <= first.total)
    }

    @Test func memoryUsedIsWithinPhysicalMemory() throws {
        let memory = try #require(sensors.memory())
        #expect(memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.usedBytes > 0)
        #expect(memory.usedBytes <= memory.totalBytes)
    }

    @Test func networkCountersAreReadable() throws {
        let bytes = try #require(sensors.networkBytes())
        #expect(bytes.received > 0)
    }

    @Test func batteryReadingIsPlausibleWhenPresent() {
        guard let reading = IOKitPowerSource().read() else { return }  // Desktop Macs have no battery.
        #expect((0...100).contains(reading.percent))
    }
}
