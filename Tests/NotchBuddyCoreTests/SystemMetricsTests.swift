import IOKit.ps
import XCTest
@testable import NotchBuddyCore

final class SystemMetricsTests: XCTestCase {
    // MARK: Battery

    private func source(_ current: Int = 80, max: Int = 100, ac: Bool = false, charging: Bool = false,
                        charged: Bool = false, toEmpty: Int = -1, toFull: Int = -1,
                        type: String = kIOPSInternalBatteryType) -> [String: Any] {
        [kIOPSTypeKey: type, kIOPSIsPresentKey: true, kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: max,
         kIOPSPowerSourceStateKey: ac ? kIOPSACPowerValue : kIOPSBatteryPowerValue, kIOPSIsChargingKey: charging,
         kIOPSIsChargedKey: charged, kIOPSTimeToEmptyKey: toEmpty, kIOPSTimeToFullChargeKey: toFull]
    }

    func testParsesTheInternalBattery() throws {
        let s = try XCTUnwrap(BatteryState.parse(source(62, toEmpty: 192)))
        XCTAssertEqual(s.percent, 62)
        XCTAssertEqual(s.phase, .discharging)
        XCTAssertEqual(s.minutesLeft, 192)
        XCTAssertEqual(SystemFormat.batteryDetail(s), "осталось 3\u{00A0}ч 12\u{00A0}мин")
    }

    func testCapacityIsAPercentOfMaxEvenWhenMaxIsNot100() throws {
        XCTAssertEqual(BatteryState.parse(source(4000, max: 5000))?.percent, 80)
    }

    func testEstimatingTimeReadsAsUnknown() throws {
        let s = try XCTUnwrap(BatteryState.parse(source(50, toEmpty: -1)))
        XCTAssertNil(s.minutesLeft)
        XCTAssertEqual(SystemFormat.batteryDetail(s), "от батареи")
    }

    func testPhasesOnPower() throws {
        let charging = try XCTUnwrap(BatteryState.parse(source(40, ac: true, charging: true, toFull: 45)))
        XCTAssertEqual(charging.phase, .charging)
        XCTAssertEqual(SystemFormat.batteryDetail(charging), "до полной 45\u{00A0}мин")
        // The charge limit (or Optimized Charging) holds it at 80 %: plugged in, not charging.
        let held = try XCTUnwrap(BatteryState.parse(source(80, ac: true)))
        XCTAssertEqual(held.phase, .onHold)
        XCTAssertEqual(SystemFormat.batteryDetail(held), "не заряжается")
        let full = try XCTUnwrap(BatteryState.parse(source(100, ac: true, charged: true)))
        XCTAssertEqual(full.phase, .full)
        XCTAssertNil(full.minutesLeft)
    }

    func testIgnoresOtherPowerSources() {
        XCTAssertNil(BatteryState.parse(source(type: "UPS")))
        XCTAssertNil(BatteryState.parse(source(0, max: 0)))
        var absent = source()
        absent[kIOPSIsPresentKey] = false
        XCTAssertNil(BatteryState.parse(absent))
    }

    func testReadingThisMacDoesNotCrash() {
        // A desktop Mac has no battery; a laptop has one with a sane percent.
        if let state = BatteryState.read() {
            XCTAssertTrue((0...100).contains(state.percent))
        }
    }

    // MARK: Battery alerts

    private func battery(_ percent: Int, ac: Bool = false, charging: Bool = false, charged: Bool = false) -> BatteryState {
        BatteryState(percent: percent, onAC: ac, charging: charging, charged: charged)
    }

    func testLowAndCriticalFireOnceWhenCrossingDownward() {
        let policy = BatteryAlertPolicy(threshold: 20, critical: 10)
        XCTAssertEqual(policy.events(from: battery(21), to: battery(20)), [.low(percent: 20)])
        XCTAssertEqual(policy.events(from: battery(20), to: battery(19)), [])
        XCTAssertEqual(policy.events(from: battery(11), to: battery(10)), [.critical(percent: 10)])
        XCTAssertEqual(policy.events(from: battery(10), to: battery(9)), [])
        // A big drop straight past both says the worse one.
        XCTAssertEqual(policy.events(from: battery(30), to: battery(8)), [.critical(percent: 8)])
    }

    func testFirstReadingSaysNothingButShowsTheLiveActivity() {
        let policy = BatteryAlertPolicy(threshold: 20)
        XCTAssertEqual(policy.events(from: nil, to: battery(5)), [])
        XCTAssertTrue(policy.isLow(battery(5)))
        XCTAssertTrue(policy.isCritical(battery(5)))
        XCTAssertFalse(policy.isLow(battery(5, ac: true, charging: true)), "plugged in: not low")
        XCTAssertFalse(policy.isLow(nil))
    }

