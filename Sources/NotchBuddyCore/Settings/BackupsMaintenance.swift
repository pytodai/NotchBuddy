import Foundation

/// The config backups the hook installers leave in `~/.notchbuddy/backups/<timestamp>/`: how much there is, and
/// clearing them from the settings page. Only timestamp folders are touched; anything else in the directory
/// (or the directory itself) is left alone.
public enum BackupsMaintenance {
    public struct Summary: Equatable, Sendable {
        /// Timestamp folders (one per install / uninstall).
        public var snapshots: Int
        public var files: Int
        public var bytes: Int64
        public var newest: Date?

        public init(snapshots: Int = 0, files: Int = 0, bytes: Int64 = 0, newest: Date? = nil) {
            self.snapshots = snapshots
            self.files = files
            self.bytes = bytes
            self.newest = newest
        }

        public static let empty = Summary()
    }

    /// `2026-09-29T14-03-11` (the installers' folder names).
    public static func isSnapshotName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    public static func summary(at directory: URL = Paths.backupsDir) -> Summary {
        let fm = FileManager.default
        var summary = Summary()
        for snapshot in snapshots(at: directory) {
            summary.snapshots += 1
            if let date = (try? snapshot.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date > (summary.newest ?? .distantPast) {
                summary.newest = date
            }
            let files = (try? fm.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
            for file in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                summary.files += 1
                summary.bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return summary
    }

    /// Removes every timestamp folder. Returns how many were removed; the first failure is thrown after the
    /// rest were tried.
    @discardableResult
    public static func clear(at directory: URL = Paths.backupsDir) throws -> Int {
        var removed = 0
        var failure: Error?
        for snapshot in snapshots(at: directory) {
            do {
                try FileManager.default.removeItem(at: snapshot)
                removed += 1
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
        return removed
    }

    private static func snapshots(at directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return entries.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return isSnapshotName(url.lastPathComponent) && values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    /// "3 копии · 48 КБ".
    public static func describe(_ summary: Summary) -> String {
        guard summary.snapshots > 0 else { return L("Копий нет") }
        let count = summary.snapshots
        let noun = RussianPlural.pick(count, "копия", "копии", "копий")
        return "\(count) \(noun) · \(formatBytes(summary.bytes))"
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return L("%@ Б", bytes) }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return L("%@ КБ", Int(kb.rounded())) }
        let mb = kb / 1024
        return L("%@ МБ", L10n.decimal(mb))
    }
}

public enum RussianPlural {
    /// Russian forms in, the interface language's form out (`Lp`): one: 1, 21, 31…; few: 2–4, 22–24…; many: the rest.
    public static func pick(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        Lp(n, one, few, many)
    }
}
