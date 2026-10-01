import SwiftUI
import NotchBuddyCore

/// The expanded part of a session card: the last prompt in full (a long one folds to `promptLines` with
/// "Показать полностью"), an excerpt of the agent's last answer, the recent tool calls as a timeline, time and
/// host app as tiles, and the actions. Sections blur in one after another (22 ms apart) while the card grows
/// around them. The folder's path is in the card's header while it is expanded.
struct SessionCardDetails: View {
    let session: AgentSession
    let actions: SessionCardActions

    /// Timeline rows shown (newest first); the section's label counts them all.
    static let maxTimelineRows = 4
    static let promptLines = 4
    static let fullPromptLines = 30
    static let replyLines = 4

    @State private var fullPrompt = false

    private static func delay(_ index: Int) -> Double { 0.03 + 0.022 * Double(index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.1), .white.opacity(0.0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 0.5)
                .padding(.horizontal, SessionCardView.padding)
                .appearAfter(Self.delay(0), style: .fade)
            VStack(alignment: .leading, spacing: 11) {
                promptSection
                    .appearAfter(Self.delay(0), style: .section)
                if let reply = session.lastAgentMessage {
                    replySection(reply)
                        .appearAfter(Self.delay(1), style: .section)
                }
                toolsSection
                    .appearAfter(Self.delay(2), style: .section)
                SessionFacts(session: session)
                    .appearAfter(Self.delay(3), style: .section)
            }
            .padding(.leading, SessionCardView.textInset)
            .padding(.trailing, SessionCardView.padding + 2)
            .padding(.top, 10)
            SessionCardActionBar(session: session, actions: actions)
                .appearAfter(Self.delay(4), style: .section)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sections

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: SessionStrings.Card.prompt)
            if let prompt = Self.prompt(session) {
                Text(prompt)
                    .font(SessionType.body)
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineSpacing(1.5)
                    .lineLimit(fullPrompt ? Self.fullPromptLines : Self.promptLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if Self.isLong(prompt) {
                    Button {
                        withAnimation(SessionCardView.expandAnimation) { fullPrompt.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(fullPrompt ? SessionStrings.Card.showLessPrompt : SessionStrings.Card.showFullPrompt)
                                .contentTransition(.interpolate)
                            IslandSymbol("chevron.down", size: 7.5)
                                .rotationEffect(.degrees(fullPrompt ? 180 : 0))
                        }
                    }
                    .buttonStyle(SessionLinkButtonStyle())
                }
            } else {
                Text(SessionStrings.Card.noPrompt)
                    .font(SessionType.body)
                    .foregroundStyle(IslandPalette.tertiary)
            }
        }
    }

    private func replySection(_ reply: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: SessionStrings.Card.reply)
            HStack(alignment: .top, spacing: 9) {
                // A quote bar in gray (the agent's own color stays in its mascot).
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 2)
                Self.replyText(reply)
                    .lineSpacing(1.5)
                    .lineLimit(Self.replyLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toolsSection: some View {
        let calls = session.recentTools.newestFirst
        let shown = Array(calls.prefix(Self.maxTimelineRows))
        // The call a permission request is about: the newest one still running while the session waits.
        let awaiting = session.status == .waitingForUser ? calls.first(where: \.isRunning)?.id : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                SectionLabel(text: SessionStrings.Card.tools)
                if !calls.isEmpty {
                    Text(Self.toolsSummary(session.recentTools))
                        .font(SessionType.caption)
                        .foregroundStyle(IslandPalette.tertiary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(IslandMotion.leaf, value: calls.count)
                }
            }
            if shown.isEmpty {
                Text(SessionStrings.Card.noTools)
                    .font(SessionType.body)
                    .foregroundStyle(IslandPalette.tertiary)
            } else {
                ToolTimeline(calls: shown, awaitingId: awaiting)
            }
        }
    }

    // MARK: Text

    /// The last prompt (the first one when the agent never reported a later one), newlines kept.
    static func prompt(_ session: AgentSession) -> String? {
        guard let text = session.lastPrompt ?? session.firstPrompt else { return nil }
        let trimmed = text.replacingOccurrences(of: " ⏎ ", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An answer as the card sets it: headings bold and bright, the rest secondary.
    static func replyText(_ reply: String) -> Text {
        var text: Text?
        for line in SessionStrings.markdownLines(reply) {
            let piece = Text(line.text)
                .font(line.heading ? SessionType.bodyStrong : SessionType.body)
                .foregroundColor(line.heading ? Color.white.opacity(0.9) : IslandPalette.secondary)
            text = text.map { Text("\($0)\n\(piece)") } ?? piece
        }
        return text ?? Text("")
    }

    /// Longer than `promptLines` lines of the card's text column (about 58 characters a line).
    static func isLong(_ prompt: String) -> Bool {
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / 58).rounded(.up))) }
        return lines > promptLines
    }

    /// "12 вызовов · 1 ошибка".
    static func toolsSummary(_ tools: RecentToolCalls) -> String {
        let total = SessionStrings.count(tools.count, "вызов", "вызова", "вызовов")
        let failures = tools.failures
        guard failures > 0 else { return total }
        return "\(total) · \(SessionStrings.count(failures, "ошибка", "ошибки", "ошибок"))"
    }
}

