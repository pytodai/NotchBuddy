import Darwin
import Foundation
import IOKit.ps

// MARK: - Battery

/// The internal battery, as `IOPowerSources` describes it.
public struct BatteryState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// On battery power.
        case discharging
        /// Plugged in and charging.
        case charging
        /// Plugged in, not charging, below full: the charge limit or Optimized Charging holds it.
        case onHold
        /// Plugged in and full.
        case full
    }

    /// 0…100.
    public var percent: Int
    /// Plugged into power.
    public var onAC: Bool
    public var charging: Bool
    /// The system reports it fully charged.
    public var charged: Bool
    /// Minutes to empty (on battery) once the system has an estimate.
    public var minutesToEmpty: Int?
    /// Minutes to full (charging) once the system has an estimate.
    public var minutesToFull: Int?
    /// Low Power Mode (from `ProcessInfo`, not the power source).
    public var lowPowerMode: Bool

    public init(percent: Int, onAC: Bool, charging: Bool, charged: Bool = false, minutesToEmpty: Int? = nil,
                minutesToFull: Int? = nil, lowPowerMode: Bool = false) {
        self.percent = min(max(percent, 0), 100)
        self.onAC = onAC
        self.charging = charging
        self.charged = charged
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.lowPowerMode = lowPowerMode
    }

    public var phase: Phase {
        if !onAC { return .discharging }
        if charging { return .charging }
        if charged || percent >= 100 { return .full }
        return .onHold
    }

    public var fraction: Double { Double(percent) / 100 }

    /// The time estimate that fits the phase (minutes), if the system has one.
    public var minutesLeft: Int? {
        switch phase {
        case .discharging: return minutesToEmpty
        case .charging: return minutesToFull
        case .onHold, .full: return nil
        }
    }

    /// Reads one power source description (`IOPSGetPowerSourceDescription`). Nil for anything that is not a
    /// present internal battery with a capacity.
    public static func parse(_ d: [String: Any], lowPowerMode: Bool = false) -> BatteryState? {
        guard d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              (d[kIOPSIsPresentKey] as? Bool) ?? true,
              let current = int(d[kIOPSCurrentCapacityKey]), let max = int(d[kIOPSMaxCapacityKey]), max > 0
        else { return nil }
        let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        // Minutes; -1 (or 0 on some Macs) while the system is still estimating.
        func minutes(_ key: String) -> Int? { int(d[key]).flatMap { $0 > 0 && $0 < 60 * 72 ? $0 : nil } }
        let percent = Int((Double(current) * 100 / Double(max)).rounded())
        return BatteryState(percent: percent, onAC: onAC, charging: charging,
                            charged: (d[kIOPSIsChargedKey] as? Bool) ?? false,
                            minutesToEmpty: onAC ? nil : minutes(kIOPSTimeToEmptyKey),
                            minutesToFull: charging ? minutes(kIOPSTimeToFullChargeKey) : nil,
                            lowPowerMode: lowPowerMode)
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    /// The internal battery right now; nil on a Mac without one.
    public static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let state = parse(d, lowPowerMode: lowPower) { return state }
        }
        return nil
    }
}

/// Something about the battery worth a notice.
public enum BatteryEvent: Equatable, Sendable {
    /// Fell to the low threshold on battery power.
    case low(percent: Int)
    /// Fell to the critical level on battery power.
    case critical(percent: Int)
    /// Plugged in (charging or held by the charge limit).
    case pluggedIn(percent: Int, charging: Bool)
    /// Unplugged.
    case unplugged(percent: Int)
    /// Finished charging while plugged in.
    case full
}

/// When the battery deserves the island's attention: pure rules over two readings.
public struct BatteryAlertPolicy: Equatable, Sendable {
    /// Low at or below this, on battery.
    public var threshold: Int
    /// Critical at or below this, on battery.
    public var critical: Int

    public init(threshold: Int = 20, critical: Int = 10) {
        self.threshold = min(max(threshold, 1), 99)
        self.critical = min(max(critical, 1), self.threshold)
    }

    /// The closed island shows the battery (a live activity) while this holds.
    public func isLow(_ state: BatteryState?) -> Bool {
        guard let state, !state.onAC else { return false }
        return state.percent <= threshold
    }

