import AppKit
import SwiftUI

/// The glance figures shown in the expanded notch. Rates are nil until two samples exist.
struct SystemStats: Equatable {
    enum MemoryPressure: Equatable {
        case normal
        case warning
        case critical
    }

    var cpuUsage: Double?
    var memory: MemoryReading?
    var memoryPressure: MemoryPressure = .normal
    var downloadRate: Double?
    var uploadRate: Double?

    static func cpuUsage(from earlier: CPUTicks, to later: CPUTicks) -> Double? {
        guard later.total > earlier.total, later.busy >= earlier.busy else { return nil }
        return Double(later.busy - earlier.busy) / Double(later.total - earlier.total)
    }

    /// Nil when a counter went backwards, which happens when an interface resets.
    static func rate(from earlier: UInt64, to later: UInt64, seconds: TimeInterval) -> Double? {
        guard seconds > 0, later >= earlier else { return nil }
        return Double(later - earlier) / seconds
    }

    /// Activity Monitor's "Memory Used": app memory (internal minus purgeable) plus wired plus compressed.
    static func memoryUsed(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        pageSize: UInt64
    ) -> UInt64 {
        (internalPages - min(purgeablePages, internalPages) + wiredPages + compressedPages) * pageSize
    }

    static func formattedRate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1_000_000: String(format: "%.0f KB/s", (bytesPerSecond / 1_000).rounded(.up))
        case ..<1_000_000_000: String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        default: String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        }
    }

    /// Uses binary gigabytes, as Activity Monitor does, so a 16 GB Mac reads as 16.
    static func formattedMemory(_ reading: MemoryReading) -> String {
        let gibibyte = Double(1 << 30)
        return String(
            format: "%.1f / %.0f GB",
            Double(reading.usedBytes) / gibibyte,
            Double(reading.totalBytes) / gibibyte
        )
    }
}

enum BatteryMoment: Equatable {
    case chargerConnected(percent: Int)
    case chargerDisconnected(percent: Int)
    case lowBattery(percent: Int, isCritical: Bool)
    case fullyCharged
}

/// Turns successive battery readings into the moments worth announcing.
struct BatteryMomentDetector {
    static let lowThresholds = [20, 10]
    static let criticalThreshold = 10

    private var previous: PowerReading?
    private var announcedThresholds: Set<Int> = []

    /// The first reading only records the starting state, so launching never announces anything.
    mutating func update(_ reading: PowerReading?) -> BatteryMoment? {
        guard let reading else {
            previous = nil
            return nil
        }
        defer { previous = reading }
        guard let previous else { return nil }

        if reading.isOnAC {
            announcedThresholds.removeAll()
        }
        if reading.isOnAC, !previous.isOnAC {
            return .chargerConnected(percent: reading.percent)
        }
        if !reading.isOnAC, previous.isOnAC {
            return .chargerDisconnected(percent: reading.percent)
        }
        if reading.isOnAC, reading.isCharged, !previous.isCharged {
            return .fullyCharged
        }
        guard !reading.isOnAC else { return nil }

        let crossed = Self.lowThresholds.filter {
            reading.percent <= $0 && previous.percent > $0 && !announcedThresholds.contains($0)
        }
        guard let lowest = crossed.min() else { return nil }
        // Every threshold at or above the current level has now been passed.
        announcedThresholds.formUnion(Self.lowThresholds.filter { reading.percent <= $0 })
        return .lowBattery(percent: reading.percent, isCritical: lowest <= Self.criticalThreshold)
    }
}

/// Battery moments and a CPU, memory and network glance in the expanded notch.
@MainActor
@Observable
final class SystemActivity: NotchActivity {
    static let samplingInterval: Duration = .seconds(2)
    static let momentDuration: Duration = .seconds(3)
    static let momentSize = CGSize(width: 240, height: 44)

    private(set) var stats = SystemStats()

    @ObservationIgnored private(set) var pendingSampling: Task<Void, Never>?
    @ObservationIgnored private let sensors: any SystemSensors
    @ObservationIgnored private let power: IOKitPowerSource?
    @ObservationIgnored private let moments: NotchMoments
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var batteryMoments = BatteryMomentDetector()
    @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private var previousSample: (date: Date, cpu: CPUTicks?, network: NetworkBytes?)?

    let id = "builtin.system"
    let name = "System"
    var isActive: Bool { true }

    var metrics: NotchActivityMetrics {
        NotchActivityMetrics(compactSideWidth: nil, expandedSectionSize: CGSize(width: 380, height: 44))
    }

    init(
        sensors: any SystemSensors = MachSystemSensors(),
        power: IOKitPowerSource? = IOKitPowerSource(),
        moments: NotchMoments,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sensors = sensors
        self.power = power
        self.moments = moments
        self.now = now
        self.sleep = sleep
    }

    func start() {
        if let power {
            _ = batteryMoments.update(power.read())
            power.startObserving { [weak self] in self?.powerSourceDidChange() }
        }

        // Delivered only when pressure changes, so nothing is polled.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressureSource?.data else { return }
                self.stats.memoryPressure = if event.contains(.critical) {
                    .critical
                } else if event.contains(.warning) {
                    .warning
                } else {
                    .normal
                }
            }
        }
        source.activate()
        memoryPressureSource = source
    }

    func expandedView() -> AnyView {
        AnyView(SystemStatsSection(stats: stats))
    }

    /// Samples only while the expanded notch is visible; the compact notch costs nothing.
    /// The last figures stay on screen when reopening until fresh ones replace them.
    func notchDidChangeExpansion(_ isExpanded: Bool) {
        pendingSampling?.cancel()
        pendingSampling = nil
        // Rates are measured within a glance; a baseline from before the notch collapsed would average over the gap.
        previousSample = nil
        guard isExpanded else { return }

        sampleNow()
        let sleep = sleep
        pendingSampling = Task { [weak self] in
            while true {
                do {
                    try await sleep(Self.samplingInterval)
                } catch {
                    return  // The notch collapsed.
                }
                guard !Task.isCancelled, let self else { return }
                sampleNow()
            }
        }
    }

    func sampleNow() {
        let date = now()
        let cpu = sensors.cpuTicks()
        let network = sensors.networkBytes()
        stats.memory = sensors.memory()

        // Without a baseline (the first sample of a glance) the previous figures are kept until the next sample.
        // With one, a failed read clears its figure rather than leaving an old value looking current.
        if let previous = previousSample {
            let seconds = date.timeIntervalSince(previous.date)
            stats.cpuUsage = zip(previous.cpu, cpu).flatMap(SystemStats.cpuUsage(from:to:))
            stats.downloadRate = zip(previous.network, network).flatMap {
                SystemStats.rate(from: $0.received, to: $1.received, seconds: seconds)
            }
            stats.uploadRate = zip(previous.network, network).flatMap {
                SystemStats.rate(from: $0.sent, to: $1.sent, seconds: seconds)
            }
        }
        previousSample = (date, cpu, network)
    }

    private func powerSourceDidChange() {
        guard let moment = batteryMoments.update(power?.read()) else { return }
        moments.present(NotchMoment(
            size: Self.momentSize,
            duration: Self.momentDuration,
            content: AnyView(BatteryMomentView(moment: moment))
        ))
    }
}

private func zip<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
