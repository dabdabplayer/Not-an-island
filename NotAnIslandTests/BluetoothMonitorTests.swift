import AppKit
import SwiftUI
import Testing
@testable import NotAnIsland

/// Shaped like `system_profiler SPBluetoothDataType -json` on macOS 27.2 (address replaced, serials removed).
/// Only `device_batteryLevelLeft` was present in the recorded report; the other battery keys are included
/// on the second device to cover the remaining fields.
private let recordedReport = Data("""
{
  "SPBluetoothDataType" : [
    {
      "controller_properties" : {},
      "device_connected" : [
        {
          "Aarav’s AirPods" : {
            "device_address" : "AA:BB:CC:DD:EE:10",
            "device_batteryLevelLeft" : "86%",
            "device_minorType" : "Headphones",
            "device_productID" : "0x2019",
            "device_vendorID" : "0x004C"
          }
        },
        {
          "Magic Mouse" : {
            "device_address" : "AA:BB:CC:DD:EE:20",
            "device_batteryLevelMain" : "41%"
          }
        },
        {
          "Studio Buds" : {
            "device_address" : "AA:BB:CC:DD:EE:30",
            "device_batteryLevelLeft" : "70%",
            "device_batteryLevelRight" : "72%",
            "device_batteryLevelCase" : "55%"
          }
        }
      ],
      "device_not_connected" : [
        { "Aarav’s iPhone 15" : { "device_address" : "AA:BB:CC:DD:EE:1B" } }
      ]
    }
  ]
}
""".utf8)

struct BluetoothBatteryReportTests {
    @Test func readsTheBatteryFieldsEachDeviceReports() throws {
        let batteries = try BluetoothBatteryReport.parse(recordedReport)

        #expect(batteries["aa:bb:cc:dd:ee:10"] == BluetoothBattery(left: 86))
        #expect(batteries["aa:bb:cc:dd:ee:20"] == BluetoothBattery(main: 41))
        #expect(batteries["aa:bb:cc:dd:ee:30"] == BluetoothBattery(left: 70, right: 72, caseLevel: 55))
    }

    @Test func devicesWithoutBatteryInformationAreLeftOut() throws {
        #expect(try BluetoothBatteryReport.parse(recordedReport)["aa:bb:cc:dd:ee:1b"] == nil)
    }

    // IOBluetooth writes addresses as "aa-bb-cc-dd-ee-ff"; the report uses "AA:BB:CC:DD:EE:FF".
    @Test func addressesMatchAcrossBothFormats() {
        #expect(BluetoothBatteryReport.normalizedAddress("AA-BB-CC-DD-EE-10") == "aa:bb:cc:dd:ee:10")
        #expect(BluetoothBatteryReport.normalizedAddress("AA:BB:CC:DD:EE:10") == "aa:bb:cc:dd:ee:10")
    }

    @Test func unreadableReportIsAnError() {
        #expect(throws: (any Error).self) { try BluetoothBatteryReport.parse(Data("not json".utf8)) }
    }
}

struct BluetoothConnectionTrackerTests {
    @Test func devicesConnectedAtLaunchAreNotAnnounced() {
        var tracker = BluetoothConnectionTracker(alreadyConnected: ["aa"])
        let announced = tracker.didConnect("aa")
        #expect(!announced)
    }

    @Test func newConnectionsAndDisconnectionsAreAnnouncedOnce() {
        var tracker = BluetoothConnectionTracker(alreadyConnected: [])
        let results = [
            tracker.didConnect("aa"),
            tracker.didConnect("aa"),
            tracker.didDisconnect("aa"),
            tracker.didDisconnect("aa"),
            tracker.didConnect("aa"),
        ]
        #expect(results == [true, false, true, false, true])
    }
}

struct BluetoothDeviceKindTests {
    @Test func appleHeadphonesAreRecognisedByName() {
        #expect(BluetoothDeviceKind(name: "Aarav’s AirPods", majorClass: 0x04, minorClass: 0x06) == .airPods)
        #expect(BluetoothDeviceKind(name: "AirPods Pro", majorClass: 0x04, minorClass: 0x06) == .airPodsPro)
        #expect(BluetoothDeviceKind(name: "AirPods Max", majorClass: 0x04, minorClass: 0x06) == .airPodsMax)
    }

