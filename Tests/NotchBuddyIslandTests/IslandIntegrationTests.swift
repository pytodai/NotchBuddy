import QuartzCore
import SwiftUI
import XCTest
import NotchBuddyCore
@testable import NotchBuddy

/// Cross-cutting checks of the island: sizes, icons, copy, effects' look.
@MainActor
final class IslandIntegrationTests: XCTestCase {
    private let floating = IslandMetrics(style: .floating, notchWidth: 0, barHeight: 34, menuBarHeight: 24)
    private let notched = IslandMetrics(style: .notch, notchWidth: 188, barHeight: 37, menuBarHeight: 37)

    override func tearDown() {
        IslandLayout.widthScale = 1
        super.tearDown()
    }

    /// Settings → Размер changes only the open island's widths: the panel's canvas (the fixed canvas) stays.
    func testSizeScaleMorphsWidthsButNeverTheCanvas() {
        for metrics in [floating, notched] {
            IslandLayout.widthScale = 1
            let canvas = IslandLayout.canvasSize(metrics)
            let normal = IslandLayout.listWidth(metrics)
            var widths: [CGFloat] = []
            for size in IslandSize.allCases {
                IslandLayout.widthScale = CGFloat(size.scale)
                XCTAssertEqual(IslandLayout.canvasSize(metrics), canvas, "\(size) resized the canvas")
                let list = IslandLayout.listWidth(metrics)
                widths.append(list)
                // The largest island still fits the canvas with its ears and shadow room.
                XCTAssertLessThanOrEqual(list + 2 * IslandLayout.openEar + 2 * IslandLayout.shadowMargin, canvas.width + 0.5)
                XCTAssertLessThanOrEqual(IslandLayout.cardWidth(metrics) + 2 * IslandLayout.openEar, canvas.width)
            }
            XCTAssertEqual(widths, widths.sorted(), "sizes grow in order")
            IslandLayout.widthScale = 1
            XCTAssertEqual(IslandLayout.listWidth(metrics), normal)
        }
    }

    /// Beside a notch the list's wings stay wide enough for the header (title + three buttons) at every size.
    func testNotchWingsHoldTheHeader() {
        for size in IslandSize.allCases {
            IslandLayout.widthScale = CGFloat(size.scale)
            let wing = (IslandLayout.listWidth(notched) - notched.notchWidth) / 2
            // Three 26 pt buttons, their spacing and the paddings.
            XCTAssertGreaterThanOrEqual(wing, 3 * 26 + 2 * 6 + 12 + 10, "\(size)")
        }
    }

    /// Every tool the cards and the card name draws from the icon set, never a stray SF Symbol.
    func testToolsDrawFromTheIconSet() {
        let tools = ["Bash", "exec_command", "Edit", "Write", "apply_patch", "Read", "view_image", "Grep", "WebFetch",
                     "WebSearch", "Task", "ExitPlanMode", "TodoWrite", "AskUserQuestion", "request_permissions",
                     "mcp__github__create_issue", "Skill", "sleep", "CronCreate", "CreateGoal", "KillShell", "something_new"]
        for tool in tools {
            XCTAssertNotNil(NBIcon.replacing(symbol: SessionStrings.toolSymbol(tool)), "\(tool) → \(SessionStrings.toolSymbol(tool))")
            XCTAssertNotNil(NBIcon.replacing(symbol: ToolStyle.symbol(for: tool)), "\(tool) (card)")
        }
        for symbol in ["bell.fill", "exclamationmark.triangle.fill", "sparkles", "moon.zzz.fill", "checkmark", "xmark",
                       "folder", "doc.on.doc", "arrow.up.right", "chevron.down", "clock", "timer", "hourglass"] {
            XCTAssertNotNil(NBIcon.replacing(symbol: symbol), symbol)
        }
    }

    /// Statuses and tool names come from the copy catalog (no raw ids, "Свободен" for idle).
    func testCopyCatalog() {
        XCTAssertEqual(SessionStatus.idle.label, "Свободен")
        XCTAssertEqual(SessionStatus.waitingForUser.shortLabel, "ждёт тебя")
        XCTAssertEqual(ToolStyle.displayName("exec_command"), "Терминал")
        XCTAssertEqual(ToolStyle.displayName("mcp__github__create_issue"), "MCP · github")
    }

    /// The island's celebration is the calm one: no aura, a whisper of glow, no gold confetti.
    func testCalmCelebrationLook() {
        for style in [DoneCelebrationStyle.calm, .calmEncore] {
            XCTAssertEqual(style.aura, 0)
            XCTAssertLessThanOrEqual(style.glow, 0.35)
            XCTAssertLessThanOrEqual(style.wash, 0.35)
            XCTAssertFalse(style.warmSparks)
        }
        XCTAssertTrue(DoneCelebrationStyle.calm.comets)
        XCTAssertFalse(DoneCelebrationStyle.calmEncore.comets)
    }

    /// The settings page is registered on the stage under its id, a readable column narrower than the wide list; the
    /// list takes a share of the screen (~38 %), clamped.
    func testSettingsPageIsRegistered() {
        IslandSettings.register()
        let spec = IslandPages.spec(IslandSettings.pageID)
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.width(floating), IslandLayout.settingsWidth(floating))
        XCTAssertLessThan(IslandLayout.settingsWidth(floating), IslandLayout.listWidth(floating))
        var wide = floating
        wide.screenWidth = 1920
        XCTAssertEqual(IslandLayout.baseListWidth(wide), 730)
        wide.screenWidth = 3840
        XCTAssertEqual(IslandLayout.baseListWidth(wide), IslandLayout.maxListWidth)
        wide.screenWidth = 1280
        XCTAssertEqual(IslandLayout.baseListWidth(wide), IslandLayout.minListWidth)
        XCTAssertGreaterThanOrEqual(IslandLayout.canvasSize(wide).width,
                                    IslandLayout.listWidth(wide) * IslandLayout.maxWidthScale + 2 * IslandLayout.openEar)
    }

    /// Hover delay presets map to the controller's dwell (nil: click only).
    func testHoverOpenPresets() {
        XCTAssertEqual(HoverOpenDelay.quick.restDwell, IslandMotion.restDwell)
        XCTAssertEqual(HoverOpenDelay.quick.maxDwell, IslandMotion.maxDwell)
        XCTAssertNil(HoverOpenDelay.never.restDwell)
        XCTAssertNil(HoverOpenDelay.never.maxDwell)
    }
}
