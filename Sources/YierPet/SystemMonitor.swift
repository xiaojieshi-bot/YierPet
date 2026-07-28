import Foundation
import IOKit.ps

/// Zero-permission system metrics sampler: CPU load, memory pressure,
/// battery state and free disk space. Pure native APIs, no subprocesses.
final class SystemMonitor {

    struct BatteryState {
        let percent: Int
        let isCharging: Bool
        let onACPower: Bool
    }

    // MARK: - CPU

    private var lastTicks:
        (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    /// Total CPU usage 0...1 averaged since the previous call.
    /// The first call establishes a baseline and returns 0.
    func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size
                / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { lastTicks = t }
        guard let l = lastTicks else { return 0 }
        let used = (t.user &- l.user) + (t.system &- l.system)
            + (t.nice &- l.nice)
        let total = used + (t.idle &- l.idle)
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    // MARK: - Memory pressure (event driven)

    private(set) var memoryPressureWarning = false
    private(set) var memoryPressureCritical = false
    private var pressureSource: DispatchSourceMemoryPressure?

    func startMemoryPressureWatch() {
        guard pressureSource == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self, let src = self.pressureSource else { return }
            let event = src.data
            if event.contains(.critical) {
                self.memoryPressureCritical = true
                self.memoryPressureWarning = true
            } else if event.contains(.warning) {
                self.memoryPressureCritical = false
                self.memoryPressureWarning = true
            } else {
                self.memoryPressureCritical = false
                self.memoryPressureWarning = false
            }
        }
        src.resume()
        pressureSource = src
    }

    // MARK: - Battery

    /// nil when the machine has no internal battery (desktop Macs).
    func batteryState() -> BatteryState? {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard
                let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                let type = desc[kIOPSTypeKey] as? String,
                type == kIOPSInternalBatteryType,
                let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let state = desc[kIOPSPowerSourceStateKey] as? String
            return BatteryState(
                percent: Int(Double(cur) / Double(max) * 100),
                isCharging: charging,
                onACPower: state == kIOPSACPowerValue
            )
        }
        return nil
    }

    // MARK: - Disk

    /// Free ratio (0...1) and free gigabytes of the root volume.
    func diskFree() -> (ratio: Double, freeGB: Double)? {
        let url = URL(fileURLWithPath: "/")
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey,
            ]),
            let free = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        return (Double(free) / Double(total), Double(free) / 1_000_000_000)
    }
}
