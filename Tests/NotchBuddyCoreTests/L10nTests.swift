import Foundation
import Observation
import XCTest
@testable import NotchBuddyCore

/// The localization layer: both tables have every key, translations keep their arguments and plural forms, every
/// key the code uses exists, no Russian UI text bypasses `L(…)`, and switching the language is live.
final class L10nTests: XCTestCase {
    override func tearDown() {
        L10n.shared.override(nil)
        super.tearDown()
    }

    // MARK: Tables

    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sources = repo.appendingPathComponent("Sources")

    static func sourceTable(_ language: UILanguage) -> [String: String] {
        let url = sources.appendingPathComponent("NotchBuddyCore/Resources/\(language.rawValue).lproj/Localizable.strings")
        return L10n.parseStrings(at: url) ?? [:]
    }

    func testBothLanguagesHaveTheSameKeys() {
        let ru = Self.sourceTable(.ru), en = Self.sourceTable(.en)
        XCTAssertGreaterThan(ru.count, 500, "the Russian table did not load")
        XCTAssertEqual(Set(ru.keys).subtracting(en.keys).sorted(), [], "keys without an English translation")
        XCTAssertEqual(Set(en.keys).subtracting(ru.keys).sorted(), [], "English keys missing from the Russian table")
        for (key, value) in en where value.trimmingCharacters(in: .whitespaces).isEmpty {
            XCTFail("empty English text for \(key)")
        }
        for (key, value) in ru where value.trimmingCharacters(in: .whitespaces).isEmpty {
            XCTFail("empty Russian text for \(key)")
        }
    }

    func testRussianTableIsTheSourceText() {
        for (key, value) in Self.sourceTable(.ru) {
            XCTAssertEqual(value, L10n.sourceText(key), "ru.lproj should repeat the key's own text")
        }
    }

    func testTranslationsKeepArgumentsAndPluralForms() {
        let en = Self.sourceTable(.en)
        for (key, russian) in Self.sourceTable(.ru) {
            guard let english = en[key] else { continue }
            XCTAssertEqual(Self.arguments(english), Self.arguments(russian), "arguments of \(key) → \(english)")
            XCTAssertEqual(english.components(separatedBy: "%%").count, russian.components(separatedBy: "%%").count,
                           "%% in \(key) → \(english)")
            if russian.contains("|") {
                XCTAssertEqual(russian.components(separatedBy: "|").count, 3, "Russian plural needs one|few|many: \(key)")
                XCTAssertEqual(english.components(separatedBy: "|").count, 2, "English plural needs one|other: \(key)")
            }
        }
    }