/// Small caps label of a details section.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(SessionType.caption)
            .tracking(0.8)
            .foregroundStyle(Color.white.opacity(0.4))
    }
}

/// "Показать полностью": a quiet text button.
private struct SessionLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    private struct LinkBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(SessionFont.manrope(11, 700))
                .foregroundStyle(SessionStatus.working.tint.opacity(hovering ? 1 : 0.85))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12).speed(IslandMotion.speed), value: hovering)
        }
    }
}

// MARK: - Facts

/// Working time, session age and host app, as small tiles.
struct SessionFacts: View {
    let session: AgentSession
    @Environment(IslandClock.self) private var clock: IslandClock?

    var body: some View {
        let now = clock?.now ?? Date()
        let live = SessionStrings.runsClock(session.status)
        HStack(spacing: 6) {
            FactTile(symbol: live ? "timer" : "clock",
                     label: SessionStrings.statusClockLabel(session.status),
                     value: live ? SessionStrings.clock(now.timeIntervalSince(session.statusSince))
                                 : SessionStrings.ago(now.timeIntervalSince(session.statusSince)),
                     tint: live ? session.status.tint : nil, live: live)
            FactTile(symbol: "hourglass", label: SessionStrings.Card.session,
                     value: SessionStrings.duration(now.timeIntervalSince(session.startedAt)))
            if let app = SessionStrings.hostApp(session.host) {
                FactTile(symbol: "macwindow", label: SessionStrings.Card.app, value: app)
            }
        }
    }
}

private struct FactTile: View {
    let symbol: String
    let label: String
    let value: String
    var tint: Color?
    var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                IslandSymbol(symbol, size: 7.5, weight: .bold, color: Color.white.opacity(0.4))
                Text(label.uppercased())
                    .font(SessionFont.manrope(8.5, 750))
                    .tracking(0.6)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(0.4))
            Text(value)
                .font(SessionFont.manrope(12, 700))
                .monospacedDigit()
                .foregroundStyle(tint ?? Color.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText(countsDown: false))
                .animation(live ? .snappy(duration: 0.24).speed(IslandMotion.speed) : nil, value: value)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - Actions