    func testPlugAndUnplug() {
        let policy = BatteryAlertPolicy()
        XCTAssertEqual(policy.events(from: battery(15), to: battery(15, ac: true, charging: true)),
                       [.pluggedIn(percent: 15, charging: true)])
        XCTAssertEqual(policy.events(from: battery(80, ac: true), to: battery(80)), [.unplugged(percent: 80)])
        // Unplugged below the threshold: both.
        XCTAssertEqual(policy.events(from: battery(15, ac: true, charging: true), to: battery(15)),
                       [.unplugged(percent: 15), .low(percent: 15)])
        XCTAssertEqual(policy.events(from: battery(99, ac: true, charging: true), to: battery(100, ac: true, charged: true)),
                       [.full])
    }

    func testPolicyClampsItsLevels() {
        let policy = BatteryAlertPolicy(threshold: 5, critical: 30)
        XCTAssertEqual(policy.threshold, 5)
        XCTAssertEqual(policy.critical, 5)
    }

    // MARK: CPU

    func testCPUUsageFromTickDeltas() throws {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        XCTAssertEqual(try XCTUnwrap(CPULoad.usage(from: a, to: b)), 100.0 / 200.0, accuracy: 1e-9)
        XCTAssertNil(CPULoad.usage(from: a, to: a))
    }

    func testCPUTicksWrapAround() throws {
        let a = CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 29, nice: 0)
        let b = CPUTicks(user: 10, system: 0, idle: 10, nice: 0)
        // 20 busy, 40 idle across the wrap.
        XCTAssertEqual(try XCTUnwrap(CPULoad.usage(from: a, to: b)), 20.0 / 60.0, accuracy: 1e-9)
    }

    func testSmoothing() {
        XCTAssertEqual(CPULoad.smoothed(nil, 0.8), 0.8)
        XCTAssertEqual(CPULoad.smoothed(0.2, 0.8, alpha: 0.5), 0.5, accuracy: 1e-9)
    }

    func testReadingTicksAndMemoryOnThisMac() throws {
        let ticks = try XCTUnwrap(CPUTicks.read())
        XCTAssertGreaterThan(UInt64(ticks.idle) + UInt64(ticks.user), 0)
        let memory = try XCTUnwrap(MemoryUsage.read())
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        let disk = try XCTUnwrap(DiskUsage.read())
        XCTAssertGreaterThan(disk.total, 0)
    }

    // MARK: Memory and disk

    func testMemoryCountsLikeActivityMonitor() {
        let m = MemoryUsage.compute(pageSize: 16384, internalPages: 600_000, purgeablePages: 100_000, wiredPages: 150_000,
                                    compressedPages: 50_000, total: 24 << 30)
        XCTAssertEqual(m.used, UInt64(700_000) * 16384)
        XCTAssertEqual(m.fraction, Double(700_000 * 16384) / Double(24 << 30), accuracy: 1e-9)
        let odd = MemoryUsage.compute(pageSize: 16384, internalPages: 10, purgeablePages: 20, wiredPages: 0,
                                      compressedPages: 0, total: 1 << 30)
        XCTAssertEqual(odd.used, 0, "purgeable above internal never underflows")
        let huge = MemoryUsage.compute(pageSize: .max, internalPages: 10, purgeablePages: 0, wiredPages: 0,
                                       compressedPages: 0, total: 1 << 30)
        XCTAssertEqual(huge.used, 1 << 30, "overflow clamps to the total")
    }

    func testDiskClampsAndComputesUsedShare() {
        let d = DiskUsage(free: 250_000_000_000, total: 1_000_000_000_000)
        XCTAssertEqual(d.fraction, 0.75, accuracy: 1e-9)
        XCTAssertEqual(DiskUsage(free: 5, total: 2).free, 2)
    }

    // MARK: Format

    func testBytesReadInRussian() {
        XCTAssertEqual(SystemFormat.bytes(Int64(14.2 * 1_073_741_824), binary: true), "14,2\u{00A0}ГБ")
        XCTAssertEqual(SystemFormat.bytes(Int64(24) << 30, binary: true), "24\u{00A0}ГБ")
        XCTAssertEqual(SystemFormat.bytes(Int64(312_400_000_000), binary: false), "312\u{00A0}ГБ")
        XCTAssertEqual(SystemFormat.bytes(Int64(1_240_000_000_000), binary: false), "1,2\u{00A0}ТБ")
        XCTAssertEqual(SystemFormat.bytes(Int64(512), binary: true), "512\u{00A0}Б")
        XCTAssertEqual(SystemFormat.bytes(Int64(-5), binary: true), "0\u{00A0}Б")
    }

    func testDurationsAndPercents() {
        XCTAssertEqual(SystemFormat.minutes(45), "45\u{00A0}мин")
        XCTAssertEqual(SystemFormat.minutes(120), "2\u{00A0}ч")
        XCTAssertEqual(SystemFormat.minutes(135), "2\u{00A0}ч 15\u{00A0}мин")
        XCTAssertEqual(SystemFormat.percent(0.234), "23\u{00A0}%")
        XCTAssertEqual(SystemFormat.percent(.nan), "0\u{00A0}%")
        XCTAssertEqual(SystemFormat.uptime(3 * 86_400 + 4 * 3600 + 5), "3\u{00A0}д 4\u{00A0}ч")
        XCTAssertEqual(SystemFormat.uptime(20), "1\u{00A0}мин")
    }
}
