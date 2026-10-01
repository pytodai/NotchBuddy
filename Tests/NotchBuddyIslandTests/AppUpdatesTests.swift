import AppKit
import NotchBuddyCore
import XCTest
@testable import NotchBuddy

/// Self-updates as the UI sees them, over a stand-in updater (no Sparkle, no network): settings switches write
/// through, «Проверить обновления…» is wired in the menu, background finds and downloads are marked, and a downloaded
/// update waits for a quiet moment.
@MainActor
final class AppUpdatesTests: XCTestCase {
    private final class FakeUpdater: UpdaterDriving {
        var canCheckForUpdates = true
        var automaticallyChecksForUpdates = true
        var automaticallyDownloadsUpdates = false
        var lastUpdateCheckDate: Date?
        var checks = 0
        func checkForUpdates() { checks += 1 }
    }

    private var fake: FakeUpdater!
    private var updates: AppUpdates!
    private var activations = 0

    override func setUp() async throws {
        L10n.shared.override(.ru)
        fake = FakeUpdater()
        updates = makeUpdates(allowsAutomaticUpdates: true)
        updates.connect(fake)
    }

    override func tearDown() async throws {
        L10n.shared.override(nil)
    }

    private func makeUpdates(allowsAutomaticUpdates: Bool) -> AppUpdates {
        let updates = AppUpdates(configuration: UpdateConfiguration(infoDictionary: [
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "3",
            "SUEnableAutomaticChecks": true, "SUAllowsAutomaticUpdates": allowsAutomaticUpdates,
        ]))
        updates.activateApp = { [weak self] in self?.activations += 1 }
        return updates
    }

    // MARK: Settings

    func testMirrorsTheUpdater() {
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        fake.lastUpdateCheckDate = checked
        fake.canCheckForUpdates = false
        updates.sync()
        XCTAssertTrue(updates.isRunning)
        XCTAssertFalse(updates.canCheck)
        XCTAssertTrue(updates.checksAutomatically)
        XCTAssertFalse(updates.installsAutomatically)
        XCTAssertEqual(updates.lastCheck, checked)
    }

    func testSwitchesWriteThrough() {
        updates.setChecksAutomatically(false)
        XCTAssertFalse(fake.automaticallyChecksForUpdates)
        XCTAssertFalse(updates.checksAutomatically)
        updates.setInstallsAutomatically(true)
        XCTAssertTrue(fake.automaticallyDownloadsUpdates)
        XCTAssertTrue(updates.installsAutomatically)

        // A bundle that does not allow automatic updates never turns them on.
        let strict = makeUpdates(allowsAutomaticUpdates: false)
        let other = FakeUpdater()
        strict.connect(other)
        strict.setInstallsAutomatically(true)
        XCTAssertFalse(other.automaticallyDownloadsUpdates)
    }

    func testCheckOnlyWhenTheUpdaterCan() {
        updates.checkForUpdates()
        XCTAssertEqual(fake.checks, 1)
        XCTAssertEqual(activations, 1, "the app comes forward before the update window opens")
        fake.canCheckForUpdates = false
        updates.sync()
        updates.checkForUpdates()
        XCTAssertEqual(fake.checks, 1)
    }