    public func isCritical(_ state: BatteryState?) -> Bool {
        guard let state, !state.onAC else { return false }
        return state.percent <= critical
    }

    /// What changed between two readings. The first reading (`old` nil) reports nothing: a Mac that starts on a
    /// low battery shows the live activity (`isLow`) without a notice or a sound.
    public func events(from old: BatteryState?, to new: BatteryState) -> [BatteryEvent] {
        guard let old else { return [] }
        var events: [BatteryEvent] = []
        if new.onAC && !old.onAC {
            events.append(.pluggedIn(percent: new.percent, charging: new.charging || new.phase == .full))
        } else if !new.onAC && old.onAC {
            events.append(.unplugged(percent: new.percent))
        }
        if !new.onAC {
            // Crossing downward only (a reading at the same level again, or going up, says nothing).
            let wasCritical = !old.onAC && old.percent <= critical
            let wasLow = !old.onAC && old.percent <= threshold
            if new.percent <= critical && !wasCritical {
                events.append(.critical(percent: new.percent))
            } else if new.percent <= threshold && !wasLow {
                events.append(.low(percent: new.percent))
            }
        }
        if new.onAC && old.onAC && new.phase == .full && old.phase == .charging {
            events.append(.full)
        }
        return events
    }
}

// MARK: - CPU

/// Cumulative CPU ticks of the whole machine (`HOST_CPU_LOAD_INFO`). The kernel counts them in 32 bits, so
/// they wrap; deltas are taken modulo 2³².
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public static func read() -> CPUTicks? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: load.cpu_ticks.0, system: load.cpu_ticks.1, idle: load.cpu_ticks.2, nice: load.cpu_ticks.3)
    }
}

public enum CPULoad {
    /// Busy share of all cores between two readings (0…1); nil when no time passed.
    public static func usage(from a: CPUTicks, to b: CPUTicks) -> Double? {
        let user = UInt64(b.user &- a.user), system = UInt64(b.system &- a.system)
        let idle = UInt64(b.idle &- a.idle), nice = UInt64(b.nice &- a.nice)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return min(max(Double(busy) / Double(total), 0), 1)
    }

    /// Exponential smoothing so the gauge does not jitter (`alpha` = weight of the new sample).
    public static func smoothed(_ previous: Double?, _ sample: Double, alpha: Double = 0.5) -> Double {
        guard let previous, previous.isFinite else { return sample }
        return previous + (sample - previous) * min(max(alpha, 0), 1)
    }

    /// Logical cores.
    public static var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }
}

// MARK: - Memory

/// Memory in use the way Activity Monitor counts it: app memory (internal − purgeable) + wired + compressed.
public struct MemoryUsage: Equatable, Sendable {
    public enum Pressure: Int, Equatable, Sendable {
        case normal = 1, warning = 2, critical = 4
    }

    public var used: UInt64
    public var total: UInt64
    public var pressure: Pressure
    public var swapUsed: UInt64

    public init(used: UInt64, total: UInt64, pressure: Pressure = .normal, swapUsed: UInt64 = 0) {
        self.used = min(used, total)
        self.total = total
        self.pressure = pressure
        self.swapUsed = swapUsed
    }

    public var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// From page counts (`vm_statistics64`).
    public static func compute(pageSize: UInt64, internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                               compressedPages: UInt64, total: UInt64, pressure: Pressure = .normal,
                               swapUsed: UInt64 = 0) -> MemoryUsage {
        let app = internalPages >= purgeablePages ? internalPages - purgeablePages : 0
        let (pages, overflow) = (app + wiredPages).addingReportingOverflow(compressedPages)
        let (bytes, overflow2) = pages.multipliedReportingOverflow(by: pageSize)
        return MemoryUsage(used: overflow || overflow2 ? total : bytes, total: total, pressure: pressure, swapUsed: swapUsed)
    }

