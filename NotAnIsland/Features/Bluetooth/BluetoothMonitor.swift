import AppKit
import CoreAudio
import IOBluetooth
import os
import SwiftUI

struct BluetoothBattery: Equatable, Sendable {
    var left: Int? = nil
    var right: Int? = nil
    var caseLevel: Int? = nil
    /// Single-battery devices such as mice and keyboards.
    var main: Int? = nil

    var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && main == nil }

    /// The single level shown in the banner's ring: the lower bud, otherwise whichever battery is reported.
    var ringLevel: Int? {
        [left, right].compactMap(\.self).min() ?? main ?? caseLevel
    }
}

enum BluetoothDeviceKind: CaseIterable, Equatable, Sendable {
    case airPods, airPodsPro, airPodsMax, headphones, speaker, keyboard, mouse, trackpad, gameController, other

    /// Apple headphones are told apart by name; everything else by its Bluetooth class of device.
    init(name: String, majorClass: UInt32, minorClass: UInt32) {
        let name = name.lowercased()
        switch majorClass {
        case UInt32(kBluetoothDeviceClassMajorAudio):
            if name.contains("airpods max") {
                self = .airPodsMax
            } else if name.contains("airpods pro") {
                self = .airPodsPro
            } else if name.contains("airpods") {
                self = .airPods
            } else if minorClass == UInt32(kBluetoothDeviceClassMinorAudioLoudspeaker) {
                self = .speaker
            } else {
                self = .headphones
            }
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            if minorClass & UInt32(kBluetoothDeviceClassMinorPeripheral1Keyboard) != 0 {
                self = .keyboard
            } else if minorClass & UInt32(kBluetoothDeviceClassMinorPeripheral1Pointing) != 0 {
                self = name.contains("trackpad") ? .trackpad : .mouse
            } else if [kBluetoothDeviceClassMinorPeripheral2Joystick, kBluetoothDeviceClassMinorPeripheral2Gamepad]
                .map(UInt32.init).contains(minorClass & 0x0F) {
                self = .gameController
            } else {
                self = .other
            }
        default:
            self = .other
        }
    }

    /// Headphones and speakers, which are announced when their audio output appears.
    var isAudio: Bool {
        [.airPods, .airPodsPro, .airPodsMax, .headphones, .speaker].contains(self)
    }

    var symbolName: String {
        switch self {
        case .airPods: "airpods"
        case .airPodsPro: "airpods.pro"
        case .airPodsMax: "airpods.max"
        case .headphones: "headphones"
        case .speaker: "hifispeaker"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gameController: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}

struct BluetoothDeviceInfo: Equatable, Sendable {
    /// Normalised to "aa:bb:cc:dd:ee:ff".
    var address: String
    var name: String
    var kind: BluetoothDeviceKind
}

extension BluetoothDeviceInfo {
    @MainActor
    init?(device: IOBluetoothDevice) {
        guard let address = device.addressString else { return nil }
        let name = device.nameOrAddress ?? address
        self.init(
            address: BluetoothBatteryReport.normalizedAddress(address),
            name: name,
            kind: BluetoothDeviceKind(
                name: name,
                majorClass: UInt32(device.deviceClassMajor),
                minorClass: UInt32(device.deviceClassMinor)
            )
        )
    }
}

/// Battery levels from macOS's own Bluetooth report (`system_profiler SPBluetoothDataType -json`).
/// There is no public API for AirPods battery; this report is public but its format is undocumented,
/// so missing or unrecognised fields are simply left out and never guessed.
enum BluetoothBatteryReport {
    struct UnexpectedFormat: Error {}
    struct ReportFailed: Error {
        let status: Int32
    }

    static func normalizedAddress(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    /// Battery levels by normalised address, for devices whose entry reports any.
    static func parse(_ data: Data) throws -> [String: BluetoothBattery] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UnexpectedFormat()
        }
        var batteries: [String: BluetoothBattery] = [:]
        for controller in root["SPBluetoothDataType"] as? [[String: Any]] ?? [] {
            for section in ["device_connected", "device_not_connected"] {
                for entry in controller[section] as? [[String: Any]] ?? [] {
                    for case let info as [String: Any] in entry.values {
                        guard let address = info["device_address"] as? String else { continue }
                        let battery = BluetoothBattery(
                            left: percent(info["device_batteryLevelLeft"]),
                            right: percent(info["device_batteryLevelRight"]),
                            caseLevel: percent(info["device_batteryLevelCase"]),
                            main: percent(info["device_batteryLevelMain"])
                        )
                        if !battery.isEmpty {
                            batteries[normalizedAddress(address)] = battery
                        }
                    }
                }
            }
        }
        return batteries
    }

    /// Runs the report off the main thread; it takes about 0.1 s.
    @Sendable
    static func fetch() async throws -> [String: BluetoothBattery] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                    process.arguments = ["SPBluetoothDataType", "-json"]
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    // Read before waiting, so a full pipe can't stall the report.
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw ReportFailed(status: process.terminationStatus) }
                    return try parse(data)
                })
            }
        }
    }

    private static func percent(_ value: Any?) -> Int? {
        (value as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
    }
}

