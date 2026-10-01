import AppKit
import CryptoKit
import Foundation
import NotchBuddyCore

/// What the menu shows for one agent's hooks.
struct HookReport: Equatable, Sendable {
    var status: HookInstallStatus
    /// Config files of this agent that exist on disk ("Показать файл настроек").
    var existingFiles: [URL]
}

/// Installs / removes agent hooks and deploys the bridge binary.
/// All config file IO runs on one serial background queue, so edits never overlap.
struct HookInstallService: Sendable {
    var bridgePath: String = Paths.bridge.path
    var home: URL = Paths.home

    static let didOfferHooksKey = "didOfferHooks"

    private static let queue = DispatchQueue(label: "me.sokolov.notchbuddy.hooks", qos: .userInitiated)

    // MARK: Hook configs

    func installer(for source: AgentSource) -> AgentHookInstaller {
        HookInstallers.installer(for: source, home: home)
    }

    func report(for source: AgentSource) async -> HookReport {
        let installer = installer(for: source)
        return (try? await Self.run { Self.makeReport(installer) })
            ?? HookReport(status: .error(L("неизвестная ошибка")), existingFiles: [])
    }

    /// Status of every agent in `sources`: the Settings list by default (`AgentCatalog.settingsAgents`).
    /// The menu bar and the first-launch offer pass the original three (`AgentSource.allCases`): catalog
    /// agents are installed only from Settings.
    func reports(_ sources: [AgentSource] = AgentCatalog.settingsAgents) async -> [AgentSource: HookReport] {
        var result: [AgentSource: HookReport] = [:]
        for source in sources {
            result[source] = await report(for: source)
        }
        return result
    }

    /// Installs (idempotently) and returns the resulting state.
    func install(_ source: AgentSource) async throws -> HookReport {
        let installer = installer(for: source)
        let bridgePath = bridgePath
        do {
            let report = try await Self.run {
                try installer.install(bridgePath: bridgePath)
                return Self.makeReport(installer)
            }
            Log.info("hooks installed for \(source.rawValue): \(report.status)")
            return report
        } catch {
            Log.error("hook install failed for \(source.rawValue): \(error)")
            throw error
        }
    }

    func uninstall(_ source: AgentSource) async throws -> HookReport {
        let installer = installer(for: source)
        do {
            let report = try await Self.run {
                try installer.uninstall()
                return Self.makeReport(installer)
            }
            Log.info("hooks removed for \(source.rawValue): \(report.status)")
            return report
        } catch {
            Log.error("hook uninstall failed for \(source.rawValue): \(error)")
            throw error
        }
    }

    private static func makeReport(_ installer: AgentHookInstaller) -> HookReport {
        let fm = FileManager.default
        return HookReport(
            status: installer.status(),
            existingFiles: installer.files.filter { fm.fileExists(atPath: $0.path) })
    }

    private static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: First launch

    /// Once per install: offers to add hooks for every agent found on this Mac.
    /// Returns true if anything was installed. The offer is a non-modal window: while it waits for an
    /// answer, the main thread keeps serving socket events and the island.
    @MainActor
    func offerInstallOnFirstLaunch(defaults: UserDefaults = .standard) async -> Bool {
        guard !defaults.bool(forKey: Self.didOfferHooksKey) else { return false }
        let current = await reports(AgentSource.allCases).mapValues(\.status)
        let found = AgentSource.allCases.filter { current[$0] != .agentMissing }
        // Nothing to offer yet: ask again on a later launch, when an agent may be installed.
        guard !found.isEmpty else { return false }

        let pending = found.filter { current[$0] != .installed }
        guard !pending.isEmpty else {
            defaults.set(true, forKey: Self.didOfferHooksKey)
            return false
        }

        let names = pending.map(\.displayName).joined(separator: ", ")
        var message = L("Найдены: %@.\nNotchBuddy добавит свои хуки в их настройки, чтобы показывать статус сессий и запросы разрешений. Чужие хуки не трогаются, перед каждым изменением делается резервная копия в ~/.notchbuddy/backups.", names)
        if pending.contains(.codex) {
            message += "\n\n" + Self.codexTrustNotice
        }
        message += "\n\n" + L("Потом это можно изменить в меню «Хуки».")
        let confirmed = await Alerts.confirm(
            title: L("Подключить NotchBuddy к агентам?"),
            message: message,
            confirmTitle: L("Установить"),
            cancelTitle: L("Не сейчас"))
        // Marked only once answered: quitting while the offer is up brings it back on the next launch.
        defaults.set(true, forKey: Self.didOfferHooksKey)
        guard confirmed else {
            Log.info("first-launch hook offer declined")
            return false
        }

        var failures: [String] = []
        var notes: [String] = []
        for source in pending {
            do {
                let report = try await install(source)
                if let note = Self.followUpNote(for: source, status: report.status) { notes.append(note) }
            } catch {
                failures.append("\(source.displayName): \(Self.describe(error))")
            }
        }
        if !failures.isEmpty {
            Alerts.show(title: L("Не все хуки установлены"), message: failures.joined(separator: "\n\n"), style: .warning)
        } else if !notes.isEmpty {
            Alerts.show(title: L("Хуки установлены"), message: notes.joined(separator: "\n\n"), style: .informational)
        }
        return failures.count < pending.count
    }

    // MARK: User-facing texts

    static func describe(_ error: Error) -> String {
        if let e = error as? HookInstallerError { return e.description }
        return error.localizedDescription
    }

    static func statusText(_ status: HookInstallStatus) -> String {
        switch status {
        case .notInstalled: return L("не установлены")
        case .installed: return L("установлены")
        case .partial: return L("установлены частично")
        case .agentMissing: return L("агент не найден")
        case .error: return L("ошибка")
        }
    }