    @Test func otherDevicesAreRecognisedByTheirBluetoothClass() {
        #expect(BluetoothDeviceKind(name: "WH-1000XM5", majorClass: 0x04, minorClass: 0x06) == .headphones)
        #expect(BluetoothDeviceKind(name: "Boom", majorClass: 0x04, minorClass: 0x05) == .speaker)
        #expect(BluetoothDeviceKind(name: "Keys", majorClass: 0x05, minorClass: 0x10) == .keyboard)
        #expect(BluetoothDeviceKind(name: "Mouse", majorClass: 0x05, minorClass: 0x20) == .mouse)
        #expect(BluetoothDeviceKind(name: "Magic Trackpad", majorClass: 0x05, minorClass: 0x20) == .trackpad)
        #expect(BluetoothDeviceKind(name: "Pad", majorClass: 0x05, minorClass: 0x02) == .gameController)
        #expect(BluetoothDeviceKind(name: "Thing", majorClass: 0x01, minorClass: 0x00) == .other)
    }

    @Test func everyKindHasASymbol() {
        for kind in BluetoothDeviceKind.allCases {
            #expect(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) != nil, "\(kind)")
        }
    }
}

@MainActor
struct BluetoothMonitorTests {
    private final class Recorder {
        var shown: [NotchMoment] = []
    }

    private let recorder = Recorder()
    // Headphones are announced through their audio device; Bluetooth connection banners cover everything else.
    private let airPods = BluetoothDeviceInfo(address: "aa:bb:cc:dd:ee:10", name: "Magic Mouse", kind: .mouse)

    private func makeMonitor(report: @escaping @Sendable () async throws -> [String: BluetoothBattery]) -> (BluetoothMonitor, NotchMoments) {
        let recorder = recorder
        // Moments stay up until replaced, so the test sees every banner.
        let moments = NotchMoments(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        moments.onChange = { if let moment = $0 { recorder.shown.append(moment) } }
        return (BluetoothMonitor(moments: moments, batteryReport: report), moments)
    }

    @Test func connectingShowsABannerAtOnceThenAddsTheBattery() async {
        let (monitor, moments) = makeMonitor { ["aa:bb:cc:dd:ee:10": BluetoothBattery(left: 86)] }
        monitor.deviceDidConnect(airPods)

        #expect(recorder.shown.count == 1)
        await monitor.pendingBattery?.value

        #expect(recorder.shown.count == 2)
        #expect(moments.current?.id == recorder.shown.last?.id)
        #expect(monitor.lastBattery == BluetoothBattery(left: 86))
    }

    @Test func noBatteryInTheReportKeepsTheFirstBanner() async {
        let (monitor, _) = makeMonitor { [:] }
        monitor.deviceDidConnect(airPods)
        await monitor.pendingBattery?.value

        #expect(recorder.shown.count == 1)
    }

    // A failed report is logged and the banner simply stays without a battery.
    @Test func failedReportKeepsTheFirstBanner() async {
        let (monitor, _) = makeMonitor { throw CocoaError(.fileReadUnknown) }
        monitor.deviceDidConnect(airPods)
        await monitor.pendingBattery?.value

        #expect(recorder.shown.count == 1)
    }

    // Another banner (say, a charger connecting) may have replaced this one while the report was read.
    @Test func batteryNeverOverwritesADifferentBanner() async {
        let (monitor, moments) = makeMonitor { ["aa:bb:cc:dd:ee:10": BluetoothBattery(left: 86)] }
        monitor.deviceDidConnect(airPods)
        let other = NotchMoment(size: CGSize(width: 200, height: 44), duration: .seconds(3), content: AnyView(EmptyView()))
        moments.present(other)
        await monitor.pendingBattery?.value

        #expect(moments.current?.id == other.id)
    }

    @Test func disconnectingShowsABanner() async {
        let (monitor, _) = makeMonitor { [:] }
        monitor.deviceDidConnect(airPods)
        await monitor.pendingBattery?.value
        monitor.deviceDidDisconnect(airPods)

        #expect(recorder.shown.count == 2)
    }

    // A disconnect for a device that was never seen connecting (for example, before launch) is ignored.
    @Test func unknownDisconnectIsIgnored() {
        let (monitor, _) = makeMonitor { [:] }
        monitor.deviceDidDisconnect(airPods)
        #expect(recorder.shown.isEmpty)
    }

    // AppKit calls these by Objective-C selector, so their names must match exactly what is registered.
    @Test func notificationHandlersHaveTheRegisteredSelectors() {
        #expect(NSStringFromSelector(BluetoothMonitor.connectSelector) == "deviceDidConnect:device:")
        #expect(NSStringFromSelector(BluetoothMonitor.disconnectSelector) == "deviceDidDisconnect:device:")
        let (monitor, _) = makeMonitor { [:] }
        #expect(monitor.responds(to: BluetoothMonitor.connectSelector))
        #expect(monitor.responds(to: BluetoothMonitor.disconnectSelector))
    }
}

/// Runs macOS's real Bluetooth report to catch mistakes in launching and reading it.
struct BluetoothBatteryReportSmokeTests {
    @Test func realReportCanBeReadAndParsed() async throws {
        let batteries = try await BluetoothBatteryReport.fetch()
        for battery in batteries.values {
            for level in [battery.left, battery.right, battery.caseLevel, battery.main].compactMap(\.self) {
                #expect((0...100).contains(level))
            }
        }
    }
}

struct BluetoothAudioOutputTests {
    // macOS names Bluetooth audio devices after their address, e.g. "AA-BB-CC-DD-EE-10:output".
    @Test func addressIsReadFromTheAudioDeviceUID() {
        #expect(BluetoothAudioOutput.address(fromUID: "AA-BB-CC-DD-EE-10:output") == "aa:bb:cc:dd:ee:10")
        #expect(BluetoothAudioOutput.address(fromUID: "aa:bb:cc:dd:ee:10:input") == "aa:bb:cc:dd:ee:10")
        #expect(BluetoothAudioOutput.address(fromUID: "BuiltInSpeakerDevice") == nil)
    }

