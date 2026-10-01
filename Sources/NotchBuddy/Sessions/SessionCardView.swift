import AppKit
import SwiftUI
import NotchBuddyCore

/// What a session card can ask for. `jump` / `remove` / `hover` go to the island controller
/// (`IslandActions`); `toggle` to whoever keeps the expanded card (`SessionCardList`).
struct SessionCardActions {
    var jump: (SessionKey) -> Void = { _ in }
    var remove: (SessionKey) -> Void = { _ in }
    /// Expand or collapse the card.
    var toggle: (SessionKey) -> Void = { _ in }
    /// The pointer entered (true) or left (false) the card.
    var hover: (SessionKey, Bool) -> Void = { _, _ in }
    /// Copies a path (the default writes it to the general pasteboard).
    var copyPath: (String) -> Void = SessionCardActions.copyToPasteboard
    /// Shows a folder (the default opens it in Finder).
    var openFolder: (String) -> Void = SessionCardActions.openInFinder

    init(jump: @escaping (SessionKey) -> Void = { _ in }, remove: @escaping (SessionKey) -> Void = { _ in },
         toggle: @escaping (SessionKey) -> Void = { _ in },
         hover: @escaping (SessionKey, Bool) -> Void = { _, _ in }) {
        self.jump = jump
        self.remove = remove
        self.toggle = toggle
        self.hover = hover
    }

    /// The island's callbacks, with `toggle` from the list.
    init(island: IslandActions, toggle: @escaping (SessionKey) -> Void) {
        self.init(jump: island.jump, remove: island.remove, toggle: toggle, hover: island.hoverRow)
    }

    static func copyToPasteboard(_ path: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(path, forType: .string)
    }

