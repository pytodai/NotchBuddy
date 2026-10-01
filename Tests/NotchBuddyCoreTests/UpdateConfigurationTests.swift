import Foundation
import XCTest
@testable import NotchBuddyCore

/// Self-update configuration: Sparkle's Info.plist keys as the app reads them, the key check that decides whether the
/// updater starts, the shipped Info.plist and the appcast at the repository root.
final class UpdateConfigurationTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// 32 bytes, base64: the shape of a real Ed25519 public key.
    static let sampleKey = Data((0..<32).map { UInt8($0 * 7 % 256) }).base64EncodedString()

    private func config(_ extra: [String: Any] = [:]) -> UpdateConfiguration {
        var info: [String: Any] = [
            "CFBundleShortVersionString": "1.2", "CFBundleVersion": "7",
            "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": Self.sampleKey,
        ]
        info.merge(extra) { $1 }
        return UpdateConfiguration(infoDictionary: info)
    }

    func testReadsSparkleKeys() {
        let c = config(["SUEnableAutomaticChecks": true, "SUScheduledCheckInterval": 3600, "SUAllowsAutomaticUpdates": false])
        XCTAssertEqual(c.version, "1.2")
        XCTAssertEqual(c.build, "7")
        XCTAssertEqual(c.feedURL, URL(string: "https://example.com/appcast.xml"))
        XCTAssertTrue(c.checksAutomatically)
        XCTAssertEqual(c.checkInterval, 3600)
        XCTAssertFalse(c.allowsAutomaticUpdates)
        XCTAssertTrue(c.canUpdate)
        XCTAssertNil(c.problem)
    }

    func testDefaultsAndLooseTypes() {
        let bare = UpdateConfiguration(infoDictionary: [:])
        XCTAssertNil(bare.version)
        XCTAssertFalse(bare.checksAutomatically)
        XCTAssertEqual(bare.checkInterval, 86_400)
        XCTAssertTrue(bare.allowsAutomaticUpdates)
        XCTAssertFalse(bare.canUpdate)
        XCTAssertEqual(bare.problem, "no SUFeedURL")

        let strings = config(["SUEnableAutomaticChecks": "YES", "SUScheduledCheckInterval": "600",
                              "SUAllowsAutomaticUpdates": NSNumber(value: false)])
        XCTAssertTrue(strings.checksAutomatically)
        XCTAssertEqual(strings.checkInterval, 600)
        XCTAssertFalse(strings.allowsAutomaticUpdates)
    }

    /// Sparkle refuses to start with a key that is not base64 Ed25519; the app must not even try.
    func testOnlyARealKeyStartsTheUpdater() {
        let placeholder = config(["SUPublicEDKey": UpdateConfiguration.placeholderKey])
        XCTAssertFalse(placeholder.hasValidPublicKey)
        XCTAssertFalse(placeholder.canUpdate)
        XCTAssertEqual(placeholder.problem, "no signing key in this build")

        XCTAssertEqual(config(["SUPublicEDKey": ""]).problem, "no signing key in this build")
        let short = config(["SUPublicEDKey": Data(count: 31).base64EncodedString()])
        XCTAssertFalse(short.canUpdate)
        XCTAssertEqual(short.problem, "SUPublicEDKey is not an Ed25519 key")
        XCTAssertTrue(config(["SUPublicEDKey": " \(Self.sampleKey)\n"]).hasValidPublicKey)

        let http = config(["SUFeedURL": "http://example.com/appcast.xml"])
        XCTAssertFalse(http.canUpdate)
        XCTAssertEqual(http.problem, "the feed is not https")
    }

    func testReleaseLinks() {
        XCTAssertEqual(UpdateConfiguration.releasesPage.absoluteString, "https://github.com/pytodai/NotchBuddy/releases")
        XCTAssertEqual(UpdateConfiguration.releasePage(version: "1.1").absoluteString,
                       "https://github.com/pytodai/NotchBuddy/releases/tag/v1.1")
    }

    // MARK: The shipped files

    func testShippedInfoPlist() throws {
        let url = Self.repo.appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        let c = UpdateConfiguration(infoDictionary: info)
        XCTAssertEqual(c.feedURL?.absoluteString, "https://raw.githubusercontent.com/pytodai/NotchBuddy/main/appcast.xml")
        XCTAssertTrue(c.checksAutomatically)
        XCTAssertEqual(c.checkInterval, 86_400)
        XCTAssertTrue(c.allowsAutomaticUpdates)
        XCTAssertNotNil(c.version)
        XCTAssertNotNil(Int(c.build ?? ""), "CFBundleVersion is Sparkle's version: a whole number")
        // The placeholder until a release build fills in the real key; never anything else.
        XCTAssertTrue(c.publicEDKey == UpdateConfiguration.placeholderKey || c.hasValidPublicKey,
                      "SUPublicEDKey: \(c.publicEDKey ?? "missing")")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "14.0")
        // Sparkle's windows follow the bundle's localizations and fall back to this one, like the app's own text.
        XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "en")
    }

    /// The hardened runtime blocks Apple Events and calendar access unless the signature carries these two
    /// entitlements; nothing else belongs there.
    func testEntitlements() throws {
        let url = Self.repo.appendingPathComponent("Resources/NotchBuddy.entitlements")
        let entitlements = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(Set(entitlements.keys), ["com.apple.security.automation.apple-events",
                                                "com.apple.security.personal-information.calendars"])
        XCTAssertTrue(entitlements.values.allSatisfy { ($0 as? Bool) == true })
    }

    /// The feed the app reads: well-formed, newest item first, every item pointing at a signed release zip.
    func testAppcastAtTheRepositoryRoot() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("appcast.xml"))
        let reader = AppcastReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        XCTAssertTrue(parser.parse(), "appcast.xml: \(parser.parserError.map(String.init(describing:)) ?? "")")
        XCTAssertTrue(reader.sawChannel)
        var previous = Int.max
        for item in reader.items {
            let build = try XCTUnwrap(Int(item["sparkle:version"] ?? ""), "sparkle:version is the build number")
            XCTAssertLessThan(build, previous, "newest item first, one item per build")
            previous = build
            let version = try XCTUnwrap(item["sparkle:shortVersionString"])
            XCTAssertEqual(item["sparkle:minimumSystemVersion"], "14.0")
            XCTAssertEqual(item["url"],
                           "https://github.com/pytodai/NotchBuddy/releases/download/v\(version)/Notchbuddy-\(version).zip")
            XCTAssertNotNil(Int(item["length"] ?? ""))
            XCTAssertEqual(Data(base64Encoded: item["sparkle:edSignature"] ?? "")?.count, 64, "an Ed25519 signature")
            // The notes are in the feed (no web page in the update window); the release page is the full changelog.
            XCTAssertNil(item["sparkle:releaseNotesLink"])
            XCTAssertEqual(item["description.format"], "markdown")
            XCTAssertFalse((item["description"] ?? "").isEmpty, "release notes")
            XCTAssertEqual(item["sparkle:fullReleaseNotesLink"],
                           UpdateConfiguration.releasePage(version: version).absoluteString)
        }
    }

    /// The reader above, on a feed in the shape scripts/appcast.sh writes.
    func testAppcastReaderOnASample() throws {
        let sample = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <title>Notchbuddy</title>
            <description>Notchbuddy updates</description>
            <item>
              <title>Version 1.1</title>
              <sparkle:version>2</sparkle:version>
              <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
              <description sparkle:format="markdown"><![CDATA[## What's Changed

        * Faster <island> & calmer]]></description>
              <sparkle:fullReleaseNotesLink>https://github.com/pytodai/NotchBuddy/releases/tag/v1.1</sparkle:fullReleaseNotesLink>
              <enclosure url="https://example.com/a.zip" length="10" type="application/octet-stream" sparkle:edSignature="c2ln" />
            </item>
          </channel>
        </rss>
        """
        let reader = AppcastReader()
        let parser = XMLParser(data: Data(sample.utf8))
        parser.delegate = reader
        XCTAssertTrue(parser.parse())
        let item = try XCTUnwrap(reader.items.first)
        XCTAssertEqual(item["description.format"], "markdown")
        XCTAssertEqual(item["description"], "## What's Changed\n\n* Faster <island> & calmer")
        XCTAssertEqual(item["sparkle:fullReleaseNotesLink"], "https://github.com/pytodai/NotchBuddy/releases/tag/v1.1")
        XCTAssertEqual(item["sparkle:version"], "2")
    }
}

/// Collects each `<item>`'s Sparkle fields and its enclosure's attributes.
private final class AppcastReader: NSObject, XMLParserDelegate {
    var sawChannel = false
    var items: [[String: String]] = []
    private var current: [String: String]?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "channel": sawChannel = true
        case "item": current = [:]
        case "enclosure": current?.merge(attributes) { $1 }
        case "description": current?["description.format"] = attributes["sparkle:format"]
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item", let item = current {
            items.append(item)
            current = nil
        } else if name.hasPrefix("sparkle:") || name == "description" {
            current?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