    @Test func ringShowsTheLowerBudOrTheOnlyBattery() {
        #expect(BluetoothBattery(left: 86, right: 75, caseLevel: 40).ringLevel == 75)
        #expect(BluetoothBattery(left: 86).ringLevel == 86)
        #expect(BluetoothBattery(main: 41).ringLevel == 41)
        #expect(BluetoothBattery(caseLevel: 60).ringLevel == 60)
        #expect(BluetoothBattery().ringLevel == nil)
    }
}

@MainActor
struct BluetoothAudioMonitorTests {
    private final class Recorder {
        var shown: [NotchMoment] = []
    }

    private let recorder = Recorder()
    private let airPods = BluetoothAudioOutput(address: "aa:bb:cc:dd:ee:10", name: "Aarav’s AirPods")

    private func makeMonitor() -> BluetoothMonitor {
        let recorder = recorder
        let moments = NotchMoments(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        moments.onChange = { if let moment = $0 { recorder.shown.append(moment) } }
        return BluetoothMonitor(moments: moments, batteryReport: { ["aa:bb:cc:dd:ee:10": BluetoothBattery(left: 75)] })
    }

    // Putting AirPods in makes their audio device appear, which is when macOS shows its popup.
    @Test func audioDeviceAppearingShowsAConnectedBanner() async {
        let monitor = makeMonitor()
        monitor.audioOutputsDidChange(to: [])
        monitor.audioOutputsDidChange(to: [airPods])
        await monitor.pendingBattery?.value

        #expect(recorder.shown.count == 2)  // At once, then with the battery.
        #expect(monitor.lastBattery == BluetoothBattery(left: 75))
    }

    @Test func audioDevicesPresentAtLaunchAreNotAnnounced() {
        let monitor = makeMonitor()
        monitor.audioOutputsDidChange(to: [airPods])
        #expect(recorder.shown.isEmpty)
    }

    // Taking them out shows nothing, as on macOS; putting them back announces again.
    @Test func takingThemOutIsSilentAndPuttingThemBackAnnouncesAgain() async {
        let monitor = makeMonitor()
        monitor.audioOutputsDidChange(to: [airPods])
        monitor.audioOutputsDidChange(to: [])
        #expect(recorder.shown.isEmpty)

        monitor.audioOutputsDidChange(to: [airPods])
        await monitor.pendingBattery?.value
        #expect(!recorder.shown.isEmpty)
    }

    // Headphones are announced when their audio appears, so the Bluetooth connection itself stays quiet.
    @Test func headphonesConnectingOverBluetoothDoNotAnnounceTwice() {
        let monitor = makeMonitor()
        monitor.deviceDidConnect(BluetoothDeviceInfo(address: "aa:bb:cc:dd:ee:10", name: "Aarav’s AirPods", kind: .airPods))
        #expect(recorder.shown.isEmpty)
    }

    @Test func otherDevicesStillAnnounceTheirBluetoothConnection() {
        let monitor = makeMonitor()
        monitor.deviceDidConnect(BluetoothDeviceInfo(address: "aa:bb:cc:dd:ee:20", name: "Magic Mouse", kind: .mouse))
        #expect(recorder.shown.count == 1)
    }
}
