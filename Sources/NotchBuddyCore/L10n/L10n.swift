import Foundation
import Observation

// NotchBuddy's localization layer: every user-facing string goes through `L(…)`.
//
// Keys are the Russian source text (Russian is the development language, `defaultLocalization: "ru"`), so a call
// site reads like the copy it shows: `L("Готово")`, `L("работает %@", clock)`. The tables are SwiftPM resources of
// this target (`Resources/<lang>.lproj/Localizable.strings`); `ru` maps each key to itself (edit Russian copy there
// without touching code), `en` holds the English. A key missing from a table falls back to the Russian text, so
// nothing ever shows a raw key.
//
// - Arguments: `%@` (in order) or `%1$@` (by position) — every argument is turned into text first, so there are no
//   type specifiers to get wrong; `%%` is a literal percent sign in a string that has arguments.
// - Plurals: `Lp(n, "сессия|сессии|сессий")` — the key holds the Russian one|few|many forms, the English entry
//   one|other ("session|sessions").
// - Context: `Lc("meeting", "идёт")` when the same Russian needs a different translation elsewhere; the key is
//   "meeting::идёт".
// - Live switching: `L10n.shared.language` is `Observable`, and every `L(…)` reads it, so a SwiftUI body that shows a
//   localized string re-renders when the language changes. AppKit code listens to `L10n.didChange`.

/// The language setting: Settings → «Язык / Language».
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    /// Follow macOS (the first of the user's preferred languages NotchBuddy has; English otherwise).
    case auto
    case ru
    case en
}

/// A language the interface is actually shown in.
public enum UILanguage: String, CaseIterable, Codable, Sendable {
    case ru
    case en

    /// For dates and numbers shown next to localized copy.
    public var locale: Locale {
        switch self {
        case .ru: return Locale(identifier: "ru_RU")
        case .en: return Locale(identifier: "en_US")
        }
    }

    /// The language's own name ("Русский", "English") — shown untranslated, as macOS does.
    public var nativeName: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    /// The name inside a sentence in that same language ("сейчас русский", "English right now").
    public var nameInSentence: String {
        switch self {
        case .ru: return "русский"
        case .en: return "English"
        }
    }
}

public final class L10n: Observable, @unchecked Sendable {
    public static let shared = L10n()

    /// Posted on the main thread after the interface language changed (AppKit menus and alerts rebuild on it).
    public static let didChange = Notification.Name("NotchBuddyLanguageDidChange")

    /// UserDefaults key of the setting (the app's domain; the bridge reads it from there too).
    public static let settingsKey = "settings.language"
    /// The app's bundle identifier: the defaults domain the bridge reads the setting from.
    public static let appDomain = "me.sokolov.notchbuddy"
    /// `NOTCHBUDDY_LANG=ru|en` overrides the setting for the process (renders, benchmarks, the bridge in a test).
    public static let environmentKey = "NOTCHBUDDY_LANG"
    /// The resource bundle SwiftPM builds for this target.
    public static let bundleName = "NotchBuddy_NotchBuddyCore.bundle"
    /// The same tables as a plain folder of `<lang>.lproj`: in the app's Resources (`build-app.sh`) and next to the
    /// bridge in `~/.notchbuddy/bin` (copied by the app).
    public static let folderName = "Localization"

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var _preference: AppLanguage
    private var _language: UILanguage
    private var tables: [UILanguage: [String: String]] = [:]
    private var resolvedBundleURL: URL??

    init(preference: AppLanguage? = nil) {
        let preference = preference ?? Self.storedPreference()
        _preference = preference
        _language = Self.resolve(preference)
    }

    // MARK: Language

    /// The interface language. Observed: reading it inside a SwiftUI body (every `L(…)` does) re-renders that view
    /// when it changes.
    public var language: UILanguage {
        registrar.access(self, keyPath: \.language)
        return lock.withLock { _language }
    }

    /// The language without registering an observation (for code that must not track it).
    public var currentLanguage: UILanguage { lock.withLock { _language } }

    public var preference: AppLanguage { lock.withLock { _preference } }

    /// Applies the setting; the environment override (`NOTCHBUDDY_LANG`) still wins. Posts `didChange` (on the main
    /// thread) when the shown language changes.
    public func setPreference(_ preference: AppLanguage) {
        lock.withLock { _preference = preference }
        apply(Self.resolve(preference))
    }