/// A Bluetooth audio output as CoreAudio lists it. AirPods appear here when they go in and
/// disappear when they come out, even though their Bluetooth connection stays up throughout.
struct BluetoothAudioOutput: Hashable, Sendable {
    var address: String
    var name: String

    /// macOS names Bluetooth audio devices after their address, for example "AA-BB-CC-DD-EE-FF:output".
    static func address(fromUID uid: String) -> String? {
        guard let range = uid.range(of: #"^([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}"#, options: .regularExpression) else {
            return nil
        }
        return BluetoothBatteryReport.normalizedAddress(String(uid[range]))
    }
}

/// Reads and observes Bluetooth audio outputs through CoreAudio. The device list is observed,
/// not polled: the listener runs only when a device is added or removed.
@MainActor
final class CoreAudioBluetoothOutputs {
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "Bluetooth")

    private var listener: AudioObjectPropertyListenerBlock?

    /// - Parameter addressForName: Fallback for devices whose UID doesn't carry their address.
    func current(addressForName: (String) -> String?) -> Set<BluetoothAudioOutput> {
        guard let devices = CoreAudioProperties.deviceIDs() else {
            Self.logger.error("Couldn't list audio devices")
            return []
        }

        return Set(devices.compactMap { device -> BluetoothAudioOutput? in
            let transport = CoreAudioProperties.uint32(device, kAudioDevicePropertyTransportType)
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  CoreAudioProperties.hasOutput(device),
                  let name = CoreAudioProperties.string(device, kAudioObjectPropertyName)
            else { return nil }
            let uid = CoreAudioProperties.string(device, kAudioDevicePropertyDeviceUID)
            guard let address = uid.flatMap(BluetoothAudioOutput.address(fromUID:)) ?? addressForName(name) else {
                Self.logger.error("Couldn't find the Bluetooth address of audio device \(name, privacy: .public)")
                return nil
            }
            return BluetoothAudioOutput(address: address, name: name)
        })
    }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        var address = CoreAudioProperties.globalAddress(kAudioHardwarePropertyDevices)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            // Registered on the main queue below.
            MainActor.assumeIsolated { onChange() }
        }
        let status = AudioObjectAddPropertyListenerBlock(CoreAudioProperties.system, &address, .main, listener)
        guard status == noErr else {
            Self.logger.error("Couldn't observe audio devices: OSStatus \(status, privacy: .public)")
            return
        }
        self.listener = listener
    }
}

/// Remembers which devices are connected, so each connection and disconnection is announced once
/// and devices already connected at launch are not announced at all.
struct BluetoothConnectionTracker {
    private var connected: Set<String>

    init(alreadyConnected: Set<String>) {
        connected = alreadyConnected
    }

    mutating func didConnect(_ address: String) -> Bool {
        connected.insert(address).inserted
    }

    mutating func didDisconnect(_ address: String) -> Bool {
        connected.remove(address) != nil
    }
}

enum BluetoothMoment: Equatable {
    case connected(BluetoothDeviceInfo, battery: BluetoothBattery?)
    case disconnected(BluetoothDeviceInfo)
}

