import AppKit
import NotchBuddyCore

/// Geometry of the island's home on one screen.
struct IslandMetrics: Equatable {
    enum Style: Equatable {
        /// Hugs the camera housing; the top strip of the island sits behind the notch.
        case notch
        /// Screen without a notch: a virtual notch flush with the top edge whose content is laid out as one
        /// block (there is no camera housing to leave room for).
        case floating
    }

    var style: Style
    /// Width of the physical notch (0 for `.floating`).
    var notchWidth: CGFloat
    /// Height of the closed island: the notch height, or a little taller than the menu bar strip.
    var barHeight: CGFloat
    /// Height of the menu bar strip (for previews and for aligning with it).
    var menuBarHeight: CGFloat
    /// «Островок»: how far below the screen's top edge the capsule floats (0: «Чёлка», flush with the edge).
    var gap: CGFloat = 0
    /// The screen's width: the open list takes a share of it (`IslandLayout.listWidth`).
    var screenWidth: CGFloat = 1512

    static let fallback = IslandMetrics(style: .floating, notchWidth: 0, barHeight: 34, menuBarHeight: 24)

    /// «Островок» (detached from the top edge).
    var detached: Bool { gap > 0 }

    /// The same screen in the other style changes only the silhouette (not the content's layout, nor the canvas):
    /// the shape morphs between them.
    func differsOnlyInGap(from other: IslandMetrics) -> Bool {
        var a = self
        a.gap = other.gap
        return a == other && gap != other.gap
    }

    /// Closed island on a screen without a notch: it hangs a little below the menu bar so it reads as an
    /// object of its own, never shorter than 34 pt.
    static func floatingBarHeight(menuBar: CGFloat) -> CGFloat {
        min(max(menuBar.rounded() + 6, 34), 44)
    }
}

/// Where the island lives right now.
struct IslandPlacement: Equatable {
    var displayID: CGDirectDisplayID
    /// Top-center point of the island in global Cocoa coordinates (bottom-left origin).
    var anchor: CGPoint
    var metrics: IslandMetrics
    /// The screen's frame (the island's hit area never reaches past it).
    var screenFrame: CGRect

    /// The island's home on `screen` in `style`. «Островок» on a notched screen floats below the camera housing and lays
    /// its content out as on a screen without a notch (there is no housing to leave room for).
    init(screen: NSScreen, style: IslandStyle = .notch) {
        displayID = screen.displayID
        let frame = screen.frame
        screenFrame = frame
        let notchHeight = screen.safeAreaInsets.top
        if style == .island {
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            let strip = menuBar > 0 ? menuBar : NSStatusBar.system.thickness
            anchor = CGPoint(x: frame.midX.rounded(), y: frame.maxY)
            if notchHeight > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                anchor.x = ((frame.minX + left.width + frame.maxX - right.width) / 2).rounded()
            }
            // The capsule is as tall as the virtual notch of a screen without one (a notch's strip is taller).
            metrics = IslandMetrics(style: .floating, notchWidth: 0,
                                    barHeight: IslandMetrics.floatingBarHeight(menuBar: min(strip, 28)),
                                    menuBarHeight: strip.rounded(),
                                    gap: (notchHeight > 0 ? notchHeight.rounded() : 0) + IslandLayout.islandGap,
                                    screenWidth: frame.width.rounded())
            return
        }
        if notchHeight > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The auxiliary areas are the menu bar parts beside the camera housing; only their widths are used
            // so the result does not depend on which coordinate space they are reported in.
            let notchMinX = frame.minX + left.width
            let notchMaxX = frame.maxX - right.width
            anchor = CGPoint(x: ((notchMinX + notchMaxX) / 2).rounded(), y: frame.maxY)
            let height = screen.safeAreaInsets.top.rounded()
            metrics = IslandMetrics(style: .notch, notchWidth: (notchMaxX - notchMinX).rounded(),
                                    barHeight: height, menuBarHeight: height, screenWidth: frame.width.rounded())
        } else {
            // No camera housing: a virtual notch hanging from the top edge, a little taller than the menu bar
            // strip (the strip's height when the menu bar auto-hides).
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            let strip = menuBar > 0 ? menuBar : NSStatusBar.system.thickness
            anchor = CGPoint(x: frame.midX.rounded(), y: frame.maxY)
            metrics = IslandMetrics(style: .floating, notchWidth: 0,
                                    barHeight: IslandMetrics.floatingBarHeight(menuBar: strip),
                                    menuBarHeight: strip.rounded(), screenWidth: frame.width.rounded())
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Finds the screen that holds the frontmost app's main window and reports changes.
///
/// App activation, screen and Space changes are observed at all times. A window dragged to another display
/// posts nothing, so while the island is on screen (`setPolling`) and more than one display is connected a
/// cheap poll looks every 2 s; with one display, or with the panel ordered out, nothing polls.
@MainActor
final class ScreenLocator {
    var onChange: ((IslandPlacement) -> Void)?
    private(set) var placement: IslandPlacement?
    /// Settings → Остров → Экран: a screen the island always uses while it is connected (nil: follow the frontmost
    /// window).
    var preferredScreen: () -> NSScreen? = { nil }
    /// Settings → Остров → Стиль: the look the island takes on a screen.
    var style: (NSScreen) -> IslandStyle = { _ in .notch }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pollTimer: Timer?
    private var pollingWanted = false

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(workspaceCenter, NSWorkspace.didActivateApplicationNotification)
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            // A display came or went: the poll is worth it only with more than one.
            self?.updatePoll()
        }
        observe(workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification)
        evaluate()
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        pollingWanted = false
        updatePoll()
    }

    /// The island is on screen (true) or ordered out (false).
    func setPolling(_ active: Bool) {
        guard active != pollingWanted else { return }
        pollingWanted = active
        updatePoll()
    }

    private func updatePoll() {
        let want = pollingWanted && NSScreen.screens.count > 1
        guard want != (pollTimer != nil) else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        guard want else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.evaluate() }
        }
        timer.tolerance = 0.5
        pollTimer = timer
    }

    /// Re-reads where the island belongs; reports a change through `onChange` unless `notify` is false.
    /// Returns the current placement.
    @discardableResult
    func evaluate(notify: Bool = true) -> IslandPlacement? {
        let screen = preferredScreen() ?? Self.frontmostWindowScreen() ?? currentScreenIfStillConnected() ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return placement }
        let next = IslandPlacement(screen: screen, style: style(screen))
        guard next != placement else { return placement }
        placement = next
        if notify { onChange?(next) }
        return next
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         before: (@MainActor () -> Void)? = nil) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                before?()
                _ = self?.evaluate()
            }
        }
        observers.append((center, token))
    }

    private func currentScreenIfStillConnected() -> NSScreen? {
        guard let id = placement?.displayID else { return nil }
        return NSScreen.screens.first { $0.displayID == id }
    }

    /// The screen containing the center of the frontmost app's frontmost normal window.
    /// Returns nil with a single display, when NotchBuddy itself is frontmost or the app has no on-screen window.
    static func frontmostWindowScreen() -> NSScreen? {
        // One display: nothing to choose (and no window list to copy from the window server).
        guard NSScreen.screens.count > 1 else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = app.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // CG window coordinates have a top-left origin on the primary display.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 80, bounds.height >= 60 else { continue }
            let center = CGPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
        }
        return nil
    }
}
