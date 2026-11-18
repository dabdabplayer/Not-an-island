import CoreAudio
import Observation
import os

/// One audio device as CoreAudio describes it, before deciding whether it belongs in the output list.
struct AudioDeviceDescription: Equatable, Sendable {
    var id: AudioObjectID
    var name: String
    var transportType: UInt32
    var hasOutput: Bool
    var isHidden: Bool
    var canBeDefaultOutput: Bool
}

/// An output the user can switch sound to.
struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    var id: AudioObjectID
    var name: String
    var transportType: UInt32

    /// The outputs macOS offers in its Sound menu: built-in first, then by name.
    static func outputs(from descriptions: [AudioDeviceDescription]) -> [AudioOutputDevice] {
        descriptions
            .filter { $0.hasOutput && !$0.isHidden && $0.canBeDefaultOutput }
            .map { AudioOutputDevice(id: $0.id, name: $0.name, transportType: $0.transportType) }
            .sorted { first, second in
                let firstBuiltIn = first.transportType == kAudioDeviceTransportTypeBuiltIn
                let secondBuiltIn = second.transportType == kAudioDeviceTransportTypeBuiltIn
                if firstBuiltIn != secondBuiltIn { return firstBuiltIn }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    var symbolName: String {
        let name = name.lowercased()
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if name.contains("airpods max") { return "airpods.max" }
            if name.contains("airpods pro") { return "airpods.pro" }
            if name.contains("airpods") { return "airpods" }
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return name.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay.audio"
        default:
            return "hifispeaker"
        }
    }
}

struct AudioOutputError: Error {
    let status: OSStatus
}

@MainActor
protocol AudioOutputSystem: AnyObject {
    func devices() -> [AudioDeviceDescription]
    func defaultOutputID() -> AudioObjectID?
    func setDefaultOutput(_ id: AudioObjectID) throws
    /// Calls `onChange` whenever devices come and go or the default output changes.
    func observeChanges(_ onChange: @escaping @MainActor () -> Void)
}

/// The audio outputs and which one is in use. Switching changes the system's default output,
/// as the Sound menu in Control Center does, so every app's sound moves with it.
@MainActor
@Observable
final class AudioOutputs {
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "AudioOutputs")

    private(set) var devices: [AudioOutputDevice] = []
    private(set) var currentID: AudioObjectID?

    @ObservationIgnored private let system: any AudioOutputSystem

    var current: AudioOutputDevice? { devices.first { $0.id == currentID } }

    init(system: any AudioOutputSystem = CoreAudioOutputSystem()) {
        self.system = system
    }

    func start() {
        refresh()
        system.observeChanges { [weak self] in self?.refresh() }
    }

    func select(_ device: AudioOutputDevice) {
        do {
            try system.setDefaultOutput(device.id)
        } catch {
            Self.logger.error("Couldn't switch sound to \(device.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        // Show what's actually in use, whether or not the switch went through.
        refresh()
    }

    private func refresh() {
        devices = AudioOutputDevice.outputs(from: system.devices())
        currentID = system.defaultOutputID()
    }
}

/// Lists and switches outputs through CoreAudio, and is notified of changes rather than polling.
@MainActor
final class CoreAudioOutputSystem: AudioOutputSystem {
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "AudioOutputs")
    private static let observedProperties = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]

    private var listener: AudioObjectPropertyListenerBlock?

    func devices() -> [AudioDeviceDescription] {
        guard let ids = CoreAudioProperties.deviceIDs() else {
            Self.logger.error("Couldn't list audio devices")
            return []
        }
        return ids.compactMap { id in
            guard let name = CoreAudioProperties.string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDeviceDescription(
                id: id,
                name: name,
                transportType: CoreAudioProperties.uint32(id, kAudioDevicePropertyTransportType) ?? 0,
                hasOutput: CoreAudioProperties.hasOutput(id),
                isHidden: CoreAudioProperties.uint32(id, kAudioDevicePropertyIsHidden) == 1,
                canBeDefaultOutput: CoreAudioProperties.uint32(
                    id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput
                ) == 1
            )
        }
    }

    func defaultOutputID() -> AudioObjectID? {
        guard let id = CoreAudioProperties.uint32(CoreAudioProperties.system, kAudioHardwarePropertyDefaultOutputDevice),
              id != kAudioObjectUnknown
        else {
            Self.logger.error("Couldn't read the default output device")
            return nil
        }
        return id
    }

    func setDefaultOutput(_ id: AudioObjectID) throws {
        var address = CoreAudioProperties.globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = id
        let status = AudioObjectSetPropertyData(
            CoreAudioProperties.system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id
        )
        guard status == noErr else { throw AudioOutputError(status: status) }
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            // Registered on the main queue below.
            MainActor.assumeIsolated { onChange() }
        }
        for selector in Self.observedProperties {
            var address = CoreAudioProperties.globalAddress(selector)
            let status = AudioObjectAddPropertyListenerBlock(CoreAudioProperties.system, &address, .main, listener)
            if status != noErr {
                Self.logger.error("Couldn't observe audio property \(selector, privacy: .public): OSStatus \(status, privacy: .public)")
            }
        }
        self.listener = listener
    }
}