    /// The argument numbers a text uses (`%@` counted in order, `%2$@` by position).
    static func arguments(_ text: String) -> [Int] {
        let regex = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?@")
        var next = 0
        var used: [Int] = []
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range(at: 1).location != NSNotFound, let n = Int(ns.substring(with: match.range(at: 1))) {
                used.append(n)
            } else {
                next += 1
                used.append(next)
            }
        }
        return used.sorted()
    }

    func testBundledTablesMatchTheSources() {
        XCTAssertNotNil(L10n.shared.resourceBundleURL, "the resource bundle was not found next to the test bundle")
        XCTAssertEqual(L10n.shared.table(.en), Self.sourceTable(.en))
        XCTAssertEqual(L10n.shared.table(.ru), Self.sourceTable(.ru))
    }

    // MARK: Code ↔ tables

    func testEveryKeyUsedInCodeIsInBothTables() throws {
        let ru = Self.sourceTable(.ru), en = Self.sourceTable(.en)
        let used = try Self.keysUsedInCode()
        XCTAssertGreaterThan(used.count, 500)
        for (key, file) in used.sorted(by: { $0.key < $1.key }) {
            XCTAssertNotNil(ru[key], "\(file): \"\(key)\" is not in ru.lproj")
            XCTAssertNotNil(en[key], "\(file): \"\(key)\" is not in en.lproj")
        }
    }

    /// Keys in `L("…")`, `LKey("…")`, `Lc("context", "…")`, `Lp(n, "…|…|…")` and Russian plural helpers
    /// (`plural(n, "a", "b", "c")`), with the file that uses each.
    static func keysUsedInCode() throws -> [String: String] {
        let literal = #""((?:[^"\\\n]|\\.)*)""#
        let patterns: [(NSRegularExpression, ([String]) -> String)] = [
            (try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])(?:L|LKey)\(\s*"# + literal), { $0[0] }),
            (try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])Lc\(\s*"# + literal + #"\s*,\s*"# + literal), { $0[0] + "::" + $0[1] }),
            (try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])Lp\(\s*[^",()]+(?:\([^()]*\))?[^",()]*,\s*"# + literal + #"\s*\)"#), { $0[0] }),
            (try NSRegularExpression(pattern: #"(?:plural|pick|count|Lp)\(\s*[^"]*?,\s*"# + literal + #"\s*,\s*"# + literal
                                        + #"\s*,\s*"# + literal + #"\s*\)"#), { $0.joined(separator: "|") }),
        ]
        var keys: [String: String] = [:]
        for file in try swiftFiles() where file.lastPathComponent != "L10n.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let ns = text as NSString
            for (regex, key) in patterns {
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let groups = (1..<match.numberOfRanges).map { unescape(ns.substring(with: match.range(at: $0))) }
                    keys[key(groups)] = file.lastPathComponent
                }
            }
        }
        return keys
    }

    /// The value of a single-line Swift string literal's text.
    static func unescape(_ raw: String) -> String {
        var out = ""
        var chars = raw.makeIterator()
        while let c = chars.next() {
            guard c == "\\", let d = chars.next() else { out.append(c); continue }
            switch d {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "u":
                _ = chars.next()  // {
                var hex = ""
                while let h = chars.next(), h != "}" { hex.append(h) }
                if let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) { out.unicodeScalars.append(scalar) }
            default: out.append(d)
            }
        }
        return out
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    // MARK: No Russian UI text outside the layer

    /// Files that draw previews, films, the promo video (its captions and fake sessions come in both languages) and the
    /// design sheet (developer tools, Russian on purpose), and the layer.
    static let developerFiles = try! NSRegularExpression(
        pattern: #"Preview|/Sheet/|/Preview/|/Promo/|StageFilm|IslandPerf|LiveCheck|MascotPreviewRenderer|/L10n\.swift$"#)

    func testNoRussianTextOutsideTheLocalizationLayer() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles() {
            let path = file.path
            if Self.developerFiles.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil {
                continue
            }
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in SwiftLiteralScanner(source).literals() where literal.isRussian && !literal.isLocalized {
                offenders.append("\(file.lastPathComponent):\(literal.line): \(literal.text)")
            }
        }
        XCTAssertEqual(offenders, [], "Russian text must go through L(…) (or be marked // l10n-ignore)")
    }

    func testScannerFindsRussianOutsideTheLayer() {
        let sample = """
        let a = Text("Привет")
        let b = L("Привет")
        let c = L("%@ из %@", n, total) // "не строка в комментарии"
        /* "и не эта" */
        let d = "\\(x ? "вложенная" : L("обёрнутая")) · ok"
        let e = plural(n, "файл", "файла", "файлов")
        let f = Lc("meeting", "идёт")
        let g = "маркер"  // l10n-ignore
        let h = "ждёт|ждут|ждут"
        let i = #"сырая "строка""#
        """
        let flagged = SwiftLiteralScanner(sample).literals().filter { $0.isRussian && !$0.isLocalized }.map(\.text)
        XCTAssertEqual(flagged, ["Привет", "вложенная", #"сырая "строка""#])
    }

    // MARK: Runtime

    func testLookupFollowsTheLanguageLive() {
        L10n.shared.override(.ru)
        XCTAssertEqual(L("Готово"), "Готово")
        let changed = Flag()
        withObservationTracking { _ = L("Готово") } onChange: { changed.value = true }
        L10n.shared.override(.en)
        XCTAssertTrue(changed.value, "a view that showed a localized string must be invalidated")
        XCTAssertEqual(L("Готово"), "Done")
        XCTAssertEqual(L("ждёт %@", "0:20"), "waiting 0:20")
        XCTAssertEqual(Lc("meeting", "идёт"), "now")
        L10n.shared.override(.ru)
        XCTAssertEqual(Lc("meeting", "идёт"), "идёт")
    }

    func testUnknownKeysShowThemselves() {
        L10n.shared.override(.en)
        XCTAssertEqual(L("какой-то текст агента"), "какой-то текст агента")
        XCTAssertEqual(L("осталось %@ из %@", 1, 2), "осталось 1 из 2")
        XCTAssertEqual(Lc("nowhere", "текст"), "текст")
    }

    func testFormatting() {
        XCTAssertEqual(L10n.format("%@ из %@", ["1", "3"]), "1 из 3")
        XCTAssertEqual(L10n.format("%2$@ of %1$@", ["3", "1"]), "1 of 3")
        XCTAssertEqual(L10n.format("%@%% · %@", ["46", "35м"]), "46% · 35м")
        XCTAssertEqual(L10n.format("no args %@ %@", ["x"]), "no args x ")
        XCTAssertEqual(L10n.format("100% ready", []), "100% ready")
        XCTAssertEqual(L10n.format("trailing %", ["x"]), "trailing %")
    }

    func testPlurals() {
        L10n.shared.override(.ru)
        XCTAssertEqual([1, 2, 5, 11, 21, 22, 112].map { Lp($0, "файл", "файла", "файлов") },
                       ["файл", "файла", "файлов", "файлов", "файл", "файла", "файлов"])
        XCTAssertEqual(ShelfFormat.files(3), "3 файла")
        L10n.shared.override(.en)
        XCTAssertEqual([1, 2, 5, 21].map { Lp($0, "файл|файла|файлов") }, ["file", "files", "files", "files"])
        XCTAssertEqual(ShelfFormat.files(1), "1 file")
        XCTAssertEqual(ShelfFormat.files(3), "3 files")
    }

    func testDecimalSeparatorFollowsTheLanguage() {
        L10n.shared.override(.ru)
        XCTAssertEqual(L10n.decimal(1.5), "1,5")
        XCTAssertEqual(ShelfFormat.size(8_400), "8,4 КБ")
        L10n.shared.override(.en)
        XCTAssertEqual(L10n.decimal(1.5), "1.5")
        XCTAssertEqual(ShelfFormat.size(8_400), "8.4 KB")
        XCTAssertEqual(ShelfFormat.size(2_000), "2 KB")
    }

    func testAutoFollowsMacOSLanguages() {
        XCTAssertEqual(L10n.autoLanguage(preferred: ["ru-US", "en-US"]), .ru)
        XCTAssertEqual(L10n.autoLanguage(preferred: ["en-GB", "ru"]), .en)
        XCTAssertEqual(L10n.autoLanguage(preferred: ["uk-UA", "ru-RU"]), .ru)
        XCTAssertEqual(L10n.autoLanguage(preferred: ["de-DE", "fr"]), .en)
        XCTAssertEqual(L10n.autoLanguage(preferred: []), .en)
    }

    func testLanguageSettingRoundTrips() {
        let defaults = UserDefaults(suiteName: "notchbuddy.l10n.tests.\(UUID().uuidString)")!
        var settings = NotchSettings()
        XCTAssertEqual(settings.language, .auto)
        settings.language = .en
        settings.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: L10n.settingsKey), "en")
        XCTAssertEqual(NotchSettings.load(from: defaults).language, .en)
        XCTAssertEqual(AppLanguage.en.label, "English")
        XCTAssertEqual(AppLanguage.ru.label, "Русский")
    }

    func testSettingsLabelsAreTranslated() {
        L10n.shared.override(.en)
        XCTAssertEqual(IslandStyle.island.label, "Island")
        XCTAssertEqual(IslandStyle.notch.label, "Notch")
        XCTAssertEqual(WidgetKind.shelf.title, "Shelf")
        XCTAssertEqual(UsageRefreshInterval.fiveMinutes.label, "5 min")
        XCTAssertEqual(HoverOpenDelay.quick.label, "0.1 s")
        L10n.shared.override(.ru)
        XCTAssertEqual(IslandStyle.island.label, "Островок")
        XCTAssertEqual(HoverOpenDelay.quick.label, "0,1 с")
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}

