import AppKit

// A bridge that disconnects mid-reply must not kill the app with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

// `NotchBuddy --perf-send <action>`: drives a running `NOTCHBUDDY_PERF=1` instance (debug benchmark) and exits.
if IslandPerfTrigger.sendIfRequested(CommandLine.arguments) { exit(0) }

// Manrope (Resources/Fonts) for the whole process, before any view is built.
NBTypography.registerBundledFonts()

// Every `--render-…` mode draws the agents' and players' own badges, not the app icons installed on this Mac.
if CommandLine.arguments.contains(where: { $0.hasPrefix("--render-") }) {
    MainActor.assumeIsolated {
        AgentAppIcon.useInstalledIcons = false
        MusicPlayerIcon.useInstalledIcons = false
    }
}

// `NotchBuddy --render-design <dir>`: the design system sheet + lint (Design/Sheet), then exit.
if let directory = NBDesignSheet.requestedDirectory(CommandLine.arguments) { exit(NBDesignSheet.runFromMain(directory)) }

// `NotchBuddy --render-perf <dir>`: films the Core Animation stage to PNGs and exits.
if let directory = IslandStageFilm.requestedDirectory(CommandLine.arguments) {
    exit(MainActor.assumeIsolated { _ = NSApplication.shared; return IslandStageFilm.run(outputDirectory: directory) })
}

if let status = ShelfPreviewRenderer.runIfRequested(CommandLine.arguments) { exit(status) }  // --render-shelf <dir>

// `NotchBuddy --render-previews <dir>`: draw the island's states to PNGs and exit (nothing else starts).
if let directory = IslandPreviewRenderer.requestedDirectory(CommandLine.arguments) {
    let status = MainActor.assumeIsolated {
        _ = NSApplication.shared
        return IslandPreviewRenderer.run(outputDirectory: directory)
    }
    exit(status)
}

// `NotchBuddy --render-effects <dir>`: filmstrips of the effects library (Effects/Preview) to PNGs, then exit.
if let dir = EffectsPreviewRenderer.requestedDirectory(CommandLine.arguments) { exit(MainActor.assumeIsolated { _ = NSApplication.shared; return EffectsPreviewRenderer.run(outputDirectory: dir) }) }

// `NotchBuddy --render-settings <dir>`: the settings page to PNGs, then exit.
if let directory = SettingsPreviewRenderer.requestedDirectory(CommandLine.arguments) {
    exit(MainActor.assumeIsolated { _ = NSApplication.shared; return SettingsPreviewRenderer.run(outputDirectory: directory) })
}

// `NotchBuddy --render-sessions <dir>`: session cards (collapsed, expanded, motion) to PNGs, then exit.
if let dir = SessionsPreviewRenderer.requestedDirectory(CommandLine.arguments) { exit(MainActor.assumeIsolated { _ = NSApplication.shared; return SessionsPreviewRenderer.run(outputDirectory: dir) }) }

// `NotchBuddy --render-usage <dir>`: the multi-agent usage footer with fake data, to PNGs.
if let dir = AgentUsagePreviewRenderer.requestedDirectory(CommandLine.arguments) { exit(MainActor.assumeIsolated { _ = NSApplication.shared; return AgentUsagePreviewRenderer.run(outputDirectory: dir) }) }

// `NotchBuddy --render-music <dir>`: the music widget's states and motion as PNGs, then exit.
if let directory = MusicPreviewRenderer.requestedDirectory(CommandLine.arguments) { exit(MainActor.assumeIsolated { _ = NSApplication.shared; return MusicPreviewRenderer.run(outputDirectory: directory) }) }

// `NotchBuddy --render-calendar <dir>`: the calendar widget's states to PNGs, then exit.
if let dir = CalendarPreviewRenderer.requestedDirectory(CommandLine.arguments) { exit(MainActor.assumeIsolated { _ = NSApplication.shared; return CalendarPreviewRenderer.run(outputDirectory: dir) }) }

// `NotchBuddy --render-timer-system <dir>`: the timer and system widgets' states to PNGs, then exit.
if let dir = TimerSystemPreviewRenderer.requestedDirectory(CommandLine.arguments) { exit(MainActor.assumeIsolated { _ = NSApplication.shared; return TimerSystemPreviewRenderer.run(outputDirectory: dir) }) }

// `NotchBuddy --render-widgets <dir>`: the widgets on the real stage (tabs, live activities, tab switches), then exit.
if let dir = WidgetsPreviewRenderer.requestedDirectory(CommandLine.arguments) { exit(MainActor.assumeIsolated { _ = NSApplication.shared; return WidgetsPreviewRenderer.run(outputDirectory: dir) }) }

// `NotchBuddy --render-mascots <dir>`: sprite sheets, GIFs and a real-size island preview of the pixel mascots.
if let directory = MascotPreviewRenderer.requestedDirectory(CommandLine.arguments) {
    exit(MainActor.assumeIsolated { _ = NSApplication.shared; return MascotPreviewRenderer.run(outputDirectory: directory) })
}

// `NotchBuddy --render-promo <dir> [--size WxH] [--fps N] [--lang en|ru]`: the promo video as PNG frames (Promo/), then exit.
if let options = PromoRenderer.options(CommandLine.arguments) { exit(MainActor.assumeIsolated { _ = NSApplication.shared; return PromoRenderer.run(options) }) }

// Top-level code runs on the main thread; the delegate is main-actor isolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `run()` never returns (terminate exits), so `delegate` (held weakly by NSApp) stays alive.
    withExtendedLifetime(delegate) { app.run() }
}
