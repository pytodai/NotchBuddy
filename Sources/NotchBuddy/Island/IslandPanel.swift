import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats over the menu bar on every Space.
///
/// It is a fixed transparent canvas (big enough for the largest open island plus its shadow) that is
/// never resized while the island animates. It ignores the mouse, so clicks fall through to the apps
/// below, except while the pointer is over the island itself (`IslandPointerTracker`).
///
/// It becomes key only while `allowsKey` is set, which `IslandKeyFocus` does only while the pointer is
/// over a permission card (for ⌘Y / ⌘N / ⌘T); becoming key never activates NotchBuddy.
final class IslandPanel: NSPanel {
    var allowsKey = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        alphaValue = 1  // goes through the override: 1 % in test runs
    }

    /// Test runs (perf bench, `--render-*` previews, `NOTCHBUDDY_PERF=1` or `NOTCHBUDDY_TEST_INVISIBLE=1`) must never show up
    /// on the user's screen or take their clicks. The window server still composites the panel at 1 % opacity, so
    /// frame-pacing numbers stay real while the island is invisible to the eye.
    static let invisibleForTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        let rendering = CommandLine.arguments.contains { $0.hasPrefix("--render-") }
        return rendering || env["NOTCHBUDDY_PERF"] == "1" || env["NOTCHBUDDY_TEST_INVISIBLE"] == "1"
    }()

    override var alphaValue: CGFloat {
        get { super.alphaValue }
        set { super.alphaValue = Self.invisibleForTests ? min(newValue, 0.01) : newValue }
    }

    override var ignoresMouseEvents: Bool {
        get { super.ignoresMouseEvents }
        set { super.ignoresMouseEvents = Self.invisibleForTests ? true : newValue }
    }

    override var canBecomeKey: Bool { allowsKey && !Self.invisibleForTests }
    override var canBecomeMain: Bool { false }

    /// The island deliberately overlaps the menu bar; AppKit would push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Content view of the panel: hosts the SwiftUI island and reports pointer movement over the panel
/// (a tracking area works whenever the panel takes mouse events, even though NotchBuddy is never active).
final class IslandContainerView: NSView {
    var onPointerEvent: (NSEvent) -> Void = { _ in }
    private var trackingArea: NSTrackingArea?

    init(host: NSView) {
        super.init(frame: .zero)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerEvent(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEvent(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerEvent(event)
    }
}

/// Hosting view that takes the first click even though its window is never key,
/// so buttons respond immediately without activating NotchBuddy.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
