import Foundation

public enum HookInstallStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// Some of our entries are present but not all (e.g. Codex hooks without trust entries).
    case partial(String)
    /// The agent's config directory doesn't exist — agent probably not installed.
    case agentMissing
    /// The config exists but can't be parsed; we refuse to touch it.
    case error(String)
}

/// Installs / removes NotchBuddy's hook entries in one agent's config files.
/// Implementations must: back up every file before writing it (`HookInstallers.backup`),
/// preserve all foreign content, be idempotent (install twice == install once),
/// recognize our entries by `Paths.hookMarker` in the command string,
/// refuse to write if an existing file doesn't parse, and write atomically.
public protocol AgentHookInstaller: Sendable {
    var source: AgentSource { get }
    /// Config files this installer may read/write.
    var files: [URL] { get }
    func status() -> HookInstallStatus
    /// `bridgePath`: absolute path of the bridge binary to register (normally `Paths.bridge.path`).
    func install(bridgePath: String) throws
    func uninstall() throws
}

/// For agents without a hook system NotchBuddy can edit.
public struct UnsupportedHookInstaller: AgentHookInstaller {
    public let source: AgentSource
    public var files: [URL] { [] }
    public func status() -> HookInstallStatus { .agentMissing }
    public func install(bridgePath: String) throws {}
    public func uninstall() throws {}
}

public enum HookInstallerError: LocalizedError, Equatable, CustomStringConvertible {
    case unparsableConfig(path: String, reason: String)
    case writeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .unparsableConfig(let p, let r): return L("Не удалось разобрать %@: %@", p, r)
        case .writeFailed(let p, let r): return L("Не удалось записать %@: %@", p, r)
        }
    }

    /// Keeps the real reason when the error is wrapped via `localizedDescription`.
    public var errorDescription: String? { description }
}

public enum HookInstallers {
    /// `home` is injectable for tests.
    /// The installer `AgentCatalog` names for `source` (its `InstallFamily`); agents without one get
    /// `UnsupportedHookInstaller` (status `.agentMissing`, install/uninstall do nothing).
    public static func installer(for source: AgentSource, home: URL = Paths.home) -> AgentHookInstaller {
        AgentCatalog.descriptor(for: source).flatMap { catalogInstaller(for: $0, home: home) }
            ?? UnsupportedHookInstaller(source: source)
    }

    /// Copies the file at `url` (if any; a symlink's target, not the link) to
    /// `backupsDir/<timestamp>/<path-with-slashes-replaced>`, named after `url` itself.
    /// Configs can hold API keys, so the copy is 0600 in 0700 directories whatever the source's mode.
    @discardableResult
    public static func backup(_ url: URL, home: URL = Paths.home, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        let source = try resolvedTarget(url)
        guard fm.fileExists(atPath: source.path) else { return nil }
        let data = try Data(contentsOf: source)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let backups = home.appendingPathComponent(".notchbuddy/backups", isDirectory: true)
        let dir = backups.appendingPathComponent(f.string(from: now), isDirectory: true)
        try makePrivateDirectory(backups)  // also tightens one created earlier with 0755
        try makePrivateDirectory(dir)
        var rel = url.path
        if rel.hasPrefix(home.path) { rel = String(rel.dropFirst(home.path.count)) }
        let name = rel.split(separator: "/").joined(separator: "__")
        let dest = dir.appendingPathComponent(name)
        if (try? fm.attributesOfItem(atPath: dest.path)) != nil { try fm.removeItem(at: dest) }
        guard fm.createFile(atPath: dest.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dest.path])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return dest
    }

    /// Atomic write. When `url` is a symlink (dotfiles), the file it points to is replaced and the link
    /// stays; that file keeps its POSIX permissions. A file that did not exist is created 0600.
    public static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        do {
            let target = try resolvedTarget(url)
            let perms = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target, options: .atomic)
            try fm.setAttributes([.posixPermissions: perms ?? NSNumber(value: 0o600)], ofItemAtPath: target.path)
        } catch let error as HookInstallerError {
            throw error
        } catch {
            throw HookInstallerError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Why an atomic write to `url` would fail, checked before anything is written; nil if it looks fine.
    static func writeProblem(_ url: URL) -> String? {
        let fm = FileManager.default
        guard let target = try? resolvedTarget(url) else { return L("слишком длинная цепочка символических ссылок") }
        if let attributes = try? fm.attributesOfItem(atPath: target.path),
           (attributes[.immutable] as? NSNumber)?.boolValue == true {
            return L("файл защищён от изменений (флаг uchg)")
        }
        var dir = target.deletingLastPathComponent()
        while !fm.fileExists(atPath: dir.path) && dir.path != "/" { dir = dir.deletingLastPathComponent() }
        if !fm.isWritableFile(atPath: dir.path) { return L("нет прав на запись в папку %@", dir.path) }
        return nil
    }

    /// The path a write to `url` really lands on: the end of its symlink chain (relative links are
    /// resolved against the link's folder), or `url` itself. The target need not exist yet.
    static func resolvedTarget(_ url: URL) throws -> URL {
        let fm = FileManager.default
        var current = url
        for _ in 0..<32 {
            guard let attributes = try? fm.attributesOfItem(atPath: current.path),
                  attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return current }
            let destination = try fm.destinationOfSymbolicLink(atPath: current.path)
            // No lexical `..` clean-up: the kernel resolves a relative link against the link's real folder.
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
        }
        throw HookInstallerError.writeFailed(path: url.path, reason: L("слишком длинная цепочка символических ссылок"))
    }

    private static func makePrivateDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
}
