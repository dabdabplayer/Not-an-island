import CoreAudio
import Testing
@testable import NotAnIsland

@MainActor
final class FakeAudioOutputSystem: AudioOutputSystem {
    var descriptions: [AudioDeviceDescription] = []
    var defaultID: AudioObjectID?
    var failsToSetDefault = false
    private(set) var setRequests: [AudioObjectID] = []
    private(set) var onChange: (@MainActor () -> Void)?

    func devices() -> [AudioDeviceDescription] { descriptions }
    func defaultOutputID() -> AudioObjectID? { defaultID }

    func setDefaultOutput(_ id: AudioObjectID) throws {
        setRequests.append(id)
        if failsToSetDefault { throw AudioOutputError(status: -50) }
        defaultID = id
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }
}

enum AudioDevices {
    static let speakers = AudioDeviceDescription(
        id: 10, name: "MacBook Pro Speakers", transportType: kAudioDeviceTransportTypeBuiltIn,
        hasOutput: true, isHidden: false, canBeDefaultOutput: true
    )
    static let microphone = AudioDeviceDescription(
        id: 11, name: "MacBook Pro Microphone", transportType: kAudioDeviceTransportTypeBuiltIn,
        hasOutput: false, isHidden: false, canBeDefaultOutput: false
    )
    static let airPods = AudioDeviceDescription(
        id: 20, name: "Aarav’s AirPods", transportType: kAudioDeviceTransportTypeBluetooth,
        hasOutput: true, isHidden: false, canBeDefaultOutput: true
    )
    static let display = AudioDeviceDescription(
        id: 30, name: "Dell U2723QE", transportType: kAudioDeviceTransportTypeDisplayPort,
        hasOutput: true, isHidden: false, canBeDefaultOutput: true
    )
    static let hidden = AudioDeviceDescription(
        id: 40, name: "CADefaultDeviceAggregate", transportType: kAudioDeviceTransportTypeAggregate,
        hasOutput: true, isHidden: true, canBeDefaultOutput: true
    )
    static let notDefaultable = AudioDeviceDescription(
        id: 50, name: "Some Driver", transportType: kAudioDeviceTransportTypeVirtual,
        hasOutput: true, isHidden: false, canBeDefaultOutput: false
    )
}

struct AudioOutputDeviceTests {
    @Test func listsOnlyOutputsMacOSOffersAsDefault() {
        let outputs = AudioOutputDevice.outputs(from: [
            AudioDevices.microphone, AudioDevices.hidden, AudioDevices.notDefaultable,
            AudioDevices.airPods, AudioDevices.speakers,
        ])
        #expect(outputs.map(\.id) == [10, 20])
    }

    @Test func builtInComesFirstThenByName() {
        let outputs = AudioOutputDevice.outputs(from: [AudioDevices.display, AudioDevices.airPods, AudioDevices.speakers])
        #expect(outputs.map(\.name) == ["MacBook Pro Speakers", "Aarav’s AirPods", "Dell U2723QE"])
    }

    @Test(arguments: [
        ("Aarav’s AirPods", kAudioDeviceTransportTypeBluetooth, "airpods"),
        ("AirPods Pro", kAudioDeviceTransportTypeBluetooth, "airpods.pro"),
        ("AirPods Max", kAudioDeviceTransportTypeBluetoothLE, "airpods.max"),
        ("WH-1000XM5", kAudioDeviceTransportTypeBluetooth, "headphones"),
        ("MacBook Pro Speakers", kAudioDeviceTransportTypeBuiltIn, "laptopcomputer"),
        ("External Headphones", kAudioDeviceTransportTypeBuiltIn, "headphones"),
        ("LG TV", kAudioDeviceTransportTypeHDMI, "display"),
        ("Dell U2723QE", kAudioDeviceTransportTypeDisplayPort, "display"),
        ("Living Room", kAudioDeviceTransportTypeAirPlay, "airplay.audio"),
        ("USB DAC", kAudioDeviceTransportTypeUSB, "hifispeaker"),
    ])
    func symbolMatchesTheKindOfDevice(name: String, transport: UInt32, symbol: String) {
        #expect(AudioOutputDevice(id: 1, name: name, transportType: transport).symbolName == symbol)
    }
}

