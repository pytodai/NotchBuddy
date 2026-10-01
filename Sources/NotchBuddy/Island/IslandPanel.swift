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

/// The island's horizontal place in the panel. The panel spans its screen (and at least the canvas), so a dragged
/// «Островок» can sit anywhere along the top; the island itself is drawn on a fixed canvas (`IslandLayout.canvasSize`),
/// `content`, whose frame is centered on the anchor plus `frameShift` (where the island is heading: AppKit hit-tests
/// there). While it slides, this view's `sublayerTransform` carries the difference between where the island is drawn
/// and that frame (baked by `IslandStage`: the render server plays it), so the whole island moves rigidly at 60 fps and
/// nothing is laid out again.
final class IslandSlideView: NSView {
    let content: NSView
    /// The canvas the island is drawn on (zero: the whole view).
    var canvasSize: CGSize = .zero {
        didSet { if canvasSize != oldValue { place() } }
    }
    /// The anchor's x in this view: the screen's top center, or the camera housing's (nil: the middle).
    var anchorX: CGFloat? {
        didSet { if anchorX != oldValue { place() } }
    }
    /// Where the canvas' center sits relative to the anchor (whole points).
    private(set) var frameShift: CGFloat = 0

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.actions = IslandStage.noActions
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        place()
    }

    /// Moves the canvas' frame to `shift` from the anchor (no animation: the caller bakes the visible motion).
    func setFrameShift(_ shift: CGFloat) {
        guard shift != frameShift else { return }
        frameShift = shift
        place()
    }

    /// The canvas' frame in this view.
    var canvasFrame: CGRect {
        let size = canvasSize == .zero ? bounds.size : canvasSize
        let center = (anchorX ?? bounds.width / 2) + frameShift
        return CGRect(x: (center - size.width / 2).rounded(), y: 0, width: size.width, height: size.height)
    }

    private func place() {
        guard content.superview === self else { return }
        let frame = canvasFrame
        guard content.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = frame
        CATransaction.commit()
    }
}

/// Hosting view that takes the first click even though its window is never key,
/// so buttons respond immediately without activating NotchBuddy.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