/// Перейти · Скопировать путь · Открыть папку · Убрать. Where the labels do not fit (a larger font, a narrow
/// island) "Убрать" becomes a round ×, then the folder buttons drop their labels too.
struct SessionCardActionBar: View {
    let session: AgentSession
    let actions: SessionCardActions
    @State private var copied = 0
    @State private var showCopied = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: 0)
            bar(compact: 1)
            bar(compact: 2)
        }
        .task(id: copied) {
            guard copied > 0 else { return }
            try? await Task.sleep(for: IslandMotion.delay(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.24).speed(IslandMotion.speed)) { showCopied = false }
        }
    }

    /// `compact`: 0 all labels, 1 "Убрать" as an icon, 2 the folder buttons as icons too.
    private func bar(compact: Int) -> some View {
        HStack(spacing: 5) {
            Button { actions.jump(session.key) } label: {
                HStack(spacing: 4) {
                    Text(SessionStrings.Actions.jump)
                    IslandSymbol("arrow.up.right", size: 9)
                }
            }
            .buttonStyle(SessionPillButtonStyle(kind: .primary))
            .help(SessionStrings.Actions.jumpHelp)

            if let cwd = session.cwd, !cwd.isEmpty {
                Button {
                    actions.copyPath(cwd)
                    withAnimation(.snappy(duration: 0.24).speed(IslandMotion.speed)) { showCopied = true }
                    copied &+= 1
                } label: {
                    HStack(spacing: 5) {
                        // The sheets turn into a check once copied.
                        IslandSymbol("doc.on.doc", size: 9.5, value: showCopied ? 1 : 0)
                        if compact < 2 {
                            Text(showCopied ? SessionStrings.Actions.copied : SessionStrings.Actions.copyPath)
                                .contentTransition(.interpolate)
                        }
                    }
                }
                .buttonStyle(SessionPillButtonStyle(kind: showCopied ? .success : .secondary, round: compact >= 2))
                .help(compact >= 2 ? "\(SessionStrings.Actions.copyPath): \(cwd)" : cwd)

                Button { actions.openFolder(cwd) } label: {
                    HStack(spacing: 5) {
                        IslandSymbol("folder", size: 9.5)
                        if compact < 2 { Text(SessionStrings.Actions.openFolder) }
                    }
                }
                .buttonStyle(SessionPillButtonStyle(kind: .secondary, round: compact >= 2))
                .help(SessionStrings.Actions.openFolder)
            }

            Spacer(minLength: 0)

            Button { actions.remove(session.key) } label: {
                HStack(spacing: 4) {
                    IslandSymbol("xmark", size: 8.5)
                    if compact == 0 { Text(SessionStrings.Actions.remove) }
                }
            }
            .buttonStyle(SessionPillButtonStyle(kind: .ghost, round: compact >= 1))
            .help(SessionStrings.Actions.removeHelp)
        }
    }
}

/// The cards' capsule buttons: primary (white), secondary (glass), success (green, after "copied"), ghost (quiet,
/// red on hover: it removes). `round`: an icon alone in a circle.
struct SessionPillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, success, ghost }
    var kind: Kind
    var height: CGFloat = 26
    var round = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, height: height, round: round)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SessionPillButtonStyle.Kind
    let height: CGFloat
    let round: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(height < 24 ? SessionFont.manrope(11, 700) : SessionType.button)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .environment(\.islandInk, foreground)
            .environment(\.nbControlHovered, hovering)
            .padding(.horizontal, round ? 0 : (height < 24 ? 8 : 9))
            .frame(minWidth: round ? height : nil)
            .frame(height: height)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(IslandMotion.press.animation, value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14).speed(IslandMotion.speed), value: hovering)
            .animation(.snappy(duration: 0.24).speed(IslandMotion.speed), value: kind)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .black
        case .secondary: return .white.opacity(hovering ? 1 : 0.88)
        case .success: return SessionStatus.finished.tint
        case .ghost: return hovering ? IslandPalette.danger : IslandPalette.secondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return hovering ? Color(white: 0.86) : .white
        case .secondary: return .white.opacity(hovering ? 0.17 : 0.09)
        case .success: return SessionStatus.finished.tint.opacity(0.16)
        case .ghost: return hovering ? IslandPalette.danger.opacity(0.14) : .white.opacity(0.0)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return .white.opacity(0.08)
        case .success: return SessionStatus.finished.tint.opacity(0.3)
        case .ghost: return hovering ? IslandPalette.danger.opacity(0.25) : .white.opacity(0.08)
        }
    }
}
