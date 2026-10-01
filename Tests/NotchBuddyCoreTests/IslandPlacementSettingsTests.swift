import XCTest
@testable import NotchBuddyCore

/// Settings → Остров: «Где показывать» (the island per app) and the dragged «Островок»'s place per display — the pure
/// decision and how both are kept.
final class IslandPlacementSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "nb-placement-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let keynote = ChosenApp(bundleID: "com.apple.iWork.Keynote", name: "Keynote")
    private let quickTime = ChosenApp(bundleID: "com.apple.QuickTimePlayerX", name: "QuickTime Player")
    private let terminal = "com.apple.Terminal"

    private func visible(_ filter: IslandAppFilter, _ chosen: [ChosenApp], front: String?, attention: Bool = false,
                         always: Bool = true) -> Bool {
        IslandAppVisibility.isVisible(filter: filter, chosen: chosen, frontmost: front, needsAttention: attention,
                                      requestsAlwaysShow: always)
    }

    // MARK: The decision

    /// «Во всех приложениях» shows everywhere, whatever the lists hold.
    func testAllAppsShowsEverywhere() {
        for front in [terminal, keynote.bundleID, nil] {
            XCTAssertTrue(visible(.all, [keynote], front: front))
        }
    }

    /// «Только в выбранных»: only while a chosen app is in front.
    func testOnlyChosenApps() {
        XCTAssertTrue(visible(.only, [keynote, quickTime], front: keynote.bundleID))
        XCTAssertTrue(visible(.only, [keynote, quickTime], front: quickTime.bundleID))
        XCTAssertFalse(visible(.only, [keynote, quickTime], front: terminal))
    }

    /// «Везде, кроме выбранных»: hidden while a chosen app is in front.
    func testEverywhereExceptChosenApps() {
        XCTAssertFalse(visible(.except, [keynote], front: keynote.bundleID))
        XCTAssertTrue(visible(.except, [keynote], front: terminal))
    }

    /// Bundle identifiers compare without case (Launch Services does).
    func testBundleIDsCompareWithoutCase() {
        XCTAssertFalse(visible(.except, [keynote], front: "COM.APPLE.IWORK.KEYNOTE"))
        XCTAssertTrue(visible(.only, [keynote], front: "com.apple.iwork.keynote"))
    }

    /// An empty list restricts nothing (the settings say so under it), and an unknown app in front shows the island.
    func testEmptyListAndUnknownAppShow() {
        XCTAssertTrue(visible(.only, [], front: terminal), "nothing chosen yet: shown everywhere")
        XCTAssertTrue(visible(.except, [], front: terminal))
        XCTAssertTrue(visible(.only, [keynote], front: nil), "the app in front is unknown")
        XCTAssertTrue(visible(.only, [keynote], front: ""))
    }

    /// «Всегда показывать запросы агентов»: a request or a "needs you" notice shows even where the island hides; off,
    /// it does not.
    func testAgentRequestsShowWhereTheIslandHides() {
        XCTAssertTrue(visible(.except, [keynote], front: keynote.bundleID, attention: true, always: true))
        XCTAssertTrue(visible(.only, [keynote], front: terminal, attention: true, always: true))
        XCTAssertFalse(visible(.except, [keynote], front: keynote.bundleID, attention: true, always: false))
        XCTAssertFalse(visible(.only, [keynote], front: terminal, attention: true, always: false))
        XCTAssertFalse(visible(.except, [keynote], front: keynote.bundleID, attention: false, always: true),
                       "no request: it stays hidden")
    }

    /// The settings' own shortcut reads the list of the mode in force.
    func testSettingsDecideWithTheirOwnList() {
        var settings = NotchSettings()
        settings.appsShownIn = [keynote]
        settings.appsHiddenIn = [quickTime]
        settings.appFilter = .only
        XCTAssertEqual(settings.chosenApps, [keynote])
        XCTAssertTrue(settings.islandVisible(frontmost: keynote.bundleID, needsAttention: false))
        XCTAssertFalse(settings.islandVisible(frontmost: quickTime.bundleID, needsAttention: false))
        settings.appFilter = .except
        XCTAssertEqual(settings.chosenApps, [quickTime])
        XCTAssertTrue(settings.islandVisible(frontmost: keynote.bundleID, needsAttention: false))
        XCTAssertFalse(settings.islandVisible(frontmost: quickTime.bundleID, needsAttention: false))
        settings.alwaysShowAgentRequests = false
        XCTAssertFalse(settings.islandVisible(frontmost: quickTime.bundleID, needsAttention: true))
        settings.appFilter = .all
        XCTAssertEqual(settings.chosenApps, [])
        XCTAssertTrue(settings.islandVisible(frontmost: quickTime.bundleID, needsAttention: false))
    }

    /// Each mode keeps its own list; an app is added once; removal ignores case.
    func testAddAndRemoveChosenApps() {
        var settings = NotchSettings()
        settings.addChosenApp(keynote)
        XCTAssertEqual(settings.appsShownIn + settings.appsHiddenIn, [], "«Во всех приложениях» has no list")
        settings.appFilter = .except
        settings.addChosenApp(keynote)
        settings.addChosenApp(ChosenApp(bundleID: "COM.apple.iWork.Keynote", name: "Keynote again"))
        settings.addChosenApp(quickTime)
        XCTAssertEqual(settings.appsHiddenIn, [keynote, quickTime])
        XCTAssertEqual(settings.appsShownIn, [])
        settings.removeChosenApp("com.apple.iwork.keynote")
        XCTAssertEqual(settings.appsHiddenIn, [quickTime])
    }

    // MARK: Keeping it

    func testDefaults() {
        let settings = NotchSettings.load(from: defaults)
        XCTAssertEqual(settings.appFilter, .all, "the island shows in every app out of the box")
        XCTAssertEqual(settings.appsShownIn, [])
        XCTAssertEqual(settings.appsHiddenIn, [])
        XCTAssertTrue(settings.alwaysShowAgentRequests)
        XCTAssertEqual(settings.islandOffsets, [:], "the capsule is centered on every screen")
        XCTAssertEqual(settings.islandOffset(forDisplay: IslandDisplayKey.builtin), 0)
    }

    func testRoundTrip() {
        var settings = NotchSettings()
        settings.appFilter = .except
        settings.appsHiddenIn = [keynote, quickTime]
        settings.appsShownIn = [ChosenApp(bundleID: terminal, name: "Terminal")]
        settings.alwaysShowAgentRequests = false
        settings.setIslandOffset(-412, forDisplay: IslandDisplayKey.builtin)
        settings.setIslandOffset(388.4, forDisplay: "display-7789-41234-16843009")
        settings.save(to: defaults)
        let loaded = NotchSettings.load(from: defaults)
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.islandOffset(forDisplay: "display-7789-41234-16843009"), 388, "whole points")
        XCTAssertEqual(defaults.stringArray(forKey: SettingsKey.appsHiddenIn),
                       ["com.apple.iWork.Keynote\tKeynote", "com.apple.QuickTimePlayerX\tQuickTime Player"])
    }

    /// Lists and offsets written by hand (`defaults write`) still count; junk is dropped, never the whole setting.
    func testHandWrittenValues() {
        defaults.set(["com.apple.Safari", "  ", "com.apple.Safari\tSafari", "has space\tX", 42, "org.videolan.vlc\tVLC"],
                     forKey: SettingsKey.appsShownIn)
        defaults.set(["builtin": "-120", "display-1-2-3": 1e9, "display-4-5-6": "junk", "": 5, "display-7-8-9": 0],
                     forKey: SettingsKey.islandOffsets)
        defaults.set("sometimes", forKey: SettingsKey.appFilter)
        let settings = NotchSettings.load(from: defaults)
        XCTAssertEqual(settings.appsShownIn.map(\.bundleID), ["com.apple.Safari", "org.videolan.vlc"])
        XCTAssertEqual(settings.appsShownIn.first?.name, "", "a bare bundle id has no stored name")
        XCTAssertEqual(settings.islandOffsets, ["builtin": -120, "display-1-2-3": NotchSettings.maxIslandOffset])
        XCTAssertEqual(settings.appFilter, .all, "an unknown mode falls back to the default")
    }

    /// The capsule's place is kept per display: the Mac's own screen by itself, any other by what it reports (vendor,
    /// model, serial), so a monitor keeps its place on another port or dock; centered is not stored.
    func testOffsetsAreKeptPerDisplay() {
        XCTAssertEqual(IslandDisplayKey.make(builtin: true, vendor: 1552, model: 41_002, serial: 0), "builtin")
        let dell = IslandDisplayKey.make(builtin: false, vendor: 4268, model: 41_234, serial: 16_843_009)
        XCTAssertEqual(dell, "display-4268-41234-16843009")
        XCTAssertNotEqual(dell, IslandDisplayKey.make(builtin: false, vendor: 4268, model: 41_234, serial: 16_843_010),
                          "two monitors of the same model keep their own places")
        var settings = NotchSettings()
        settings.setIslandOffset(-300, forDisplay: "builtin")
        settings.setIslandOffset(250, forDisplay: dell)
        XCTAssertEqual(settings.islandOffset(forDisplay: "builtin"), -300)
        XCTAssertEqual(settings.islandOffset(forDisplay: dell), 250)
        XCTAssertEqual(settings.islandOffset(forDisplay: "display-1-1-1"), 0, "a display never moved on: centered")
        settings.setIslandOffset(-0.3, forDisplay: "builtin")
        XCTAssertNil(settings.islandOffsets["builtin"], "back at the center: nothing stored")
        settings.setIslandOffset(.infinity, forDisplay: dell)
        XCTAssertNil(settings.islandOffsets[dell])
        XCTAssertEqual(NotchSettings.storedOffset(-12_000), -NotchSettings.maxIslandOffset)
    }

    /// «Сбросить всё» centers the capsule again and shows the island everywhere.
    func testResetCentersAndShowsEverywhere() {
        var settings = NotchSettings()
        settings.appFilter = .only
        settings.appsShownIn = [keynote]
        settings.setIslandOffset(100, forDisplay: "builtin")
        let fresh = settings.reset()
        XCTAssertEqual(fresh.appFilter, .all)
        XCTAssertEqual(fresh.appsShownIn, [])
        XCTAssertEqual(fresh.islandOffsets, [:])
    }

    func testStoredAppEncoding() {
        XCTAssertEqual(ChosenApp(stored: "com.apple.Music\tMusic"), ChosenApp(bundleID: "com.apple.Music", name: "Music"))
        XCTAssertEqual(ChosenApp(stored: "com.apple.Music")?.stored, "com.apple.Music")
        XCTAssertEqual(ChosenApp(bundleID: "a.b", name: "Tab\tName").stored.split(separator: "\t").count, 3,
                       "a name may hold anything after the first tab")
        XCTAssertEqual(ChosenApp(stored: "a.b\tTab\tName")?.name, "Tab\tName")
        XCTAssertNil(ChosenApp(stored: ""))
        XCTAssertNil(ChosenApp(stored: "\tName"))
    }
}
