import Darwin
import Foundation
import IOKit.ps
import os

struct CPUTicks: Equatable, Sendable {
    /// Ticks spent in user, system and nice time across all cores.
    var busy: UInt64
    var total: UInt64
}

struct MemoryReading: Equatable, Sendable {
    var usedBytes: UInt64
    var totalBytes: UInt64
}

struct NetworkBytes: Equatable, Sendable {
    var received: UInt64
    var sent: UInt64
}

struct PowerReading: Equatable, Sendable {
    var percent: Int
    var isOnAC: Bool
    var isCharging: Bool
    /// True once charging has finished, including when macOS holds the charge below 100%.
    var isCharged: Bool
}

/// Cumulative system counters; rates come from the difference between two readings.
@MainActor
protocol SystemSensors: AnyObject {
    func cpuTicks() -> CPUTicks?
    func memory() -> MemoryReading?
    func networkBytes() -> NetworkBytes?
}

/// Reads counters through public Mach and BSD interfaces. Each read is a single cheap system call.
@MainActor
final class MachSystemSensors: SystemSensors {
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "System")
    /// Network interfaces that tunnel traffic already counted on a physical interface.
    private static let tunnelPrefixes = ["utun", "ipsec", "gif", "stf"]

    /// Each `mach_host_self()` call adds a port reference, so it is taken once.
    private let host = mach_host_self()
    /// Whether each interface index is a tunnel. Looking a name up re-reads the whole interface list,
    /// so it happens once per interface rather than on every sample.
    private var tunnelByIndex: [UInt16: Bool] = [:]

    func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            Self.logger.error("Couldn't read CPU load: kern_return \(result, privacy: .public)")
            return nil
        }
        let ticks = info.cpu_ticks
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)  // user + system + nice
        return CPUTicks(busy: busy, total: busy + UInt64(ticks.2))      // + idle
    }

    func memory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            Self.logger.error("Couldn't read memory statistics: kern_return \(result, privacy: .public)")
            return nil
        }
        let used = SystemStats.memoryUsed(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(getpagesize())
        )
        return MemoryReading(usedBytes: used, totalBytes: ProcessInfo.processInfo.physicalMemory)
    }

    func networkBytes() -> NetworkBytes? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else {
            Self.logger.error("Couldn't size the interface list: errno \(errno, privacy: .public)")
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
            Self.logger.error("Couldn't read the interface list: errno \(errno, privacy: .public)")
            return nil
        }

        var total = NetworkBytes(received: 0, sent: 0)
        var seenIndices: Set<UInt16> = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                defer { offset += Int(header.ifm_msglen) }

                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length
                else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                seenIndices.insert(message.ifm_index)
                guard message.ifm_flags & IFF_UP != 0,
                      message.ifm_flags & IFF_LOOPBACK == 0,
                      !isTunnel(index: message.ifm_index)
                else { continue }
                total.received += message.ifm_data.ifi_ibytes
                total.sent += message.ifm_data.ifi_obytes
            }
        }
        // Forget interfaces that went away, so a reused index is looked up afresh.
        tunnelByIndex = tunnelByIndex.filter { seenIndices.contains($0.key) }
        return total
    }

    private func isTunnel(index: UInt16) -> Bool {
        if let known = tunnelByIndex[index] {
            return known
        }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return false }
        let interface = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let isTunnel = Self.tunnelPrefixes.contains { interface.hasPrefix($0) }
        tunnelByIndex[index] = isTunnel
        return isTunnel
    }
}

/// The internal battery, read through IOKit's power-source interface.
@MainActor
final class IOKitPowerSource {
    private static let logger = Logger(subsystem: "app.arysha.NotAnIsland", category: "System")

    private var onChange: (@MainActor () -> Void)?
    private var runLoopSource: CFRunLoopSource?

    /// Nil on Macs without a battery.
    func read() -> PowerReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }
            return PowerReading(
                percent: current * 100 / maximum,
                isOnAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false
            )
        }
        return nil
    }

    /// Calls `onChange` whenever macOS reports a power-source change. Nothing runs between changes.
    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let powerSource = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
            // The source is added to the main run loop, so this callback runs on the main thread.
            MainActor.assumeIsolated { powerSource.onChange?() }
        }, context)?.takeRetainedValue() else {
            Self.logger.error("Couldn't observe power-source changes")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }
}
