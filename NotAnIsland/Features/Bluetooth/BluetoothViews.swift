import SwiftUI

/// The banner shown below the notch when a Bluetooth device connects or disconnects,
/// laid out like macOS's own AirPods notice: icon, name and status, and a battery ring.
struct BluetoothMomentView: View {
    let moment: BluetoothMoment

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.kind.symbolName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 4)
            if let level = battery?.ringLevel {
                BatteryRing(level: level)
            }
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
    }

    private var device: BluetoothDeviceInfo {
        switch moment {
        case let .connected(device, _), let .disconnected(device): device
        }
    }

    private var battery: BluetoothBattery? {
        switch moment {
        case let .connected(_, battery): battery
        case .disconnected: nil
        }
    }

    private var status: String {
        switch moment {
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        }
    }
}

/// A circular battery gauge with the percentage in the middle.
struct BatteryRing: View {
    let level: Int

    private static let lowBattery = 20

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(level, 0), 100)) / 100)
                .stroke(level <= Self.lowBattery ? Color.red : Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(level)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .accessibilityLabel("Battery \(level) percent")
    }
}