// MARK: - A small Swift lexer: string literals outside comments

/// Finds every string literal (with its interpolations) outside comments, and says whether one is Russian text and
/// whether it goes through the localization layer: the first argument of `L`/`LKey`/`Lp`, the key of `Lc`, a form of
/// a plural helper, a "one|few|many" forms literal, or a line marked `// l10n-ignore` (or inside
/// `// l10n-ignore-begin` … `// l10n-ignore-end`).
struct SwiftLiteralScanner {
    struct Literal {
        let text: String
        let line: Int
        let isRussian: Bool
        let isLocalized: Bool
    }

    private let bytes: [UInt8]
    private let source: String
    private var ignoredLines: Set<Int> = []

    init(_ source: String) {
        self.source = source
        bytes = Array(source.utf8)
        var inside = false
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.contains("l10n-ignore-begin") { inside = true }
            if inside || line.contains("// l10n-ignore") { ignoredLines.insert(index + 1) }
            if line.contains("l10n-ignore-end") { inside = false }
        }
    }

    func literals() -> [Literal] {
        var found: [(start: Int, end: Int, text: String)] = []
        _ = scanCode(0, stopAtParen: false, into: &found)
        var lineStarts = [0]
        for (index, byte) in bytes.enumerated() where byte == 10 { lineStarts.append(index + 1) }
        return found.map { item in
            // Binary search: the number of line starts at or before the literal.
            var low = 0, high = lineStarts.count
            while low < high {
                let mid = (low + high) / 2
                if lineStarts[mid] <= item.start { low = mid + 1 } else { high = mid }
            }
            let line = low
            let russian = item.text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            return Literal(text: item.text, line: line, isRussian: russian,
                           isLocalized: ignoredLines.contains(line) || localized(start: item.start, text: item.text))
        }
    }

    private static let localizedContexts: [NSRegularExpression] = [
        #"(?<![A-Za-z0-9_.])(?:L|LKey|Lp)\(\s*$"#,
        #"(?<![A-Za-z0-9_.])Lc\(\s*"[^"]*"\s*,\s*$"#,
        #"\b(?:plural|pick|count|Lp)\([^()"]*(?:\([^()]*\))?[^()"]*,\s*$"#,
        #"\b(?:plural|pick|count|Lp)\(.*",\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private func localized(start: Int, text: String) -> Bool {
        if text.components(separatedBy: "|").count == 3 { return true }  // "ждёт|ждут|ждут": a plural key
        var lineStart = start
        while lineStart > 0, bytes[lineStart - 1] != 10 { lineStart -= 1 }
        let prefix = String(decoding: bytes[lineStart..<start], as: UTF8.self)
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        return Self.localizedContexts.contains { $0.firstMatch(in: prefix, range: range) != nil }
    }

    private func starts(_ string: String, at i: Int) -> Bool {
        var j = i
        for byte in string.utf8 {
            guard j < bytes.count, bytes[j] == byte else { return false }
            j += 1
        }
        return true
    }

    /// Code from `i`; with `stopAtParen`, up to the `)` that closes an interpolation (returns its index).
    private func scanCode(_ start: Int, stopAtParen: Bool, into found: inout [(start: Int, end: Int, text: String)]) -> Int {
        var i = start
        var depth = 0
        while i < bytes.count {
            let c = bytes[i]
            if starts("//", at: i) {
                while i < bytes.count, bytes[i] != 10 { i += 1 }
                continue
            }
            if starts("/*", at: i) {
                var nesting = 0
                while i < bytes.count {
                    if starts("/*", at: i) { nesting += 1; i += 2 }
                    else if starts("*/", at: i) { nesting -= 1; i += 2; if nesting == 0 { break } }
                    else { i += 1 }
                }
                continue
            }
            if c == UInt8(ascii: "\"") || (c == UInt8(ascii: "#") && isRawStringStart(i)) {
                i = scanString(i, into: &found)
                continue
            }
            if stopAtParen {
                if c == UInt8(ascii: "(") { depth += 1 }
                if c == UInt8(ascii: ")") {
                    if depth == 0 { return i }
                    depth -= 1
                }
            }
            i += 1
        }
        return i
    }

    private func isRawStringStart(_ i: Int) -> Bool {
        var j = i
        while j < bytes.count, bytes[j] == UInt8(ascii: "#") { j += 1 }
        return j < bytes.count && bytes[j] == UInt8(ascii: "\"")
    }

    private func scanString(_ start: Int, into found: inout [(start: Int, end: Int, text: String)]) -> Int {
        var i = start
        var hashes = 0
        while bytes[i] == UInt8(ascii: "#") { hashes += 1; i += 1 }
        var multiline = false
        if starts("\"\"\"", at: i) {
            var j = i + 3
            while j < bytes.count, bytes[j] == 32 || bytes[j] == 9 { j += 1 }
            multiline = j < bytes.count && bytes[j] == 10
        }
        let quote = multiline ? "\"\"\"" : "\""
        i += quote.count
        let close = quote + String(repeating: "#", count: hashes)
        let escape = "\\" + String(repeating: "#", count: hashes)
        var text: [UInt8] = []
        while i < bytes.count {
            if starts(close, at: i) { i += close.count; break }
            if starts(escape, at: i) {
                let j = i + escape.count
                if j < bytes.count, bytes[j] == UInt8(ascii: "(") {
                    let end = scanCode(j + 1, stopAtParen: true, into: &found)
                    text += Array("\\(…)".utf8)
                    i = end + 1
                    continue
                }
                text += bytes[i...min(j, bytes.count - 1)]
                i = j + 1
                continue
            }
            text.append(bytes[i])
            i += 1
        }
        found.append((start, i, String(decoding: text, as: UTF8.self)))
        return i
    }
}
