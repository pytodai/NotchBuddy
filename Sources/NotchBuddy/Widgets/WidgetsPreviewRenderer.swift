import AppKit
import NotchBuddyCore
import SwiftUI

/// `NotchBuddy --render-widgets <dir>`: the widgets ("островки") on the real Core Animation stage, filmed like
/// `--render-perf` (virtual clock, every baked track drawn at its moment), with sample data for every widget:
///
/// - `widgets-tabs-{floating,notch}.png`: every tab of the open island, settled (the strip, its pill, the page);
/// - `widgets-closed-{floating,notch}.png`: the closed island's live activities (agents, music, calendar, timer,
///   low battery, shelf);
/// - `film-switch-*.png`, `film-open-*.png`: tab switches in both directions and opening on a live activity's tab,
///   with the stage's continuity check (the silhouette never jumps between two 1/120 s samples).
///
/// Nothing else starts: no player, calendar or drag detector is touched.
@MainActor
enum WidgetsPreviewRenderer {
    nonisolated static let flag = "--render-widgets"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/widget-previews"
    }

    static let tabs: [WidgetKind] = [.agents, .music, .calendar, .timer, .system, .shelf]

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchbuddy-widget-previews-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }
        NSApp.setActivationPolicy(.accessory)
        let shelf = ShelfPreviewRenderer.sampleShelf(in: scratch)
        let music = MusicPreviewRenderer.sampleModel()
        let calendar = CalendarPreviewRenderer.sampleService()
        let timer = TimerSystemPreviewRenderer.sampleTimerStore()
        let system = TimerSystemPreviewRenderer.sampleSystemMonitor()
        let lowBattery = TimerSystemPreviewRenderer.sampleSystemMonitor(low: true)
        func hub(system override: SystemMonitor? = nil) -> WidgetHub {
            .preview(tabs: tabs, music: music, calendar: calendar, timer: timer, system: override ?? system, shelf: shelf)
        }
        WidgetHub.shared = hub()
        IslandWidgetPages.register()
        IslandSettings.register()

        var failures = 0
        func save(_ image: CGImage?, _ name: String) {
            failures += IslandStageFilm.write(image, to: directory.appendingPathComponent("\(name).png")) ? 0 : 1
        }
        func report(_ name: String, _ problems: [String]) {
            for problem in problems { FileHandle.standardError.write(Data("\(name): \(problem)\n".utf8)) }
            failures += problems.count
        }
        let only = ProcessInfo.processInfo.environment["NOTCHBUDDY_WIDGET_FILMS"].map { Set($0.split(separator: ",").map(String.init)) }
        func wanted(_ name: String) -> Bool { only == nil || only!.contains(name) }

        for (suffix, metrics) in [("floating", IslandPreviewRenderer.floating), ("notch", IslandPreviewRenderer.notched)] {
            let set = FilmSet(metrics: metrics)

            // Every tab, settled.
            if wanted("tabs") {
                var stills: [CGImage] = []
                for kind in tabs {
                    let film = StageFilm(name: "tab-\(kind.rawValue)", title: kind.title, times: [0],
                                         setup: { s, f in
                                             s.tabs = tabs
                                             // Settled values (gauges, rings): the stills skip SwiftUI's own sweeps.
                                             s.reduceMotion = true
                                             s.setContent(.tab(kind), snapshot: snapshot(f))
                                         },
                                         change: { _, _, _ in }, captureHeight: 560)
                    let (image, problems) = set.shoot(film)
                    report("tab-\(kind.rawValue)-\(suffix)", problems)
                    if let image { stills.append(image) }
                }
                save(IslandPreviewRenderer.stitch(stills, columns: 2, header: header("Островки: вкладки открытого острова")),
                     "widgets-tabs-\(suffix)")
            }

            // The closed island's live activities.
            if wanted("closed") {
                var stills: [CGImage] = []
                let activities: [(IslandActivityKind, String)] = [
                    (.agents, "Агенты: сессия ждёт"), (.timer, "Таймер"), (.calendar, "Встреча через 7 мин"),
                    (.music, "Музыка"), (.system, "Низкий заряд"), (.shelf, "Полка"),
                ]
                for (activity, title) in activities {
                    WidgetHub.shared = hub(system: activity == .system ? lowBattery : nil)
                    let film = StageFilm(name: "closed-\(activity.rawValue)", title: title, times: [0],
                                         setup: { s, f in
                                             s.tabs = tabs
                                             var snap = snapshot(f)
                                             if activity == .agents { snap.sessions = f.waiting }
                                             snap.activity = activity
                                             s.setContent(.collapsed, snapshot: snap)
                                         },
                                         change: { _, _, _ in }, captureHeight: 84)
                    let (image, problems) = set.shoot(film)
                    report("closed-\(activity.rawValue)-\(suffix)", problems)
                    if let image { stills.append(image) }
                }
                WidgetHub.shared = hub()
                save(IslandPreviewRenderer.stitch(stills, columns: 2, header: header("Свёрнутый остров: живые активности")),
                     "widgets-closed-\(suffix)")
            }

            // Motion.
            let films: [StageFilm] = [
                StageFilm(name: "switch-forward", title: "Вкладка →: Агенты → Музыка (контент уезжает влево, пилюля скользит)",
                          setup: { s, f in
                              s.tabs = tabs
                              s.setContent(.expanded, snapshot: snapshot(f))
                          },
                          change: { s, f, _ in
                              s.setContent(.tab(.music), snapshot: snapshot(f), entrance: .slide(forward: true),
                                           exit: .slide(forward: true))
                          }, captureHeight: 470),
                StageFilm(name: "switch-back", title: "Вкладка ←: Календарь → Агенты (вправо, остров меняет размер)",
                          setup: { s, f in
                              s.tabs = tabs
                              s.setContent(.tab(.calendar), snapshot: snapshot(f))
                          },
                          change: { s, f, _ in
                              s.setContent(.expanded, snapshot: snapshot(f), entrance: .slide(forward: false),
                                           exit: .slide(forward: false))
                          }, captureHeight: 470),
                StageFilm(name: "switch-quick", title: "Два свайпа подряд: Таймер → Система → Полка (второй через 90 мс)",
                          setup: { s, f in
                              s.tabs = tabs
                              s.setContent(.tab(.timer), snapshot: snapshot(f))
                          },
                          change: { s, f, _ in
                              s.setContent(.tab(.system), snapshot: snapshot(f), entrance: .slide(forward: true),
                                           exit: .slide(forward: true))
                          },
                          later: [(0.09, { s, f, _ in
                              s.setContent(.tab(.shelf), snapshot: snapshot(f), entrance: .slide(forward: true),
                                           exit: .slide(forward: true))
                          })], captureHeight: 470),
                StageFilm(name: "open-activity", title: "Клик по живой активности: свёрнут (музыка) → вкладка «Музыка»",
                          setup: { s, f in
                              s.tabs = tabs
                              var snap = snapshot(f)
                              snap.activity = .music
                              s.setContent(.collapsed, snapshot: snap)
                              s.setHovering(true)
                          },
                          change: { s, f, _ in s.setContent(.tab(.music), snapshot: snapshot(f)) }, captureHeight: 330),
                StageFilm(name: "settings-from-tab", title: "⚙️ на вкладке: полоса вкладок уходит, настройки морфятся",
                          setup: { s, f in
                              s.tabs = tabs
                              s.setContent(.tab(.timer), snapshot: snapshot(f))
                          },
                          change: { s, f, _ in s.setContent(.page(IslandSettings.pageID), snapshot: snapshot(f)) },
                          captureHeight: 470),
            ]
            for film in films where wanted(film.name) {
                let (image, problems) = set.shoot(film)
                report("film-\(film.name)-\(suffix)", problems)
                save(image, "film-\(film.name)-\(suffix)")
            }
            set.close()
        }
        return failures == 0 ? 0 : 1
    }

    /// The films' sessions with every agent's usage (the footer shows three rows).
    private static func snapshot(_ f: StageFakes) -> IslandSnapshot {
        var s = f.trio
        let now = f.now
        s.agentUsages = [
            .claude(fiveHour: (42, now.addingTimeInterval(2 * 3600 + 600)), sevenDay: (18, now.addingTimeInterval(3 * 86400)),
                    fetchedAt: now),
            AgentUsage(agent: .codex, windows: [
                AgentUsageWindow(id: "5h", used: 23, resetsAt: now.addingTimeInterval(3 * 3600), minutes: 300),
                AgentUsageWindow(id: "7d", used: 14, resetsAt: now.addingTimeInterval(5 * 86400), minutes: 10080),
            ], plan: "Plus", fetchedAt: now),
            AgentUsage(agent: .kimi, windows: [
                AgentUsageWindow(id: "5h", used: 8, resetsAt: now.addingTimeInterval(4 * 3600), minutes: 300),
                AgentUsageWindow(id: "7d", used: 31, resetsAt: now.addingTimeInterval(2 * 86400), minutes: 10080),
            ], fetchedAt: now.addingTimeInterval(-20 * 60)),
        ]
        return s
    }

    private static func header(_ text: String) -> CGImage? {
        IslandPreviewRenderer.image(Text(verbatim: text).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.85)))
    }
}
