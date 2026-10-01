import XCTest
@testable import NotchBuddyCore

final class SettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "nb-settings-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Defaults and round trip

    func testEmptyDefaultsGiveTheBuiltInValues() {
        let settings = NotchSettings.load(from: defaults)
        XCTAssertEqual(settings, NotchSettings())
        XCTAssertTrue(settings.soundsEnabled)
        XCTAssertEqual(settings.sound(for: .finished), "Glass")
        XCTAssertEqual(settings.sound(for: .attention), "Ping")
        XCTAssertEqual(settings.sound(for: .permission), "Ping")
        XCTAssertEqual(settings.sound(for: .error), "")
        XCTAssertEqual(settings.hoverOpen.restDwell, 0.09)
        XCTAssertEqual(settings.hoverOpen.maxDwell, 0.22)
        XCTAssertEqual(settings.flashDuration.seconds, 5)
        XCTAssertTrue(settings.claudeUsageViaAPI)
        XCTAssertTrue(settings.hotkeyEnabled, "⌃⌥N opens the island out of the box")
        XCTAssertEqual(settings.hotkey.display, "⌃⌥N")
        XCTAssertEqual(settings.islandStyle(hasNotch: false), .notch)
        XCTAssertEqual(settings.islandStyle(hasNotch: true), .notch)
        XCTAssertEqual(settings.enabledWidgets, [.agents], "only «Агенты»: no tab strip out of the box")
        XCTAssertTrue(settings.showsUsageRing)
        XCTAssertEqual(settings.usageProvider, .auto)
        XCTAssertEqual(settings.capsuleWidth, 190, "a compact capsule out of the box")
        XCTAssertFalse(settings.usesIslandStyle)
    }

    func testEverySettingRoundTrips() {
        var settings = NotchSettings()
        settings.soundsEnabled = false
        settings.soundVolume = 0.35
        settings.sounds[.finished] = "Hero"
        settings.sounds[.error] = "Basso"
        settings.claudeUsageViaAPI = false
        settings.kimiUsageViaAPI = true
        settings.usageRefresh = .fifteenMinutes
        settings.hoverOpen = .never
        settings.openOnPermission = false
        settings.showWithoutSessions = true
        settings.flashDuration = .veryLong
        settings.pinOnOpen = true
        settings.size = .large
        settings.screen = .display(id: "37D8832A-2D66-02CA-B9F7-8F30A301B230", name: "DELL U2720Q")
        settings.setIslandStyle(.island, hasNotch: false)
        settings.setIslandStyle(.island, hasNotch: true)
        settings.capsuleWidth = 244
        settings.hotkeyEnabled = true
        settings.hotkey = HotkeyCombo(keyCode: 49, modifiers: [.command, .shift])
        settings.widgets = [WidgetEntry(.timer, enabled: true), WidgetEntry(.agents, enabled: true),
                            WidgetEntry(.shelf, enabled: false), WidgetEntry(.calendar, enabled: true),
                            WidgetEntry(.music, enabled: false), WidgetEntry(.system, enabled: true)]
        settings.usageProvider = .codex
        settings.showsUsageRing = false
        settings.accent = .mint
        settings.motion = .reduced
        settings.didOfferHooks = true
        settings.save(to: defaults)
        XCTAssertEqual(NotchSettings.load(from: defaults), settings)
    }

    func testSaveWritesOnlyWhatChanged() {
        let old = NotchSettings()
        var new = old
        new.accent = .graphite
        new.sounds[.attention] = ""
        let written = new.save(to: defaults, changedFrom: old)
        XCTAssertEqual(Set(written), [SettingsKey.accent, SettingsKey.sound(.attention)])
        XCTAssertNil(defaults.object(forKey: SettingsKey.soundsEnabled))
        XCTAssertEqual(defaults.string(forKey: SettingsKey.sound(.attention)), "")
        XCTAssertEqual(NotchSettings.load(from: defaults).audibleSound(for: .attention), nil)
    }

    func testLegacyKeysAreSharedWithTheRestOfTheApp() {
        // The menu bar menu, the island's sound button and UsageFetcher read these very keys.
        defaults.set(false, forKey: "soundsEnabled")
        defaults.set(false, forKey: "usageNetworkEnabled")
        defaults.set(true, forKey: "didOfferHooks")
        let settings = NotchSettings.load(from: defaults)
        XCTAssertFalse(settings.soundsEnabled)
        XCTAssertFalse(settings.claudeUsageViaAPI)
        XCTAssertTrue(settings.didOfferHooks)
    }

    func testUnreadableValuesFallBackToDefaults() {
        defaults.set("loud", forKey: SettingsKey.soundVolume)
        defaults.set(7, forKey: SettingsKey.flashDuration)
        defaults.set("xl", forKey: SettingsKey.size)
        defaults.set("display:", forKey: SettingsKey.screen)
        defaults.set("99:9999", forKey: SettingsKey.hotkey)
        defaults.set(["nope:1", "calendar:1", "calendar:0", "agents:0", "weather:1"], forKey: SettingsKey.widgets)
        defaults.set(3.5, forKey: SettingsKey.soundVolume)
        let settings = NotchSettings.load(from: defaults)
        XCTAssertEqual(settings.soundVolume, 1, "clamped to 0…1")
        XCTAssertEqual(settings.flashDuration, .normal)
        XCTAssertEqual(settings.size, .medium)
        XCTAssertEqual(settings.screen, .activeWindow)
        XCTAssertEqual(settings.hotkey, .defaultToggle)
        // Unknown and retired ones dropped, the repeated one keeps its first state, the missing ones appended, and
        // «Агенты» is always on.
        XCTAssertEqual(settings.widgets.map(\.kind), [.calendar, .agents, .music, .timer, .system, .shelf])
        XCTAssertTrue(settings.widgets[0].enabled)
        XCTAssertTrue(settings.widgets[1].enabled)
        XCTAssertEqual(settings.enabledWidgets, [.calendar, .agents])
    }

    /// «Ширина капсулы»: whole points within 140…360; anything else written by hand is clamped or dropped.
    func testCapsuleWidthIsClampedToItsRange() {
        defaults.set(1000, forKey: SettingsKey.capsuleWidth)
        XCTAssertEqual(NotchSettings.load(from: defaults).capsuleWidth, 360)
        defaults.set("80", forKey: SettingsKey.capsuleWidth)
        XCTAssertEqual(NotchSettings.load(from: defaults).capsuleWidth, 140)
        defaults.set("212,6", forKey: SettingsKey.capsuleWidth)
        XCTAssertEqual(NotchSettings.load(from: defaults).capsuleWidth, 213)
        defaults.set("wide", forKey: SettingsKey.capsuleWidth)
        XCTAssertEqual(NotchSettings.load(from: defaults).capsuleWidth, NotchSettings.defaultCapsuleWidth)
        XCTAssertEqual(NotchSettings.clampedCapsuleWidth(.nan), NotchSettings.defaultCapsuleWidth)
        var settings = NotchSettings()
        settings.setIslandStyle(.island, hasNotch: true)
        XCTAssertTrue(settings.usesIslandStyle, "a notched screen in «Островок» is enough")
    }

    /// «Стиль» per kind of screen: monitors and a screen with a camera notch; a value it cannot read is dropped.
    func testIslandStylePerKindOfScreen() {
        var settings = NotchSettings()
        settings.setIslandStyle(.island, hasNotch: false)
        settings.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.islandStyleMonitors), "island")
        let loaded = NotchSettings.load(from: defaults)
        XCTAssertEqual(loaded.islandStyle(hasNotch: false), .island)
        XCTAssertEqual(loaded.islandStyle(hasNotch: true), .notch, "the notched screen keeps its own")
        defaults.set("bubble", forKey: SettingsKey.islandStyleNotched)
        XCTAssertEqual(NotchSettings.load(from: defaults).islandStyle(hasNotch: true), .notch)
    }

    /// v3: a display set to «Островок» in the old per-UUID map makes it the monitors' style — a monitor whose UUID
    /// changed keeps it; ⌃⌥Space (it switches keyboard layouts) gives way to ⌃⌥N.
    func testMigrationV3() {
        defaults.set(2, forKey: SettingsKey.schemaVersion)
        defaults.set(["37D8832A": "island"], forKey: SettingsKey.legacyIslandStyles)
        defaults.set(HotkeyCombo.formerDefault.rawValue, forKey: SettingsKey.hotkey)
        let steps = SettingsMigration.migrate(defaults)
        XCTAssertEqual(steps.count, 2, "\(steps)")
        let settings = NotchSettings.load(from: defaults)
        XCTAssertEqual(settings.islandStyle(hasNotch: false), .island)
        XCTAssertEqual(settings.islandStyle(hasNotch: true), .notch)
        XCTAssertEqual(settings.hotkey, .defaultToggle)
        XCTAssertNil(defaults.object(forKey: SettingsKey.legacyIslandStyles))
        XCTAssertEqual(SettingsMigration.migrate(defaults), [], "idempotent")

        // A combo of one's own and «Чёлка» everywhere stay as they were.
        defaults.set(2, forKey: SettingsKey.schemaVersion)
        defaults.set(["A": "notch"], forKey: SettingsKey.legacyIslandStyles)
        defaults.removeObject(forKey: SettingsKey.islandStyleMonitors)
        let own = HotkeyCombo(keyCode: 34, modifiers: [.control, .option])
        defaults.set(own.rawValue, forKey: SettingsKey.hotkey)
        SettingsMigration.migrate(defaults)
        XCTAssertEqual(NotchSettings.load(from: defaults).hotkey, own)
        XCTAssertEqual(NotchSettings.load(from: defaults).islandStyle(hasNotch: false), .notch)
    }

    /// The Mac's own shortcuts: an enabled one with the same key and modifiers is a clash (fn on function keys is
    /// ignored), a disabled one is not; every preset is free of the defaults.
    func testHotkeyClashesWithTheSystem() {
        let system: [HotkeyClashes.SystemHotkey] = [
            .init(keyCode: 49, carbonModifiers: 0x1800, enabled: true),     // ⌃⌥Space: next input source
            .init(keyCode: 49, carbonModifiers: 0x1000, enabled: true),     // ⌃Space
            .init(keyCode: 103, carbonModifiers: 0x20000, enabled: true),   // F11 (fn): Show Desktop
            .init(keyCode: 45, carbonModifiers: 0x1800, enabled: false),    // ⌃⌥N, switched off
        ]
        L10n.shared.override(.ru)
        defer { L10n.shared.override(nil) }
        XCTAssertEqual(HotkeyClashes.system(.formerDefault, in: system), "Следующий источник ввода")
        XCTAssertEqual(HotkeyClashes.system(HotkeyCombo(keyCode: 103, modifiers: []), in: system), "Показать рабочий стол")
        XCTAssertNil(HotkeyClashes.system(.defaultToggle, in: system), "a disabled shortcut is free")
        XCTAssertNil(HotkeyClashes.system(HotkeyCombo(keyCode: 49, modifiers: [.control, .option, .command]), in: system))
        for preset in HotkeyCombo.presets {
            XCTAssertNil(HotkeyClashes.system(preset, in: system.filter(\.enabled)), preset.display)
            XCTAssertNil(HotkeyClashes.app(preset), preset.display)
        }
        XCTAssertNotNil(HotkeyClashes.app(HotkeyCombo(keyCode: 34, modifiers: [.option, .command])), "⌥⌘I: DevTools")
    }

    func testHandWrittenStringsCount() {
        defaults.set("NO", forKey: SettingsKey.soundsEnabled)
        defaults.set("0,4", forKey: SettingsKey.soundVolume)
        defaults.set("300", forKey: SettingsKey.usageRefresh)
        let settings = NotchSettings.load(from: defaults)
        XCTAssertFalse(settings.soundsEnabled)
        XCTAssertEqual(settings.soundVolume, 0.4, accuracy: 0.0001)
        XCTAssertEqual(settings.usageRefresh, .fiveMinutes)
    }

    func testResetKeepsBookkeeping() {
        var settings = NotchSettings()
        settings.didOfferHooks = true
        settings.accent = .coral
        settings.soundsEnabled = false
        let reset = settings.reset()
        XCTAssertTrue(reset.didOfferHooks)
        XCTAssertEqual(reset.accent, .azure)
        XCTAssertTrue(reset.soundsEnabled)
    }

    func testAudibleSoundHonoursTheMasterSwitchAndVolume() {
        var settings = NotchSettings()
        XCTAssertEqual(settings.audibleSound(for: .finished), "Glass")
        XCTAssertNil(settings.audibleSound(for: .error))
        settings.soundVolume = 0
        XCTAssertNil(settings.audibleSound(for: .finished))
        settings.soundVolume = 0.5
        settings.soundsEnabled = false
        XCTAssertNil(settings.audibleSound(for: .finished))
    }

    // MARK: Migration

    func testMigrationTurnsTheLegacyOptOutIntoTheToggle() {
        defaults.set(true, forKey: SettingsKey.legacyUsageNetworkDisabled)
        let steps = SettingsMigration.migrate(defaults)
        XCTAssertFalse(steps.isEmpty)
        XCTAssertEqual(defaults.object(forKey: SettingsKey.claudeUsageViaAPI) as? Bool, false)
        XCTAssertEqual(defaults.integer(forKey: SettingsKey.schemaVersion), SettingsMigration.currentVersion)
        XCTAssertFalse(NotchSettings.load(from: defaults).claudeUsageViaAPI)
        XCTAssertEqual(SettingsMigration.migrate(defaults), [], "idempotent")
    }

    func testMigrationKeepsAnExplicitToggle() {
        defaults.set(true, forKey: SettingsKey.legacyUsageNetworkDisabled)
        defaults.set(true, forKey: SettingsKey.claudeUsageViaAPI)
        SettingsMigration.migrate(defaults)
        XCTAssertEqual(defaults.object(forKey: SettingsKey.claudeUsageViaAPI) as? Bool, true)
    }

    func testMigrationTurnsStringBooleansIntoBooleans() {
        defaults.set("no", forKey: SettingsKey.soundsEnabled)
        defaults.set("maybe", forKey: SettingsKey.didOfferHooks)
        SettingsMigration.migrate(defaults)
        XCTAssertEqual(defaults.object(forKey: SettingsKey.soundsEnabled) as? Bool, false)
        XCTAssertNil(defaults.object(forKey: SettingsKey.didOfferHooks))
    }

    /// v2: the usage ring leaves the widgets, "nowPlaying" becomes «Музыка», the weather placeholder goes.
    func testMigrationMovesTheUsageRingOutOfTheWidgets() {
        defaults.set(1, forKey: SettingsKey.schemaVersion)
        defaults.set(["usage:0", "nowPlaying:1", "calendar:0", "timer:0", "weather:0"], forKey: SettingsKey.widgets)
        let steps = SettingsMigration.migrate(defaults)
        XCTAssertFalse(steps.isEmpty)
        let settings = NotchSettings.load(from: defaults)
        XCTAssertFalse(settings.showsUsageRing)
        XCTAssertEqual(settings.enabledWidgets, [.music, .agents])
        XCTAssertEqual(defaults.stringArray(forKey: SettingsKey.widgets)?.contains { $0.hasPrefix("usage") }, false)
        XCTAssertEqual(SettingsMigration.migrate(defaults), [], "idempotent")
    }

    /// v2: an untouched "off" hotkey of earlier versions (⌃⌥N) is turned on (v3: ⌃⌥N is the default again); a combo of
    /// one's own stays.
    func testMigrationTurnsTheHotkeyOnUnlessItWasTheUsersOwn() {
        defaults.set(1, forKey: SettingsKey.schemaVersion)
        defaults.set(false, forKey: SettingsKey.hotkeyEnabled)
        SettingsMigration.migrate(defaults)
        var settings = NotchSettings.load(from: defaults)
        XCTAssertTrue(settings.hotkeyEnabled)
        XCTAssertEqual(settings.hotkey, .defaultToggle)

        let own = HotkeyCombo(keyCode: 34, modifiers: [.option, .command])
        defaults.set(1, forKey: SettingsKey.schemaVersion)
        defaults.set(false, forKey: SettingsKey.hotkeyEnabled)
        defaults.set(own.rawValue, forKey: SettingsKey.hotkey)
        SettingsMigration.migrate(defaults)
        settings = NotchSettings.load(from: defaults)
        XCTAssertFalse(settings.hotkeyEnabled, "switched off with a combo of their own: left alone")
        XCTAssertEqual(settings.hotkey, own)
    }

    func testMigrationOnAFreshInstallOnlyStampsTheVersion() {
        XCTAssertEqual(SettingsMigration.migrate(defaults), [])
        XCTAssertEqual(defaults.integer(forKey: SettingsKey.schemaVersion), SettingsMigration.currentVersion)
        XCTAssertNil(defaults.object(forKey: SettingsKey.claudeUsageViaAPI))
    }

    // MARK: Values

    func testScreenChoiceRawValues() {
        for choice: ScreenChoice in [.activeWindow, .main, .display(id: "ABC", name: "Studio Display"),
                                     .display(id: "X", name: "")] {
            XCTAssertEqual(ScreenChoice(rawValue: choice.rawValue), choice)
        }
        XCTAssertEqual(ScreenChoice(rawValue: "display:ID\tName\twith tab"), .display(id: "ID", name: "Name\twith tab"))
        XCTAssertNil(ScreenChoice(rawValue: "display:"))
        XCTAssertNil(ScreenChoice(rawValue: "left"))
    }

    func testHoverDelaysGrow() {
        let rests = HoverOpenDelay.allCases.compactMap(\.restDwell)
        XCTAssertEqual(rests, rests.sorted())
        XCTAssertNil(HoverOpenDelay.never.restDwell)
        XCTAssertNil(HoverOpenDelay.never.maxDwell)
        for delay in HoverOpenDelay.allCases where delay != .never {
            XCTAssertGreaterThan(delay.maxDwell!, delay.restDwell!)
        }
    }

    func testMotionPreference() {
        XCTAssertTrue(MotionPreference.system.reduceMotion(system: true))
        XCTAssertFalse(MotionPreference.system.reduceMotion(system: false))
        XCTAssertFalse(MotionPreference.full.reduceMotion(system: true))
        XCTAssertTrue(MotionPreference.reduced.reduceMotion(system: false))
    }

    func testMoveWidget() {
        var settings = NotchSettings()
        settings.moveWidget(from: 0, to: 3)
        XCTAssertEqual(settings.widgets.map(\.kind), [.music, .calendar, .timer, .agents, .system, .shelf])
        settings.moveWidget(from: 5, to: 0)
        XCTAssertEqual(settings.widgets.map(\.kind), [.shelf, .music, .calendar, .timer, .agents, .system])
        settings.moveWidget(from: 1, to: 99)
        XCTAssertEqual(settings.widgets.last?.kind, .music)
        settings.moveWidget(from: 42, to: 0)
        XCTAssertEqual(settings.widgets.count, WidgetKind.allCases.count)
    }

    // MARK: Hotkeys

    func testHotkeyDisplayAndRawValue() {
        let combo = HotkeyCombo.legacyDefault
        XCTAssertEqual(combo.display, "⌃⌥N")
        XCTAssertEqual(combo.keycaps, ["⌃", "⌥", "N"])
        XCTAssertEqual(HotkeyCombo.formerDefault.keycaps, ["⌃", "⌥", "Space"])
        XCTAssertEqual(HotkeyCombo(rawValue: combo.rawValue), combo)
        let all = HotkeyCombo(keyCode: 49, modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(all.display, "⌃⌥⇧⌘Space")
        XCTAssertEqual(HotkeyCombo(rawValue: all.rawValue), all)
        XCTAssertNil(HotkeyCombo(rawValue: "3"))
        XCTAssertNil(HotkeyCombo(rawValue: "3:500"), "unknown key code")
    }

    func testHotkeyUsability() {
        XCTAssertTrue(HotkeyCombo.defaultToggle.isUsable)
        XCTAssertFalse(HotkeyCombo(keyCode: 45, modifiers: []).isUsable, "a bare letter would eat typing")
        XCTAssertFalse(HotkeyCombo(keyCode: 45, modifiers: [.shift]).isUsable, "⇧ alone is typing too")
        XCTAssertTrue(HotkeyCombo(keyCode: 96, modifiers: []).isUsable, "F5 alone is fine")
        XCTAssertFalse(HotkeyCombo(keyCode: 55, modifiers: [.command]).isUsable, "⌘ is not a key")
        for preset in HotkeyCombo.presets { XCTAssertTrue(preset.isUsable, preset.display) }
        XCTAssertEqual(Set(HotkeyCombo.presets).count, HotkeyCombo.presets.count)
    }

    // MARK: Backups

    func testBackupsSummaryAndClearTouchOnlySnapshots() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nb-backups-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        XCTAssertEqual(BackupsMaintenance.summary(at: dir), .empty)
        for (stamp, files) in [("2026-09-29T14-03-11", 2), ("2026-09-30T08-00-00", 1)] {
            let snap = dir.appendingPathComponent(stamp, isDirectory: true)
            try fm.createDirectory(at: snap, withIntermediateDirectories: true)
            for i in 0..<files {
                try Data(repeating: 7, count: 100).write(to: snap.appendingPathComponent("file\(i)"))
            }
        }
        let keep = dir.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: keep)
        let other = dir.appendingPathComponent("manual", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)

        let summary = BackupsMaintenance.summary(at: dir)
        XCTAssertEqual(summary.snapshots, 2)
        XCTAssertEqual(summary.files, 3)
        XCTAssertEqual(summary.bytes, 300)
        XCTAssertNotNil(summary.newest)
        XCTAssertEqual(BackupsMaintenance.describe(summary), "2 копии · 300 Б")

        XCTAssertEqual(try BackupsMaintenance.clear(at: dir), 2)
        XCTAssertEqual(BackupsMaintenance.summary(at: dir).snapshots, 0)
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
    }

    func testSnapshotNames() {
        XCTAssertTrue(BackupsMaintenance.isSnapshotName("2026-09-29T14-03-11"))
        XCTAssertFalse(BackupsMaintenance.isSnapshotName("2026-09-29"))
        XCTAssertFalse(BackupsMaintenance.isSnapshotName("../2026-09-29T14-03-11"))
        XCTAssertFalse(BackupsMaintenance.isSnapshotName("2026-09-29T14-03-11x"))
    }

    func testRussianPluralsAndSizes() {
        XCTAssertEqual(RussianPlural.pick(1, "копия", "копии", "копий"), "копия")
        XCTAssertEqual(RussianPlural.pick(3, "копия", "копии", "копий"), "копии")
        XCTAssertEqual(RussianPlural.pick(11, "копия", "копии", "копий"), "копий")
        XCTAssertEqual(RussianPlural.pick(21, "копия", "копии", "копий"), "копия")
        XCTAssertEqual(RussianPlural.pick(112, "копия", "копии", "копий"), "копий")
        XCTAssertEqual(BackupsMaintenance.formatBytes(2048), "2 КБ")
        XCTAssertEqual(BackupsMaintenance.formatBytes(3 * 1024 * 1024 + 200_000), "3,2 МБ")
        XCTAssertEqual(BackupsMaintenance.describe(.empty), "Копий нет")
    }
}