    /// Re-resolves «Авто» (macOS languages may have changed).
    public func refresh() {
        apply(Self.resolve(preference))
    }

    /// Shows `language` whatever the setting says (tests, renders). `nil` goes back to the setting.
    public func override(_ language: UILanguage?) {
        apply(language ?? Self.resolve(preference))
    }

    private func apply(_ new: UILanguage) {
        guard lock.withLock({ _language }) != new else { return }
        registrar.withMutation(of: self, keyPath: \.language) {
            lock.withLock { _language = new }
        }
        let post = { NotificationCenter.default.post(name: Self.didChange, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    public var locale: Locale { language.locale }

    /// A number with the interface language's decimal separator and `digits` after it: 1.5 → "1,5" / "1.5".
    public static func decimal(_ value: Double, digits: Int = 1) -> String {
        let text = String(format: "%.\(max(digits, 0))f", value.isFinite ? value : 0)
        return shared.language == .ru ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    /// «Авто» → the first of macOS' preferred languages NotchBuddy speaks, else English.
    public static func autoLanguage(preferred: [String] = Locale.preferredLanguages) -> UILanguage {
        for identifier in preferred {
            let code = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let code, let language = UILanguage(rawValue: code) { return language }
        }
        return .en
    }

    static func resolve(_ preference: AppLanguage) -> UILanguage {
        if let forced = environmentLanguage { return forced }
        switch preference {
        case .ru: return .ru
        case .en: return .en
        case .auto:
            // Tests compare Russian copy: the development language unless a test asks for another.
            if isRunningTests { return .ru }
            return autoLanguage()
        }
    }

    static var environmentLanguage: UILanguage? {
        ProcessInfo.processInfo.environment[environmentKey].flatMap { UILanguage(rawValue: $0.lowercased()) }
    }

    static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    /// The stored setting: the app's own defaults, or — from another process (the bridge) — the app's domain.
    static func storedPreference() -> AppLanguage {
        let defaults: UserDefaults?
        if Bundle.main.bundleIdentifier == appDomain || isRunningTests {
            defaults = isRunningTests ? nil : .standard
        } else {
            defaults = UserDefaults(suiteName: appDomain)
        }
        return defaults?.string(forKey: settingsKey).flatMap(AppLanguage.init(rawValue:)) ?? .auto
    }

    // MARK: Lookup

    /// The text of `key` in the current language (the key itself when no table has it).
    public func string(_ key: String) -> String {
        string(key, in: language)
    }

    public func string(_ key: String, in language: UILanguage) -> String {
        if let value = table(language)[key] { return value }
        if language != .ru, let value = table(.ru)[key] { return value }
        return Self.sourceText(key)
    }

    /// "meeting::идёт" → "идёт": the Russian text of a key when the tables are not there.
    static func sourceText(_ key: String) -> String {
        guard let range = key.range(of: "::") else { return key }
        return String(key[range.upperBound...])
    }

    /// `%@` / `%1$@` replaced by `args`, `%%` by `%`. Without arguments the text is returned as is.
    public static func format(_ template: String, _ args: [String]) -> String {
        guard !args.isEmpty, template.contains("%") else { return template }
        var out = ""
        out.reserveCapacity(template.count + args.reduce(0) { $0 + $1.count })
        var next = 0
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            guard c == "%" else { out.append(c); i = template.index(after: i); continue }
            let j = template.index(after: i)
            guard j < template.endIndex else { out.append(c); break }
            if template[j] == "%" { out.append("%"); i = template.index(after: j); continue }
            if template[j] == "@" {
                if next < args.count { out += args[next] }
                next += 1
                i = template.index(after: j)
                continue
            }
            // %N$@
            var k = j
            var digits = ""
            while k < template.endIndex, template[k].isASCII, template[k].isNumber { digits.append(template[k]); k = template.index(after: k) }
            if !digits.isEmpty, k < template.endIndex, template[k] == "$" {
                let at = template.index(after: k)
                if at < template.endIndex, template[at] == "@", let n = Int(digits), n >= 1 {
                    if n - 1 < args.count { out += args[n - 1] }
                    i = template.index(after: at)
                    continue
                }
            }
            out.append(c)
            i = j
        }
        return out
    }

    /// The form of `forms` ("один|несколько|много" in Russian, "one|other" in English) for `n`.
    public func plural(_ n: Int, _ forms: String) -> String {
        let lang = language
        let text = string(forms, in: lang)
        let parts = text.components(separatedBy: "|")
        return Self.pick(n, parts, rule: lang)
    }

    static func pick(_ n: Int, _ forms: [String], rule: UILanguage) -> String {
        guard let first = forms.first else { return "" }
        let n = n == Int.min ? Int.max : abs(n)
        switch rule {
        case .ru:
            guard forms.count >= 3 else { return n == 1 ? first : forms[forms.count - 1] }
            let mod10 = n % 10, mod100 = n % 100
            if mod10 == 1 && mod100 != 11 { return forms[0] }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return forms[1] }
            return forms[2]
        case .en:
            return n == 1 ? first : forms[min(1, forms.count - 1)]
        }
    }

    // MARK: Tables

    /// The table of a language (loaded once; empty when the resources cannot be found).
    public func table(_ language: UILanguage) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let table = tables[language] { return table }
        let table = loadTable(language)
        tables[language] = table
        return table
    }

    private func loadTable(_ language: UILanguage) -> [String: String] {
        guard let bundle = bundleURL() else { return [:] }
        for url in Self.tableURLs(in: bundle, language) {
            if let table = Self.parseStrings(at: url) { return table }
        }
        return [:]
    }

    /// A table in a bundle as SwiftPM builds it (`Contents/Resources/<lang>.lproj`) or flat (`<lang>.lproj`, the
    /// copy in the app and next to the bridge).
    public static func tableURLs(in bundle: URL, _ language: UILanguage) -> [URL] {
        let file = "\(language.rawValue).lproj/Localizable.strings"
        return [bundle.appendingPathComponent(file), bundle.appendingPathComponent("Contents/Resources/" + file)]
    }

    /// A `.strings` file (UTF-8 or UTF-16, text or binary plist) as a dictionary.
    public static func parseStrings(at url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return plist as? [String: String]
    }

    private func bundleURL() -> URL? {
        if let cached = resolvedBundleURL { return cached }
        let found = Self.candidateBundleURLs().first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        resolvedBundleURL = .some(found)
        return found
    }

    /// Where the tables may be: the app's Resources, next to the executable (`swift build`, the bridge in
    /// `~/.notchbuddy/bin`), the app's Resources seen from `Contents/Helpers` (the bundled bridge), and next to the
    /// test bundle; in each, the plain folder first, then SwiftPM's bundle.
    static func candidateBundleURLs() -> [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources) }
        dirs.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = executable.deletingLastPathComponent()
            dirs.append(dir)
            dirs.append(dir.deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        let own = Bundle(for: L10n.self)
        dirs.append(own.bundleURL.deletingLastPathComponent())
        if let resources = own.resourceURL { dirs.append(resources) }
        var seen = Set<String>()
        return dirs.flatMap { [$0.appendingPathComponent(folderName), $0.appendingPathComponent(bundleName)] }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The resource bundle this process uses (nil: none found, Russian source text shown).
    public var resourceBundleURL: URL? {
        lock.withLock { bundleURL() }
    }
}

// MARK: - Call-site helpers

/// The localized text of `key` (the Russian source text), with `%@` / `%1$@` replaced by `args`.
@inline(__always)
public func L(_ key: String, _ args: Any...) -> String {
    let template = L10n.shared.string(key)
    guard !args.isEmpty else { return template }
    return L10n.format(template, args.map { "\($0)" })
}

/// The Russian source text of a string that is stored now and translated where it is shown (`L(stored)`): tables
/// built once (the agent catalog) and notes kept in models, so they follow a language switch.
@inline(__always)
public func LKey(_ key: String) -> String { key }

/// Like `L`, for a key that needs a context to tell two translations of the same Russian apart: "context::key".
public func Lc(_ context: String, _ key: String, _ args: Any...) -> String {
    let template = L10n.shared.string("\(context)::\(key)")
    guard !args.isEmpty else { return template }
    return L10n.format(template, args.map { "\($0)" })
}

/// The plural form for `n`: `Lp(3, "сессия|сессии|сессий")` → "сессии" / "sessions".
public func Lp(_ n: Int, _ forms: String) -> String {
    L10n.shared.plural(n, forms)
}

/// Russian-style call (`plural(n, "сессия", "сессии", "сессий")`) localized: the key is "сессия|сессии|сессий".
public func Lp(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    L10n.shared.plural(n, "\(one)|\(few)|\(many)")
}