    func testWithoutAnUpdaterEverythingIsOff() {
        let idle = makeUpdates(allowsAutomaticUpdates: true)
        XCTAssertFalse(idle.isRunning)
        idle.checkForUpdates()
        idle.setChecksAutomatically(false)
        XCTAssertTrue(idle.checksAutomatically, "Info.plist's default stays")
        XCTAssertEqual(UpdatesSettingsSection.summary(idle), "Недоступны в этой сборке")
        let item = idle.menuItem()
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.toolTip, "Обновления недоступны в этой сборке")
    }

    func testSummaries() {
        XCTAssertEqual(UpdatesSettingsSection.summary(updates), "Раз в день")
        XCTAssertEqual(UpdatesSettingsSection.versionLine(updates), "Версия 1.0 (3)")
        XCTAssertEqual(UpdatesSettingsSection.lastCheckLine(updates), "Ещё не проверялось")
        fake.lastUpdateCheckDate = Date()
        updates.sync()
        XCTAssertTrue(UpdatesSettingsSection.summary(updates).hasPrefix("Раз в день · проверено сегодня"),
                      UpdatesSettingsSection.summary(updates))
        updates.setChecksAutomatically(false)
        XCTAssertEqual(UpdatesSettingsSection.summary(updates), "Только вручную")
        updates.found(version: "1.1")
        XCTAssertEqual(UpdatesSettingsSection.summary(updates), "Доступна версия 1.1")
        L10n.shared.override(.en)
        XCTAssertEqual(UpdatesSettingsSection.summary(updates), "Version 1.1 is available")
    }

    func testSectionSitsBeforePrivacy() {
        let all = SettingsSection.allCases
        XCTAssertEqual(all.firstIndex(of: .updates).map { $0 + 1 }, all.firstIndex(of: .privacy))
        XCTAssertEqual(SettingsSection.updates.title, "Обновления")
        XCTAssertTrue(SettingsSection.updates.expandable)
    }

    // MARK: Menu

    func testMenuItemChecksForUpdates() throws {
        let item = updates.menuItem()
        XCTAssertEqual(item.title, "Проверить обновления…")
        XCTAssertTrue(item.isEnabled)
        let target = try XCTUnwrap(item.target as? AppUpdates)
        XCTAssertTrue(target === updates)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: target, from: item))
        XCTAssertEqual(fake.checks, 1)

        fake.canCheckForUpdates = false
        updates.sync()
        XCTAssertFalse(updates.menuItem().isEnabled, "disabled while a check runs")
    }

    func testBackgroundFindIsMarkedUntilSeen() throws {
        var changes = 0
        updates.onAttentionChange = { changes += 1 }
        updates.found(version: "1.1")
        updates.found(version: "1.1")
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(updates.needsAttention)
        let item = updates.menuItem()
        XCTAssertEqual(item.title, "Обновить до 1.1…")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(fake.checks, 1, "brings Sparkle's window with the update")
        updates.attended()
        XCTAssertFalse(updates.needsAttention)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(updates.menuItem().title, "Проверить обновления…")
    }

    func testStatusIconBadge() throws {
        let plain = try XCTUnwrap(MenuBarController.statusImage(badge: false))
        let badged = try XCTUnwrap(MenuBarController.statusImage(badge: true))
        XCTAssertTrue(plain.isTemplate)
        XCTAssertTrue(badged.isTemplate, "the dot follows the menu bar's appearance")
        XCTAssertGreaterThan(badged.size.width, plain.size.width)
    }

    // MARK: Background downloads

    func testDownloadedUpdateWaitsForAQuietMoment() throws {
        var installs = 0
        var quiet = false
        var idle: TimeInterval = 10
        updates.isQuiet = { quiet }
        updates.idleSeconds = { idle }
        updates.downloaded(version: "1.1") { installs += 1 }
        XCTAssertTrue(updates.needsAttention)
        XCTAssertEqual(updates.downloadedVersion, "1.1")
        XCTAssertEqual(updates.menuItem().title, "Обновить до 1.1 и перезапустить")

        XCTAssertFalse(updates.installIfQuiet(), "an agent is working")
        quiet = true
        XCTAssertFalse(updates.installIfQuiet(), "the user is at the keyboard")
        idle = AppUpdates.quietIdleSeconds
        XCTAssertTrue(updates.installIfQuiet())
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(updates.installIfQuiet(), "only once")
        XCTAssertEqual(installs, 1)
        XCTAssertNil(updates.downloadedVersion, "Sparkle's handler is spent: nothing left to install from here")
        XCTAssertFalse(updates.needsAttention)
    }

    func testMenuInstallsADownloadedUpdateNow() throws {
        var installs = 0
        var changes = 0
        updates.onAttentionChange = { changes += 1 }
        updates.downloaded(version: "1.1") { installs += 1 }
        let item = updates.menuItem()
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(fake.checks, 0)
        XCTAssertEqual(changes, 2, "the dot goes away with the update")
        XCTAssertEqual(updates.menuItem().title, "Проверить обновления…", "an install that did not relaunch offers a check")
    }

    // MARK: Settings button

    func testSettingsButtonSaysWhatItDoes() {
        XCTAssertEqual(UpdatesSettingsSection.primaryTitle(updates), "Проверить обновления…", "it opens a window")
        updates.found(version: "1.1")
        XCTAssertEqual(UpdatesSettingsSection.primaryTitle(updates), "Обновить до 1.1…")
        var installs = 0
        updates.downloaded(version: "1.1") { installs += 1 }
        XCTAssertEqual(UpdatesSettingsSection.primaryTitle(updates), "Установить и перезапустить")
        L10n.shared.override(.en)
        XCTAssertEqual(UpdatesSettingsSection.primaryTitle(updates), "Install and Relaunch")
        updates.installDownloaded()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(UpdatesSettingsSection.primaryTitle(updates), "Check for Updates…",
                       "no install button once Sparkle's handler is used")
    }

    // MARK: Quiet moments

    /// The relaunch that installs an update forgets every session (they live in memory only), so it waits until none
    /// was active lately and no card is left to read.
    func testRelaunchWaitsUntilNothingWouldBeLost() {
        final class Now: @unchecked Sendable {
            var moment = Moment(wall: Date(timeIntervalSince1970: 1_800_000_000), monotonic: 5_000)
            func advance(_ seconds: TimeInterval) { moment = moment.advanced(by: seconds) }
        }
        let now = Now()
        let model = AppModel(jumper: StayPut(), usageProvider: IslandPerfUsage(), clock: AppClock { now.moment })
        model.showsAgentReply = { true }
        func send(_ kind: EventKind) {
            let event = AgentEvent(source: .claude, hookEventName: kind.rawValue, kind: kind, sessionId: "s",
                                   cwd: "/Users/u/proj", timestamp: now.moment.wall)
            model.handle(BridgeRequest(event: event, expectsReply: false), reply: nil)
        }
        XCTAssertTrue(model.canRelaunchQuietly(), "no sessions at all")

        send(.promptSubmitted)
        XCTAssertFalse(model.canRelaunchQuietly(), "an agent is working")
        now.advance(AppModel.quietSessionAge + 60)
        XCTAssertFalse(model.canRelaunchQuietly(), "still working, however long ago it said so")

        send(.stop)
        XCTAssertNotNil(model.flash, "the «Готово» card")
        XCTAssertFalse(model.canRelaunchQuietly(), "the card is not read yet")
        model.dismissFlash(all: true)
        XCTAssertFalse(model.canRelaunchQuietly(), "the session just finished: its answer is still worth a look")
        now.advance(AppModel.quietSessionAge - 1)
        XCTAssertFalse(model.canRelaunchQuietly())
        now.advance(1)
        XCTAssertTrue(model.canRelaunchQuietly(), "every session long silent")
    }
}

private struct StayPut: TerminalJumping {
    func jump(to session: AgentSession) -> Bool { false }
}