    static func openInFinder(_ path: String) {
        var isDirectory: ObjCBool = false
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// Session row (dense, no card chrome). Collapsed (`SessionCardView.collapsedHeight`): the
/// agent's pixel mascot; line 1 «project · chat title» with small tags on the right (status, agent, its clock); line 2
/// «Вы: <last prompt>»; line 3 what it does right now (the tool's name, then its command in mono) or what it said. A click on it expands it (one spring,
/// the same one the island's silhouette follows, `IslandMotion.data`): the card grows from its top, the
/// details blur in section by section and the chevron turns over; the details are the last prompt in full, an
/// excerpt of the agent's last answer, a timeline of recent tool calls, working time, folder and host app, and
/// the actions (Перейти, Скопировать путь, Открыть папку, Убрать). Jumping is a button now, never the row click;
/// on hover a collapsed card offers a small "Перейти" of its own.
///
/// Equatable on what it shows (`.equatable()`): a hover elsewhere or an event of another session does not
/// re-render it.
struct SessionCardView: View, Equatable {
    let session: AgentSession
    var expanded: Bool
    var hovering: Bool
    /// Arrived while the list was already open: glows once (read only when it appears).
    var lateArrival = false
    /// Its agent mark is the flying hero: the text column appears this long after mounting (nil: with the card).
    var heroTextDelay: Double?
    var actions = SessionCardActions()
    /// Filmstrips only: how far the expansion is (0 … 1, a spring may overshoot); nil when live.
    var filmExpansion: Double?
    /// Filmstrips only: the expanded card's full height (the frame is interpolated towards it).
    var filmExpandedHeight: CGFloat?

    nonisolated static func == (a: SessionCardView, b: SessionCardView) -> Bool {
        a.session == b.session && a.expanded == b.expanded && a.hovering == b.hovering
            && a.heroTextDelay == b.heroTextDelay && a.filmExpansion == b.filmExpansion
            && a.filmExpandedHeight == b.filmExpandedHeight
    }

    static let collapsedHeight: CGFloat = IslandLayout.rowHeight
    static let cornerRadius: CGFloat = 14
    static let iconSize: CGFloat = 34
    static let padding: CGFloat = 14
    /// Where the text column starts (the details line up with it).
    static let textInset: CGFloat = padding + iconSize + 12
    /// The one spring of expand / collapse (the island's silhouette follows content on the same one).
    static var expandAnimation: Animation { IslandMotion.data.animation }
    static var expandCurve: MotionCurve { IslandMotion.data.curve }

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandFilmTime) private var filmTime
    @State private var arrivalGlow = 0.0
    @State private var shakeTrigger = 0
    @State private var waitPulse = 0
    @State private var doneSweep = 0
    @State private var pressed = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous) }
    private var tint: Color { session.status.tint }
    private var showsDetails: Bool { filmExpansion.map { $0 > 0.001 } ?? expanded }
    private var chevronTurn: Double {
        if let filmExpansion { return 180 * filmExpansion }
        return expanded ? 180 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsDetails {
                SessionCardDetails(session: session, actions: actions)
                    .transition(reduceMotion ? .opacity.animation(.easeOut(duration: 0.14).speed(IslandMotion.speed))
                                             : .sessionDetails)
            }
        }
        .frame(height: filmHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { background }
        .overlay { border }
        // One-shot overlays exist only once they have played (a list of rows builds faster without them).
        .overlay {
            if doneSweep > 0 {
                DoneSweep(trigger: doneSweep, color: SessionStatus.finished.tint).clipShape(shape).allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .overlay { if waitPulse > 0 { waitFlare } }
        .scaleEffect(pressed ? 0.985 : 1)
        .animation(IslandMotion.press.animation, value: pressed)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakeTrigger) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-1.5, duration: IslandMotion.t(0.05))
                CubicKeyframe(1.5, duration: IslandMotion.t(0.06))
                CubicKeyframe(-1, duration: IslandMotion.t(0.06))
                CubicKeyframe(0.6, duration: IslandMotion.t(0.06))
                CubicKeyframe(0, duration: IslandMotion.t(0.07))
            }
        }
        .onHover { actions.hover(session.key, $0) }
        .onAppear {
            guard lateArrival, !staticRender, !reduceMotion, filmTime == nil else { return }
            arrivalGlow = 0.14
            withAnimation(.easeOut(duration: 1.4).speed(IslandMotion.speed)) { arrivalGlow = 0 }
        }
        .onChange(of: session.status) { old, new in
            guard !reduceMotion, !staticRender else { return }
            if new == .error, old != .error { shakeTrigger &+= 1 }
            if new == .waitingForUser, old != .waitingForUser { waitPulse &+= 1 }
            // Done: a green sheen sweeps across the card, once per episode.
            if new == .finished, old != .finished, OneShots.claim("card-done:\(session.episode)") { doneSweep &+= 1 }
        }
    }

    /// Filmstrips: the frame between the collapsed and the expanded height.
    private var filmHeight: CGFloat? {
        guard let filmExpansion, let full = filmExpandedHeight else { return nil }
        return Self.collapsedHeight + (full - Self.collapsedHeight) * CGFloat(max(filmExpansion, 0))
    }

    // MARK: Chrome

    /// No card: a row lights up only under the pointer or while expanded (and once, softly, when it arrives late).
    private var background: some View {
        ZStack {
            shape.fill(Color.white.opacity(hovering ? 0.065 : expanded ? 0.045 : 0))
            shape.fill(Color.white.opacity(arrivalGlow * 0.6))
        }
        .animation(.smooth(duration: 0.22).speed(IslandMotion.speed), value: hovering)
    }

    private var border: some View {
        shape.strokeBorder(Color.white.opacity(expanded ? 0.07 : 0), lineWidth: 0.6)
            .animation(.smooth(duration: 0.2).speed(IslandMotion.speed), value: expanded)
            .allowsHitTesting(false)
    }

    /// Moved up because it now waits for the user: its border flares once.
    private var waitFlare: some View {
        shape.strokeBorder(SessionStatus.waitingForUser.tint, lineWidth: 1.2)
            .keyframeAnimator(initialValue: 0.0, trigger: waitPulse) { content, opacity in
                content.opacity(opacity)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.9, duration: IslandMotion.t(0.22))
                    CubicKeyframe(0, duration: IslandMotion.t(0.5))
                }
            }
            .allowsHitTesting(false)
    }

    // MARK: Header (the collapsed card)

    private var header: some View {
        Button { actions.toggle(session.key) } label: {
            HStack(alignment: .center, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 0) {
                    titleRow
                        .frame(height: 18)
                    promptRow
                        // Clear of the chevron at the row's trailing edge.
                        .padding(.trailing, 30)
                        .frame(height: 15)
                        .padding(.top, 2)
                    SessionActivityLine(session: session)
                        .padding(.trailing, 30)
                        .frame(height: 16)
                        .padding(.top, 2)
                }
                .appearAfter(heroTextDelay ?? 0, style: .fade, enabled: heroTextDelay != nil)
            }
            .padding(.horizontal, Self.padding)
            .frame(height: Self.collapsedHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(pressed: $pressed))
        .overlay(alignment: .bottomTrailing) { trailingControls }
        .accessibilityLabel("\(session.title), \(SessionStrings.status(session.status))")
        .accessibilityHint(expanded ? SessionStrings.Card.collapse : SessionStrings.Card.expand)
    }

    /// The session's pixel mascot, animated for its state (it carries the status: no glow behind it).
    private var icon: some View {
        HeroSlot(session: session, size: Self.iconSize)
            .frame(width: Self.iconSize, height: Self.iconSize)
    }

    /// «project · chat title» (the project dimmer), then the tags.
    private var titleRow: some View {
        HStack(spacing: 8) {
            titleText
                .font(SessionType.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            SessionRowTags(session: session)
        }
    }

    private var titleText: Text {
        let chat = SessionNaming.oneLine(session.chatTitle) ?? SessionNaming.promptTitle(session.firstPrompt)
        let primary = Text(chat ?? session.displayTitle ?? SessionStrings.agentName(session.source))
            .foregroundColor(IslandPalette.primary)
        guard let project = session.projectName, let chat, chat != project else { return primary }
        return Text(project).foregroundColor(Color.white.opacity(0.62))
            + Text(" · ").foregroundColor(IslandPalette.tertiary)
            + primary
    }

    /// «Вы: <last prompt>»; without one, what the session is doing in words.
    private var promptRow: some View {
        Group {
            if let prompt = SessionStrings.oneLine(session.lastPrompt ?? session.firstPrompt) {
                (Text(L("Вы:")).foregroundColor(IslandPalette.tertiary).fontWeight(.semibold)
                    + Text(" " + prompt).foregroundColor(IslandPalette.secondary))
            } else {
                Text(SessionStrings.statusDetail(session.status)).foregroundColor(IslandPalette.tertiary)
            }
        }
        .font(SessionType.meta)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// The chevron (always) and, on hover while collapsed, a quick "Перейти" (the line under it fades out).
    private var trailingControls: some View {
        let quickJump = hovering && !expanded && filmExpansion == nil
        return HStack(spacing: 6) {
            if quickJump {
                Button { actions.jump(session.key) } label: {
                    HStack(spacing: 3) {
                        Text(SessionStrings.Actions.jump)
                        IslandSymbol("arrow.up.right", size: 8.5)
                    }
                }
                .buttonStyle(SessionPillButtonStyle(kind: .primary, height: 20))
                .help(SessionStrings.Actions.jumpHelp)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8, anchor: .trailing).combined(with: .opacity)
                        .animation(.spring(response: 0.26, dampingFraction: 0.78).speed(IslandMotion.speed)),
                    removal: .opacity.animation(.easeOut(duration: 0.1).speed(IslandMotion.speed))))
            }
            Chevron(turn: chevronTurn, hovering: hovering)
                .allowsHitTesting(false)
        }
        .padding(.leading, 48)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .background(alignment: .trailing) {
            if quickJump {
                LinearGradient(stops: [.init(color: Self.hoverFill.opacity(0), location: 0),
                                       .init(color: Self.hoverFill, location: 0.34)],
                               startPoint: .leading, endPoint: .trailing)
                    .padding(.bottom, 6)
                    .padding(.top, -2)
                    .transition(.opacity.animation(.easeOut(duration: 0.14).speed(IslandMotion.speed)))
                    .allowsHitTesting(false)
            }
        }
    }

    /// The hovered card's fill at its third line (behind the quick "Перейти").
    static let hoverFill = Color(white: 0.082)
}

