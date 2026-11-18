import SwiftUI

/// The CPU, memory and network glance in the expanded notch.
struct SystemStatsSection: View {
    let stats: SystemStats

    var body: some View {
        HStack(spacing: 0) {
            cell("CPU", value: stats.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" })
            divider
            cell("Memory", value: stats.memory.map(SystemStats.formattedMemory), indicator: pressureColor)
            divider
            cell(
                "Network",
                value: zip(stats.downloadRate, stats.uploadRate).map {
                    "↓ \(SystemStats.formattedRate($0))  ↑ \(SystemStats.formattedRate($1))"
                }
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 22)
    }

    private var pressureColor: Color {
        switch stats.memoryPressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    private func cell(_ title: String, value: String?, indicator: Color? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                if let indicator {
                    Circle().fill(indicator).frame(width: 5, height: 5)
                }
                Text(title)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))

            // Unknown only before the first reading since launch, or if a reading failed; never a made-up value.
            Text(value ?? "—")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The banner that drops below the notch for a battery event.
struct BatteryMomentView: View {
    let moment: BatteryMoment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            if let percent {
                Text("\(percent)%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch moment {
        case .chargerConnected: "Charging"
        case .chargerDisconnected: "On Battery"
        case .lowBattery: "Low Battery"
        case .fullyCharged: "Fully Charged"
        }
    }

    private var percent: Int? {
        switch moment {
        case let .chargerConnected(percent), let .chargerDisconnected(percent), let .lowBattery(percent, _): percent
        case .fullyCharged: nil
        }
    }

    private var symbol: String {
        switch moment {
        case .chargerConnected: "bolt.fill"
        case .chargerDisconnected: "battery.75percent"
        case let .lowBattery(_, isCritical): isCritical ? "battery.0percent" : "battery.25percent"
        case .fullyCharged: "battery.100percent.bolt"
        }
    }

    private var tint: Color {
        switch moment {
        case .chargerConnected, .fullyCharged: .green
        case .chargerDisconnected: .white
        case let .lowBattery(_, isCritical): isCritical ? .red : .orange
        }
    }
}

private func zip<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