    public static func read() -> MemoryUsage? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return compute(pageSize: UInt64(vm_kernel_page_size), internalPages: UInt64(vm.internal_page_count),
                       purgeablePages: UInt64(vm.purgeable_count), wiredPages: UInt64(vm.wire_count),
                       compressedPages: UInt64(vm.compressor_page_count), total: ProcessInfo.processInfo.physicalMemory,
                       pressure: pressureLevel(), swapUsed: swapUsed())
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    static func pressureLevel() -> Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return Pressure(rawValue: Int(level)) ?? .normal
    }

    static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
}

// MARK: - Disk

/// Free space on the startup volume.
public struct DiskUsage: Equatable, Sendable {
    /// What apps can still write ("available for important usage", purgeable space included, like Finder).
    public var free: Int64
    public var total: Int64

    public init(free: Int64, total: Int64) {
        self.total = max(total, 0)
        self.free = min(max(free, 0), self.total)
    }

    public var used: Int64 { total - free }
    public var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func read(path: String = "/") -> DiskUsage? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
        return DiskUsage(free: free, total: Int64(total))
    }
}

// MARK: - Format

/// Russian short forms for the system widget: "14,2 ГБ", "2 ч 15 мин", "23 %".
public enum SystemFormat {
    private static let nbsp = "\u{00A0}"

    /// Memory sizes count in 1024s (a 24 GB Mac has 24 "ГБ"), disks in 1000s (like Finder).
    public static func bytes(_ value: Int64, binary: Bool) -> String {
        let base: Double = binary ? 1024 : 1000
        let units = [L("Б"), L("КБ"), L("МБ"), L("ГБ"), L("ТБ"), L("ПБ")]
        var amount = Double(max(value, 0))
        var unit = 0
        while amount >= base * 0.995 && unit < units.count - 1 {
            amount /= base
            unit += 1
        }
        let text: String
        if unit == 0 || amount >= 100 {
            text = "\(Int(amount.rounded()))"
        } else {
            let tenths = (amount * 10).rounded() / 10
            text = tenths == tenths.rounded() ? "\(Int(tenths))" : L10n.decimal(tenths)
        }
        return "\(text)\(nbsp)\(units[unit])"
    }

    public static func bytes(_ value: UInt64, binary: Bool) -> String {
        bytes(Int64(clamping: value), binary: binary)
    }

    /// "45 мин", "2 ч 15 мин", "3 ч".
    public static func minutes(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return L("%@\u{00A0}мин", m) }
        let h = m / 60, r = m % 60
        return r == 0 ? L("%@\u{00A0}ч", h) : L("%@\u{00A0}ч %@\u{00A0}мин", h, r)
    }

    /// "23 %" in Russian (its typography puts a space before the sign), "23%" in English.
    public static func percent(_ fraction: Double) -> String {
        L("%@\u{00A0}%%", percentValue(fraction))
    }

    public static func percentValue(_ fraction: Double) -> Int {
        fraction.isFinite ? Int((min(max(fraction, 0), 1) * 100).rounded()) : 0
    }

    /// "работает 3 д 4 ч", from the system's uptime.
    public static func uptime(_ seconds: TimeInterval) -> String {
        let s = seconds.isFinite ? Int(max(seconds, 0)) : 0
        let days = s / 86_400, hours = (s % 86_400) / 3600, minutes = (s % 3600) / 60
        if days > 0 { return hours > 0 ? L("%@\u{00A0}д %@\u{00A0}ч", days, hours) : L("%@\u{00A0}д", days) }
        if hours > 0 { return minutes > 0 ? L("%@\u{00A0}ч %@\u{00A0}мин", hours, minutes) : L("%@\u{00A0}ч", hours) }
        return L("%@\u{00A0}мин", max(minutes, 1))
    }

    /// How the battery line reads under the gauge: "осталось 3 ч 12 мин", "до полной 45 мин",
    /// "не заряжается", "заряжен".
    public static func batteryDetail(_ state: BatteryState) -> String {
        switch state.phase {
        case .discharging:
            return state.minutesToEmpty.map { L("осталось %@", minutes($0)) } ?? L("от батареи")
        case .charging:
            return state.minutesToFull.map { L("до полной %@", minutes($0)) } ?? L("заряжается")
        case .onHold:
            return L("не заряжается")
        case .full:
            return L("заряжен")
        }
    }
}