// MARK: - Pieces

/// The chevron: turns over as the card opens (it rides the expand transaction).
private struct Chevron: View {
    let turn: Double
    let hovering: Bool

    var body: some View {
        NBIconView(.chevron, size: 13, color: hovering || turn > 90 ? Color.white.opacity(0.9) : IslandPalette.tertiary)
            .rotationEffect(.degrees(turn))
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.white.opacity(hovering || turn > 90 ? 0.1 : 0)))
            .animation(.smooth(duration: 0.2).speed(IslandMotion.speed), value: hovering)
    }
}

/// Press feedback for the card's header: the whole card sinks a little.
private struct CardPressStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, now in pressed = now }
    }
}

/// Status in a tinted capsule with its live indicator (equalizer, pulse, drawn check, shaking mark).
struct SessionStatusPill: View {
    let session: AgentSession

    var body: some View {
        let tint = session.status.tint
        HStack(spacing: 5) {
            LiveIndicator(status: session.status, size: 11, episode: session.episode, key: session.key)
            Text(SessionStrings.status(session.status))
                .font(SessionType.pill)
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.interpolate)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(0.15)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 0.5))
        .animation(IslandMotion.tint, value: session.status)
    }
}

/// A row's small tags, right of its title: the status (only a live or failed one: its color is the accent), the agent,
/// and the status's clock ("2:14" running, "5 мин" after).
struct SessionRowTags: View {
    let session: AgentSession
    @Environment(IslandClock.self) private var clock: IslandClock?