@MainActor
struct AudioOutputsTests {
    private let system = FakeAudioOutputSystem()

    private func makeOutputs() -> AudioOutputs {
        system.descriptions = [AudioDevices.speakers, AudioDevices.airPods]
        system.defaultID = 20
        let outputs = AudioOutputs(system: system)
        outputs.start()
        return outputs
    }

    @Test func startReadsDevicesAndTheCurrentOutput() {
        let outputs = makeOutputs()
        #expect(outputs.devices.map(\.id) == [10, 20])
        #expect(outputs.current?.name == "Aarav’s AirPods")
    }

    @Test func followsChangesMadeElsewhere() {
        let outputs = makeOutputs()
        system.descriptions = [AudioDevices.speakers]
        system.defaultID = 10
        system.onChange?()
        #expect(outputs.devices.map(\.id) == [10])
        #expect(outputs.current?.id == 10)
    }

    @Test func selectingSwitchesTheSystemOutput() throws {
        let outputs = makeOutputs()
        let speakers = try #require(outputs.devices.first)
        outputs.select(speakers)
        #expect(system.setRequests == [10])
        #expect(outputs.current?.id == 10)
    }

    @Test func refusedSwitchKeepsTheOutputInUse() throws {
        let outputs = makeOutputs()
        system.failsToSetDefault = true
        outputs.select(try #require(outputs.devices.first))
        #expect(outputs.current?.id == 20)
    }
}

@MainActor
struct MusicOutputPickerTests {
    private let system = FakeAudioOutputSystem()

    private func makeActivity(devices: [AudioDeviceDescription]) -> MusicActivity {
        system.descriptions = devices
        system.defaultID = devices.first?.id
        let outputs = AudioOutputs(system: system)
        outputs.start()
        return MusicActivity(scripting: FakeMusicScripting(), musicProcessID: { nil }, outputs: outputs)
    }

    @Test func closedPickerKeepsTheUsualHeight() {
        let activity = makeActivity(devices: [AudioDevices.speakers, AudioDevices.airPods])
        #expect(activity.metrics.expandedSectionSize?.height == MusicActivity.expandedHeight)
    }

    @Test func openPickerGrowsByItsRows() {
        let activity = makeActivity(devices: [AudioDevices.speakers, AudioDevices.airPods])
        activity.toggleOutputPicker()
        #expect(activity.isOutputPickerOpen)
        #expect(activity.metrics.expandedSectionSize?.height == MusicActivity.expandedHeight + MusicActivity.outputPickerHeight(rows: 2))
        #expect(MusicActivity.outputPickerHeight(rows: 2) > MusicActivity.outputPickerHeight(rows: 1))
    }

    @Test func longListsScrollInsteadOfGrowingForever() {
        #expect(MusicActivity.outputPickerHeight(rows: 12) == MusicActivity.outputPickerHeight(rows: MusicActivity.maxVisibleOutputRows))
    }

    @Test func togglingAgainCloses() {
        let activity = makeActivity(devices: [AudioDevices.speakers])
        activity.toggleOutputPicker()
        activity.toggleOutputPicker()
        #expect(!activity.isOutputPickerOpen)
    }

    @Test func collapsingTheNotchClosesThePicker() {
        let activity = makeActivity(devices: [AudioDevices.speakers])
        activity.toggleOutputPicker()
        activity.notchDidChangeExpansion(false)
        #expect(!activity.isOutputPickerOpen)
    }

    @Test func choosingAnOutputSwitchesAndCloses() throws {
        let activity = makeActivity(devices: [AudioDevices.speakers, AudioDevices.airPods])
        activity.toggleOutputPicker()
        activity.selectOutput(try #require(activity.outputs.devices.last))
        #expect(system.setRequests == [20])
        #expect(activity.outputs.current?.id == 20)
        #expect(!activity.isOutputPickerOpen)
    }
}
