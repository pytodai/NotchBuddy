import Foundation

// Settings → Остров: in which apps the island shows («Где показывать») and where a dragged «Островок» sits on each
// display. Plain values and pure decisions; the island applies them (`IslandController`), the settings page edits them.

// MARK: - Where the island shows (per app)

/// «Где показывать»: in every app, only while one of the chosen apps is in front, or everywhere except while one of them
/// is (games, video, Keynote).
public enum IslandAppFilter: String, CaseIterable, Codable, Sendable {
    case all, only, except

    /// The segment's title.
    public var label: String {
        switch self {
        case .all: return L("Во всех приложениях")
        case .only: return L("Только в выбранных")
        case .except: return L("Везде, кроме выбранных")
        }
    }

    /// One line under the segments.
    public var hint: String {
        switch self {
        case .all: return L("Остров виден, какое бы приложение ни было впереди.")
        case .only: return L("Остров виден, только пока впереди одно из этих приложений.")
        case .except: return L("Остров прячется, пока впереди одно из этих приложений: игры, видео, Keynote.")
        }
    }

    /// Whether the list of chosen apps applies.
    public var usesApps: Bool { self != .all }
}

/// An app chosen in «Где показывать»: its bundle identifier (what counts) and its name when it was chosen (shown when the
/// app cannot be found any more).
public struct ChosenApp: Equatable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    /// Bundle identifiers compare without case (Launch Services does).
    public var id: String { bundleID.lowercased() }

    /// "com.apple.iWork.Keynote\tKeynote".
    var stored: String { name.isEmpty ? bundleID : "\(bundleID)\t\(name)" }

    init?(stored: String) {
        let parts = stored.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let id = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !id.isEmpty, !id.contains(" ") else { return nil }
        self.init(bundleID: id, name: parts.count > 1 ? String(parts[1]) : "")
    }

    /// Each app once (the first spelling wins), in the given order.
    public static func unique(_ apps: [ChosenApp]) -> [ChosenApp] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.id).inserted }
    }
}

/// Whether the island shows, as a pure function of «Где показывать» and the app in front.
public enum IslandAppVisibility {
    /// - `frontmost`: the bundle identifier of the app in front (NotchBuddy itself never counts: the caller passes the
    ///   last other app); nil when unknown (it shows).
    /// - `needsAttention`: a permission request is waiting, or a "needs you" notice is up.
    /// - `requestsAlwaysShow`: «Всегда показывать запросы агентов».
    ///
    /// An empty list restricts nothing (the settings say so under it).
    public static func isVisible(filter: IslandAppFilter, chosen: [ChosenApp], frontmost: String?,
                                 needsAttention: Bool, requestsAlwaysShow: Bool) -> Bool {
        if needsAttention, requestsAlwaysShow { return true }
        guard filter.usesApps, let frontmost, !frontmost.isEmpty, !chosen.isEmpty else { return true }
        let key = frontmost.lowercased()
        let isChosen = chosen.contains { $0.id == key }
        return filter == .only ? isChosen : !isChosen
    }
}

// MARK: - Where a dragged «Островок» sits

/// A display's key for settings that belong to one physical screen (the dragged capsule's offset). A display's UUID
/// changes with the port or dock it hangs on (which is why the old per-display styles were dropped in the v3
/// migration, `SettingsMigration`), so this is built from what the display reports about itself: the Mac's own screen
/// is "builtin", any other "display-<vendor>-<model>-<serial>".
public enum IslandDisplayKey {
    public static let builtin = "builtin"

    public static func make(builtin: Bool, vendor: UInt32, model: UInt32, serial: UInt32) -> String {
        builtin ? Self.builtin : "display-\(vendor)-\(model)-\(serial)"
    }
}

extension NotchSettings {
    /// The apps «Где показывать» counts now (none for «Во всех приложениях»).
    public var chosenApps: [ChosenApp] {
        switch appFilter {
        case .all: return []
        case .only: return appsShownIn
        case .except: return appsHiddenIn
        }
    }

    /// Adds `app` to the list of the current filter (once); nothing for «Во всех приложениях».
    public mutating func addChosenApp(_ app: ChosenApp) {
        switch appFilter {
        case .all: return
        case .only: appsShownIn = ChosenApp.unique(appsShownIn + [app])
        case .except: appsHiddenIn = ChosenApp.unique(appsHiddenIn + [app])
        }
    }

    public mutating func removeChosenApp(_ bundleID: String) {
        let key = bundleID.lowercased()
        switch appFilter {
        case .all: return
        case .only: appsShownIn.removeAll { $0.id == key }
        case .except: appsHiddenIn.removeAll { $0.id == key }
        }
    }

    /// Whether the island shows while `frontmost` is in front (see `IslandAppVisibility`).
    public func islandVisible(frontmost: String?, needsAttention: Bool) -> Bool {
        IslandAppVisibility.isVisible(filter: appFilter, chosen: chosenApps, frontmost: frontmost,
                                      needsAttention: needsAttention, requestsAlwaysShow: alwaysShowAgentRequests)
    }

    /// How far the dragged «Островок» sits from the screen's top center on the display `key`, in points (left < 0); 0 when
    /// it was never moved there. The island clamps it to the screen it is on.
    public func islandOffset(forDisplay key: String) -> Double {
        islandOffsets[key] ?? 0
    }

    /// Remembers the capsule's place on the display `key` (whole points; the center is not stored).
    public mutating func setIslandOffset(_ offset: Double, forDisplay key: String) {
        let value = Self.storedOffset(offset)
        if value == 0 { islandOffsets[key] = nil } else { islandOffsets[key] = value }
    }

    /// An offset as it is kept: whole points within ±`maxIslandOffset` (0 for anything unreadable).
    public static func storedOffset(_ offset: Double) -> Double {
        guard offset.isFinite else { return 0 }
        let rounded = min(max(offset, -maxIslandOffset), maxIslandOffset).rounded()
        return rounded == 0 ? 0 : rounded   // no -0
    }

    /// Wider than any screen's half: a stored offset beyond it was written by hand.
    public static let maxIslandOffset: Double = 8000
}