    var body: some View {
        HStack(spacing: 5) {
            if session.status != .idle, session.status != .finished {
                let tint = session.status.tint
                HStack(spacing: 4) {
                    LiveIndicator(status: session.status, size: 9, episode: session.episode, key: session.key)
                    Text(SessionStrings.status(session.status))
                        .contentTransition(.interpolate)
                }
                .foregroundStyle(tint)
                .modifier(RowTag(fill: tint.opacity(0.13)))
            } else if session.status == .finished {
                Text(SessionStrings.status(session.status))
                    .foregroundStyle(SessionStatus.finished.tint)
                    .modifier(RowTag(fill: SessionStatus.finished.tint.opacity(0.11)))
            }
            Text(SessionStrings.agentShortName(session.source))
                .foregroundStyle(Color.white.opacity(0.6))
                .modifier(RowTag(fill: Color.white.opacity(0.07)))
            SessionStatusClock(session: session, compact: true)
        }
        .animation(IslandMotion.tint, value: session.status)
    }
}

/// A small tag: 10.5 pt text on a soft capsule, 17 pt tall.
private struct RowTag: ViewModifier {
    let fill: Color

    func body(content: Content) -> some View {
        content
            .font(SessionFont.manrope(10.5, 700))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(fill))
    }
}

/// "2:14" while it works or waits (a running clock), "5 мин назад" after.
struct SessionStatusClock: View {
    let session: AgentSession
    /// The row's tag size (10.5 pt).
    var compact = false
    @Environment(IslandClock.self) private var clock: IslandClock?