/// Shows a banner when a Bluetooth device connects or disconnects, with its battery when macOS reports it.
@MainActor
final class BluetoothMonitor: NSObject {
    nonisolated static let connectSelector = #selector(deviceDidConnect(_:device:))
    nonisolated static let disconnectSelector = #selector(deviceDidDisconnect(_:device:))
    static let momentSize = CGSize(width: 300, height: 52)
    static let momentDuration: Duration = .seconds(3)
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "Bluetooth")

    private(set) var pendingBattery: Task<Void, Never>?
    private(set) var lastBattery: BluetoothBattery?

    private let moments: NotchMoments
    private let batteryReport: @Sendable () async throws -> [String: BluetoothBattery]
    private var tracker = BluetoothConnectionTracker(alreadyConnected: [])
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private let coreAudio = CoreAudioBluetoothOutputs()
    /// Nil until the first reading, which only records what is already present.
    private var audioOutputs: Set<BluetoothAudioOutput>?

    init(
        moments: NotchMoments,
        batteryReport: @escaping @Sendable () async throws -> [String: BluetoothBattery] = BluetoothBatteryReport.fetch
    ) {
        self.moments = moments
        self.batteryReport = batteryReport
        super.init()
    }

    /// The first IOBluetooth call shows the Bluetooth permission prompt.
    func start() {
        let connected = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }
        tracker = BluetoothConnectionTracker(alreadyConnected: Set(connected.compactMap { BluetoothDeviceInfo(device: $0)?.address }))
        connected.forEach(watchDisconnection)
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: Self.connectSelector)
        if connectNotification == nil {
            Self.logger.error("Couldn't observe Bluetooth connections; Bluetooth access may be denied")
        }

        audioOutputsDidChange(to: readAudioOutputs())
        coreAudio.startObserving { [weak self] in
            guard let self else { return }
            audioOutputsDidChange(to: readAudioOutputs())
        }
    }

    /// Announces audio outputs that just appeared, which is when AirPods go in or their case opens.
    /// Disappearing is silent, as it is on macOS.
    func audioOutputsDidChange(to outputs: Set<BluetoothAudioOutput>) {
        defer { audioOutputs = outputs }
        guard let previous = audioOutputs else { return }
        let previousAddresses = Set(previous.map(\.address))
        for output in outputs where !previousAddresses.contains(output.address) {
            announceConnection(BluetoothDeviceInfo(
                address: output.address,
                name: output.name,
                kind: BluetoothDeviceKind(
                    name: output.name,
                    majorClass: UInt32(kBluetoothDeviceClassMajorAudio),
                    minorClass: UInt32(kBluetoothDeviceClassMinorAudioHeadphones)
                )
            ))
        }
    }

    // IOBluetooth calls these on the main thread for classic connections but on its own queue
    // for Bluetooth LE ones, so they hop to the main actor themselves.
    @objc nonisolated func deviceDidConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        nonisolated(unsafe) let device = device
        Self.onMainActor { [self] in
            guard let info = BluetoothDeviceInfo(device: device) else { return }
            watchDisconnection(of: device)
            deviceDidConnect(info)
        }
    }

    @objc nonisolated func deviceDidDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        nonisolated(unsafe) let notification = notification
        nonisolated(unsafe) let device = device
        Self.onMainActor { [self] in
            notification.unregister()
            guard let info = BluetoothDeviceInfo(device: device) else { return }
            disconnectNotifications[info.address] = nil
            deviceDidDisconnect(info)
        }
    }

    private nonisolated static func onMainActor(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    func deviceDidConnect(_ device: BluetoothDeviceInfo) {
        guard tracker.didConnect(device.address) else { return }
        // Headphones and speakers are announced when their audio output appears, so they aren't announced twice.
        guard !device.kind.isAudio else { return }
        announceConnection(device)
    }

    /// Shows the banner at once, then adds the battery once macOS's report has been read.
    private func announceConnection(_ device: BluetoothDeviceInfo) {
        let banner = makeMoment(.connected(device, battery: nil))
        moments.present(banner)

        let report = batteryReport
        pendingBattery = Task {
            do {
                guard let battery = try await report()[device.address], !battery.isEmpty else { return }
                lastBattery = battery
                // Another banner may have replaced this one while the report was read.
                guard moments.current?.id == banner.id else { return }
                moments.present(makeMoment(.connected(device, battery: battery)))
            } catch {
                Self.logger.error("Couldn't read Bluetooth battery levels: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func deviceDidDisconnect(_ device: BluetoothDeviceInfo) {
        guard tracker.didDisconnect(device.address) else { return }
        moments.present(makeMoment(.disconnected(device)))
    }

    private func readAudioOutputs() -> Set<BluetoothAudioOutput> {
        coreAudio.current { name in
            (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
                .first { $0.name == name }
                .flatMap { BluetoothDeviceInfo(device: $0)?.address }
        }
    }

    private func watchDisconnection(of device: IOBluetoothDevice) {
        guard let address = BluetoothDeviceInfo(device: device)?.address, disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(forDisconnectNotification: self, selector: Self.disconnectSelector)
    }

    private func makeMoment(_ moment: BluetoothMoment) -> NotchMoment {
        NotchMoment(size: Self.momentSize, duration: Self.momentDuration, content: AnyView(BluetoothMomentView(moment: moment)))
    }
}