    /// Shown before installing Codex hooks: we also write trust entries, bypassing Codex's own review.
    static var codexTrustNotice: String {
        L("Для Codex хуки также будут отмечены как доверенные в ~/.codex/config.toml — без этого Codex их не запускает.")
    }

    static var codexTrustExplanation: String {
        L("Codex запускает только доверенные хуки: для каждого нужна запись trusted_hash в ~/.codex/config.toml. Без неё (или если хук изменился) Codex молча его пропускает.\n«Переустановить» запишет доверие заново. Можно и вручную: /hooks в Codex или «Настройки → Hooks» в приложении Codex.")
    }

    /// What the user should know after an install (restart needed, trust missing…).
    static func followUpNote(for source: AgentSource, status: HookInstallStatus) -> String? {
        if case .partial(let detail) = status {
            let base = L("%@: хуки установлены частично — %@", source.displayName, detail)
            return source == .codex ? base + "\n" + codexTrustExplanation : base
        }
        guard status == .installed else { return nil }
        // Claude Code picks up settings changes on its own (no note); the others say what to restart.
        return AgentCatalog.descriptor(for: source)?.restartNote
    }
}

// MARK: - Bridge binary deployment

extension HookInstallService {
    enum BridgeSyncResult: Equatable {
        case upToDate
        case copied(from: String)
        case sourceMissing
        case failed(String)
    }

    /// Where the bundled bridge lives: `Contents/Helpers` of the .app, or next to the
    /// executable when running unbundled (`swift run` puts both products in one bin dir).
    static func bundledBridgeURL(bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = [
            bundle.bundleURL.appendingPathComponent("Contents/Helpers/notchbuddy-bridge")
        ]
        if let exe = bundle.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("notchbuddy-bridge"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Copies the bridge to `Paths.bridge` (0755) when missing or different.
    /// Same size + same mtime → assumed identical; same size, other mtime → compared by SHA-256.
    /// The copy lands in a temp file and is renamed over the target, so running hooks never see
    /// a partial binary and the kernel's code-signature cache never sees a rewritten inode.
    @discardableResult
    static func syncBridgeBinary(from source: URL? = bundledBridgeURL(), to destination: URL = Paths.bridge) -> BridgeSyncResult {
        guard let source else {
            Log.error("bridge binary not found next to the app; hooks will be inert")
            return .sourceMissing
        }
        let fm = FileManager.default
        do {
            if try !needsCopy(source: source, destination: destination) {
                try ensureExecutable(destination)
                return .upToDate
            }
            let dir = destination.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let temp = dir.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: source, to: temp)
            // A quarantined helper would be blocked by Gatekeeper when an agent spawns it.
            removexattr(temp.path, "com.apple.quarantine", 0)
            let srcAttrs = try fm.attributesOfItem(atPath: source.path)
            var attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
            if let mtime = srcAttrs[.modificationDate] { attrs[.modificationDate] = mtime }
            try fm.setAttributes(attrs, ofItemAtPath: temp.path)
            guard rename(temp.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            Log.info("bridge copied \(source.path) → \(destination.path)")
            return .copied(from: source.path)
        } catch {
            Log.error("bridge sync failed: \(error)")
            return .failed("\(error)")
        }
    }

    /// Copies the localization tables next to the bridge (`~/.notchbuddy/bin/Localization/<lang>.lproj`) when they
    /// differ, so the bridge alone speaks the app's language. Each file lands through a temp file and a rename.
    @discardableResult
    static func syncBridgeLocalization(from bundle: URL? = L10n.shared.resourceBundleURL,
                                       to folder: URL = Paths.bridge.deletingLastPathComponent()
                                           .appendingPathComponent(L10n.folderName)) -> Int {
        guard let bundle else {
            Log.error("localization tables not found; the bridge will speak Russian")
            return 0
        }
        let fm = FileManager.default
        var copied = 0
        for language in UILanguage.allCases {
            guard let source = L10n.tableURLs(in: bundle, language).first(where: { fm.fileExists(atPath: $0.path) }),
                  let data = try? Data(contentsOf: source) else { continue }
            let dir = folder.appendingPathComponent("\(language.rawValue).lproj")
            let destination = dir.appendingPathComponent("Localizable.strings")
            if (try? Data(contentsOf: destination)) == data { continue }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let temp = dir.appendingPathComponent(".Localizable.strings.\(UUID().uuidString)")
                defer { try? fm.removeItem(at: temp) }
                try data.write(to: temp)
                guard rename(temp.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                copied += 1
            } catch {
                Log.error("bridge localization sync failed for \(language.rawValue): \(error)")
            }
        }
        if copied > 0 { Log.info("bridge localization: \(copied) table(s) copied to \(folder.path)") }
        return copied
    }

    private static func needsCopy(source: URL, destination: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return true }
        let src = try fm.attributesOfItem(atPath: source.path)
        let dst = try fm.attributesOfItem(atPath: destination.path)
        let srcSize = (src[.size] as? NSNumber)?.uint64Value
        let dstSize = (dst[.size] as? NSNumber)?.uint64Value
        guard srcSize == dstSize else { return true }
        if let a = src[.modificationDate] as? Date, let b = dst[.modificationDate] as? Date,
           abs(a.timeIntervalSince(b)) < 1 {
            return false
        }
        return try sha256(of: source) != sha256(of: destination)
    }

    private static func sha256(of url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    private static func ensureExecutable(_ url: URL) throws {
        let fm = FileManager.default
        let perms = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if perms & 0o777 != 0o755 {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}