    var body: some View {
        let text = SessionStrings.statusClock(session.status, since: session.statusSince, now: clock?.now ?? Date())
        let live = SessionStrings.runsClock(session.status)
        Text(text)
            .font(compact ? SessionFont.manrope(10.5, 650) : SessionType.clock)
            .monospacedDigit()
            .foregroundStyle(live ? Color.white.opacity(0.78) : IslandPalette.tertiary)
            .contentTransition(.numericText(countsDown: false))
            .animation(.snappy(duration: 0.24).speed(IslandMotion.speed), value: text)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Third line: the tool it runs, what it said last, or what it is waiting for. A new line pushes the old one up
/// (at most one animated swap per 0.4 s; faster updates just replace it).
struct SessionActivityLine: View {
    let session: AgentSession
    @State private var lastSwap = -TimeInterval.infinity

    var body: some View {
        let line = Self.line(for: session)
        let throttled = AppClock.monotonicSeconds() - lastSwap < 0.4
        ZStack(alignment: .leading) {
            content(line)
                .id(line.signature)
                .transition(.asymmetric(insertion: .push(from: .bottom), removal: .push(from: .bottom))
                    .combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .transaction(value: line.signature) { transaction in
            if throttled {
                transaction.disablesAnimations = true
            } else {
                transaction.animation = .spring(response: 0.32, dampingFraction: 0.88).speed(IslandMotion.speed)
            }
        }
        .onChange(of: line.signature) { lastSwap = AppClock.monotonicSeconds() }
    }

    private func content(_ line: Line) -> some View {
        HStack(spacing: 6) {
            if let name = line.name {
                // The tool's name in its color (a calm blue while it works, the status color while it waits).
                Text(name)
                    .font(SessionType.metaStrong)
                    .foregroundStyle(line.tint)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                IslandSymbol(line.symbol, size: 9.5, color: line.tint)
                    .frame(width: 12, height: 12)
            }
            if !line.text.isEmpty {
                Text(line.text)
                    .font(line.code ? SessionType.code(10.5) : SessionType.meta)
                    .foregroundStyle(line.code ? Color.white.opacity(0.56) : IslandPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    struct Line: Equatable {
        var symbol: String
        var tint: Color
        var name: String?
        var text: String
        var code: Bool
        var filledGlyph = false

        var signature: String { "\(symbol)|\(name ?? "")|\(text)" }
    }

    static func line(for session: AgentSession) -> Line {
        let message = SessionStrings.oneLine(session.lastMessage)
        let tint = session.status.tint
        switch session.status {
        case .waitingForUser:
            if let tool = session.lastToolName, !tool.isEmpty, message == nil || message == session.lastToolSummary.flatMap(SessionStrings.oneLine) {
                return toolLine(tool, session.lastToolSummary, tint: tint)
            }
            return Line(symbol: "bell.fill", tint: tint, text: message ?? SessionStrings.statusDetail(.waitingForUser),
                        code: false, filledGlyph: true)
        case .error:
            return Line(symbol: "exclamationmark.triangle.fill", tint: tint,
                        text: message ?? SessionStrings.statusDetail(.error), code: false, filledGlyph: true)
        case .finished, .idle:
            if let reply = SessionStrings.replyLine(session.lastAgentMessage) ?? message {
                return Line(symbol: "text.bubble.fill", tint: session.status == .finished ? tint : IslandPalette.secondary,
                            text: reply, code: false)
            }
        case .working:
            break
        }
        if let tool = session.lastToolName, !tool.isEmpty {
            return toolLine(tool, session.lastToolSummary,
                            tint: session.status == .working ? Self.toolTint : IslandPalette.secondary)
        }
        if session.status == .working {
            return Line(symbol: "sparkles", tint: tint, text: SessionStrings.statusDetail(.working), code: false)
        }
        return Line(symbol: "moon.zzz.fill", tint: IslandPalette.tertiary, text: SessionStrings.statusDetail(session.status),
                    code: false)
    }

    /// A working session's tool name, colored, muted.
    static let toolTint = Color(red: 0.47, green: 0.68, blue: 1.0)

    private static func toolLine(_ tool: String, _ summary: String?, tint: Color) -> Line {
        Line(symbol: SessionStrings.toolSymbol(tool), tint: tint, name: SessionStrings.toolName(tool),
             text: SessionStrings.toolSummary(tool, summary) ?? "", code: SessionStrings.toolSummaryIsCode(tool))
    }
}

/// A tool's symbol on a small tinted tile.
struct ToolGlyph: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 18
    var filled = false

    var body: some View {
        IslandSymbol(symbol, size: size * 0.5, color: tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(tint.opacity(filled ? 0.2 : 0.13)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 0.5))
    }
}
