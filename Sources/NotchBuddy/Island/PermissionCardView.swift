import AppKit
import SwiftUI
import NotchBuddyCore

/// Card for the first pending permission request. Shows exactly what is being approved
/// (`PermissionDetail`); the model's own explanation is labeled as such.
///
/// Decisions go through `decide`, which `IslandController` accepts only for the armed front card.
/// While the card is arming (`armed == false`) the buttons are disabled and "Разрешить" fills up once;
/// when it arms, the button glints. ⌘Y / ⌘N / ⌘T are handled by `IslandKeyFocus`; their hints show
/// only while they are live.
///
/// Motion: the card's sections cascade in as the silhouette uncovers them (a new card in a queue
/// rises from below instead, so a changed request never looks like the same card); the code block, an
/// AppKit view the silhouette cannot mask, comes in with them as a snapshot of itself and turns live once
/// the silhouette has settled around it (it leaves first, though). The queue
/// indicator (and, on a notched screen, the strip beside the camera) is not part of the card: it is
/// `PermissionQueueChrome`, drawn over the card's placeholders, so it stays while the requests swap.
struct PermissionCardView: View {
    let card: PermissionCardInfo
    let total: Int
    var queue: [UUID] = []
    let metrics: IslandMetrics
    let width: CGFloat
    /// False for the first `PermissionArming.delay` of a card: clicks and shortcuts are ignored.
    let armed: Bool
    /// When the card appeared, in monotonic seconds (the arming fill runs from here).
    var presentedAt: TimeInterval?
    /// The panel has the keyboard (the pointer is over the card), so the shortcuts work.
    let keyboardActive: Bool
    let decide: (PermissionDecision) -> Void

    @Environment(\.islandEntrance) private var entrance
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandHeroKey) private var heroKey
    @Environment(\.islandHeroFlies) private var heroFlies
    @State private var armProgress: CGFloat = 0

    static let horizontalPadding: CGFloat = 16
    /// The header row (agent mark, project, queue indicator) is exactly this tall.
    static let headerHeight: CGFloat = 34
    static func topPadding(_ metrics: IslandMetrics) -> CGFloat { metrics.style == .notch ? 8 : 16 }

    var body: some View {
        let event = card.event
        let detail = card.detail
        let notch = metrics.style == .notch
        VStack(alignment: .leading, spacing: 0) {
            if notch {
                // The strip itself is `PermissionQueueChrome` (it stays while requests swap).
                Color.clear.frame(height: metrics.barHeight)
            }
            VStack(alignment: .leading, spacing: 0) {
                header(event)
                    .appearAfter(delay(1), style: sectionStyle)
                toolLine(event)
                    .padding(.top, 8)
                    .appearAfter(delay(2), style: sectionStyle)
                // Reveals itself: only its SwiftUI part may take the section's blur and offset.
                CodeBlock(text: detail.body, width: width - 2 * Self.horizontalPadding,
                          delay: delay(3), style: sectionStyle)
                    .padding(.top, 14)
                if detail.hiddenCharacters > 0 {
                    warning(L("Невидимые и управляющие символы показаны как ⟨U+…⟩ — проверь внимательно"))
                        .padding(.top, 10)
                        .appearAfter(delay(4), style: sectionStyle)
                }
                if detail.omittedCharacters > 0 {
                    warning(L("Показана только часть запроса — целиком он виден в терминале"))
                        .padding(.top, 10)
                        .appearAfter(delay(4), style: sectionStyle)
                }
                if let reason = detail.justification {
                    justification(reason)
                        .padding(.top, 10)
                        .appearAfter(delay(5), style: sectionStyle)
                }
                buttons(event)
                    .padding(.top, 16)
                    .appearAfter(delay(6), style: sectionStyle)
                footer
                    .padding(.top, 10)
                    .appearAfter(delay(7), style: sectionStyle)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, Self.topPadding(metrics))
            .padding(.bottom, 12)
        }
        .frame(width: width)
        .background(alignment: .topLeading) { warmth }
        .onAppear(perform: startArming)
    }

    // MARK: Motion

    private func delay(_ order: Int) -> Double { Self.sectionDelay(order, entrance: entrance, metrics: metrics) }

    /// Sections cascade 20 ms apart while the silhouette uncovers them: from 30 ms out of a closed
    /// island, 40 ms from an open one, 55 ms for the next card of a queue (it rises as the old one, sent
    /// up, is gone at ~50 ms; the notch strip stays, so the header leads there too). Order 0 is the
    /// notch strip, so on a screen without one the header is k = 0.
    static func sectionDelay(_ order: Int, entrance: IslandEntrance, metrics: IslandMetrics) -> Double {
        let k = Double(min(max(order - (metrics.style == .notch ? 0 : 1), 0), 6))
        switch entrance {
        case .deck: return 0.055 + 0.02 * Double(min(max(order - 1, 0), 6))
        case .open: return 0.03 + 0.02 * k
        default: return 0.04 + 0.02 * k
        }
    }

    static func sectionStyle(_ entrance: IslandEntrance) -> AppearStyle { entrance == .deck ? .deckSection : .section }
    private var sectionStyle: AppearStyle { Self.sectionStyle(entrance) }

    private var arming: CGFloat {
        if let filmTime { return CGFloat(min(max(filmTime / PermissionArming.seconds, 0), 1)) }
        if staticRender { return 0.6 }
        return armProgress
    }

    private func startArming() {
        guard !staticRender, filmTime == nil, !armed else { return }
        let elapsed = presentedAt.map { AppClock.monotonicSeconds() - $0 } ?? 0
        let remaining = max(PermissionArming.seconds - elapsed, 0)
        armProgress = CGFloat(min(max(elapsed / PermissionArming.seconds, 0), 1))
        withAnimation(.linear(duration: remaining).speed(IslandMotion.speed)) { armProgress = 1 }
    }

    /// A warm light behind the agent: this card wants an answer. It stays off the top edge, which must
    /// read as pure black (the island continues the camera housing).
    private var warmth: some View {
        let topClear: CGFloat = metrics.style == .notch ? metrics.barHeight + 10 : 40
        let tint = SessionStatus.waitingForUser.tint
        return RadialGradient(colors: [tint.opacity(0.10), tint.opacity(0.03), .clear],
                              center: .center, startRadius: 0, endRadius: 190)
            .frame(width: 380, height: 380)
            .offset(x: -150, y: topClear - 150)
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: topClear)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 36)
                    Color.black
                }
            }
            .allowsHitTesting(false)
    }

    // MARK: Parts

    private func header(_ event: AgentEvent) -> some View {
        HStack(spacing: 11) {
            // The agent's mascot, waiting (its hopping "!" is the card's live status).
            HeroSlot(key: event.sessionKey, size: 32, mascot: .waiting)
            VStack(alignment: .leading, spacing: 2) {
                Text(VisibleText.escaped(card.projectTitle))
                    .font(.manrope(14, weight: 680))
                    .foregroundStyle(IslandPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L("%@ просит разрешения", event.source.displayName))
                    .font(.manrope(11.5, weight: 520))
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(1)
            }
            // The flying agent mark lands first, then its text (it would fly over it otherwise).
            .appearAfter(delay(1) + IslandMotion.heroTextLag(entrance, flies: heroFlies, notch: metrics.style == .notch,
                                                             card: true),
                         style: .fade, enabled: heroKey == event.sessionKey)
            Spacer(minLength: 8)
            if total > 1, metrics.style != .notch {
                // Holds the place of `PermissionQueueChrome`'s indicator, which draws over it.
                QueueIndicator(queue: queue, total: total).hidden()
            }
        }
        .frame(height: Self.headerHeight)
    }

    private func toolLine(_ event: AgentEvent) -> some View {
        let tint = SessionStatus.waitingForUser.tint
        return HStack(spacing: 8) {
            NBIconView(NBIcon.tool(event.toolName), size: 15, color: tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(tint.opacity(0.16)))
            Text(ToolStyle.action(for: event.toolName))
                .font(.manrope(13.5, weight: 680))
                .foregroundStyle(IslandPalette.primary)
                .lineLimit(1)
            if let tool = event.toolName, !tool.isEmpty {
                Text(VisibleText.escaped(tool))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08)))
                    .help(VisibleText.escaped(tool))
            }
            Spacer(minLength: 0)
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            NBIconView(.error, size: 13, color: IslandPalette.danger)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.manrope(11.5, weight: 580))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(IslandPalette.danger)
    }

    /// The model's explanation (Bash `description`, Codex `reason`): what the model says, not what runs.
    private func justification(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.white.opacity(0.16))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Пояснение модели"))
                    .font(.manrope(10.5, weight: 680))
                    .foregroundStyle(IslandPalette.tertiary)
                Text(reason)
                    .font(.manrope(12, weight: 520))
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(reason)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func buttons(_ event: AgentEvent) -> some View {
        HStack(spacing: 8) {
            Button { decide(.deny(reason: nil)) } label: {
                HStack(spacing: 6) {
                    IslandSymbol("xmark", size: 10)
                    Text(L("Запретить"))
                    KeyHint(text: "⌘N", active: keyboardActive && armed)
                }
            }
            .buttonStyle(IslandButtonStyle(kind: .destructive, height: 34))
            .modifier(ArmedOpacity(armed: armed))
            .help(L("Запретить (⌘N, пока курсор на карточке)"))

            if event.canAlwaysAllow {
                Button { decide(.allowAlways) } label: {
                    HStack(spacing: 5) {
                        NBIconView(.done, size: 15, color: .white)
                        Text(L("Всегда"))
                    }
                }
                .buttonStyle(IslandButtonStyle(kind: .secondary, height: 34, stretches: false))
                .modifier(ArmedOpacity(armed: armed))
                .help(L("Разрешить и больше не спрашивать"))
            }

            Button { decide(.allow) } label: {
                HStack(spacing: 6) {
                    IslandSymbol("checkmark", size: 10.5)
                    Text(L("Разрешить"))
                    KeyHint(text: "⌘Y", active: keyboardActive && armed)
                }
            }
            .buttonStyle(IslandButtonStyle(kind: .primary, height: 34, arming: armed ? nil : arming))
            .modifier(ArmedGlint(armed: armed))
            .help(L("Разрешить один раз (⌘Y, пока курсор на карточке)"))
        }
        .disabled(!armed)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { decide(.askInTerminal) } label: {
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        IslandSymbol("apple.terminal", size: 10)
                        Text(L("В терминал"))
                    }
                    .font(.manrope(11.5, weight: 600))
                    KeyHint(text: "⌘T", active: keyboardActive && armed)
                }
            }
            .buttonStyle(IslandButtonStyle(kind: .ghost, height: 24))
            .padding(.leading, -8)
            .disabled(!armed)
            .modifier(ArmedOpacity(armed: armed))
            .help(L("Ответить в терминале агента (⌘T, пока курсор на карточке)"))

            Spacer(minLength: 8)

            if keyboardActive {
                Image(systemName: "keyboard")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(IslandPalette.tertiary)
                    .help(L("Клавиатура у карточки: ⌘Y — разрешить, ⌘N — запретить, ⌘T — в терминал. Уведи курсор, чтобы вернуть её приложению."))
                    .transition(.opacity.animation(.easeOut(duration: 0.15).speed(IslandMotion.speed)))
            }

            WaitingClock(since: card.receivedAt)
        }
    }
}

extension PermissionCardView {
    /// See `CodeTextView.warmUp`.
    static func warmUpCodeBlock() { CodeTextView.warmUp() }
}

/// The card re-renders only when what it shows changes: `decide` (a closure bound to `card.id`, which SwiftUI
/// cannot compare) is left out, so another session's event does not rebuild the card (`.equatable()`).
extension PermissionCardView: Equatable {
    nonisolated static func == (a: PermissionCardView, b: PermissionCardView) -> Bool {
        a.card == b.card && a.total == b.total && a.queue == b.queue && a.metrics == b.metrics && a.width == b.width
            && a.armed == b.armed && a.presentedAt == b.presentedAt && a.keyboardActive == b.keyboardActive
    }
}

/// The part of the card's top that stays while the front request changes: the queue indicator (beside
/// the header on a screen without a notch) and, on a notched screen, the strip beside the camera housing.
/// Drawn over the placeholders `PermissionCardView` leaves for it, so the dots and "1 из N" animate.
struct PermissionQueueChrome: View {
    let queue: [UUID]
    let total: Int
    let metrics: IslandMetrics
    let width: CGFloat

    @Environment(\.islandEntrance) private var entrance
    @Environment(\.islandFilmQueueChange) private var filmChange

    var body: some View {
        Group {
            if metrics.style == .notch {
                // Each side fits its wing beside the camera housing: the title shortens (and at worst leaves only its
                // icon) rather than sliding under the camera.
                let wing = max(0, (width - metrics.notchWidth) / 2)
                NotchWingsLayout(notchWidth: metrics.notchWidth, minWing: wing, maxWing: wing) {
                    ViewThatFits(in: .horizontal) {
                        stripTitle(L("Нужно разрешение"))
                        stripTitle(L("Нужен ответ"))
                        stripTitle(nil)
                    }
                    .padding(.leading, PermissionCardView.horizontalPadding)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        indicator
                    }
                    .padding(.trailing, PermissionCardView.horizontalPadding)
                    .padding(.leading, 10)
                }
                .frame(height: metrics.barHeight)
                .appearAfter(PermissionCardView.sectionDelay(0, entrance: entrance, metrics: metrics),
                             style: PermissionCardView.sectionStyle(entrance))
            } else {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    indicator
                }
                .padding(.horizontal, PermissionCardView.horizontalPadding)
                .frame(height: PermissionCardView.headerHeight)
                .padding(.top, PermissionCardView.topPadding(metrics))
                .appearAfter(PermissionCardView.sectionDelay(1, entrance: entrance, metrics: metrics),
                             style: PermissionCardView.sectionStyle(entrance))
            }
        }
        .frame(width: width, alignment: .top)
        .allowsHitTesting(false)
    }

    /// The strip's title beside the camera: the waiting hourglass and `text` (nil: the icon alone).
    private func stripTitle(_ text: String?) -> some View {
        HStack(spacing: 6) {
            NBIconView(.waiting, size: 15, color: SessionStatus.waitingForUser.tint)
            if let text {
                Text(text)
                    .font(.manrope(11.5, weight: 700))
                    .foregroundStyle(SessionStatus.waitingForUser.tint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var indicator: some View {
        if total > 1 {
            QueueIndicator(queue: queue, total: total)
                .transition(.scale(scale: 0.7).combined(with: .opacity).animation(IslandMotion.pop))
        } else if let filmChange, filmChange.previous.count > 1 {
            // Filmstrips: the last queued card came to the front; the indicator leaves.
            let p = min(max(filmChange.progress, 0), 1)
            QueueIndicator(queue: filmChange.previous, total: filmChange.previous.count)
                .environment(\.islandFilmQueueChange, nil)
                .scaleEffect(1 - 0.3 * p)
                .opacity(1 - p)
        }
    }
}

/// Buttons are dimmed until the card arms, then brighten.
private struct ArmedOpacity: ViewModifier {
    let armed: Bool

    func body(content: Content) -> some View {
        content.animation(.easeOut(duration: 0.18).speed(IslandMotion.speed)) { view in
            view.opacity(armed ? 1 : 0.45)
        }
    }
}

/// "ждёт 0:20" under the card.
private struct WaitingClock: View {
    let since: Date
    @Environment(IslandClock.self) private var clock: IslandClock?

    var body: some View {
        let text = IslandFormat.clock((clock?.now ?? Date()).timeIntervalSince(since))
        HStack(spacing: 4) {
            NBIconView(.timer, size: 12, color: IslandPalette.tertiary)
            Text(L("ждёт %@", text))
                .font(.manrope(11, weight: 580, tabular: true))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(.snappy(duration: 0.24).speed(IslandMotion.speed), value: text)
        }
        .foregroundStyle(IslandPalette.tertiary)
    }
}

/// "Разрешить" glints once when the card arms.
private struct ArmedGlint: ViewModifier {
    let armed: Bool
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion

    @KeyframesBuilder<Double>
    static func keyframes(_ on: Bool) -> some Keyframes<Double> {
        KeyframeTrack {
            LinearKeyframe(on ? 1 : 0, duration: IslandMotion.t(0.08))
            CubicKeyframe(0, duration: IslandMotion.t(0.25))
        }
    }

    func body(content: Content) -> some View {
        if let filmTime {
            // Filmstrips: the card arms at `PermissionArming.seconds`.
            let t = filmTime - PermissionArming.seconds
            let glint = t > 0 ? KeyframeTimeline(initialValue: 0.0) { Self.keyframes(true) }.value(time: t) : 0
            content
                .scaleEffect(1 + 0.03 * glint)
                .shadow(color: Color.white.opacity(0.45 * glint), radius: 8)
        } else if staticRender {
            content
        } else {
            // Reduce Motion: the glow alone, no swell.
            let swell: CGFloat = reduceMotion ? 0 : 0.03
            content.keyframeAnimator(initialValue: 0.0, trigger: armed) { view, glint in
                view
                    .scaleEffect(1 + swell * glint)
                    .shadow(color: Color.white.opacity(0.45 * glint), radius: 8)
            } keyframes: { _ in
                Self.keyframes(armed)
            }
        }
    }
}

/// "1 из 3" with a dot per queued request (keyed by request, so the front dot leaves and the next one
/// widens into its place); the front one is the long dot.
private struct QueueIndicator: View {
    let queue: [UUID]
    let total: Int

    @Environment(\.islandFilmQueueChange) private var filmChange

    var body: some View {
        HStack(spacing: 7) {
            if let filmChange, filmChange.previous != queue {
                // Filmstrips: the front dot leaves, the next one widens, the count rolls (live: transitions).
                let previousQueue = filmChange.previous
                let p = min(max(filmChange.progress, 0), 1)
                filmDots(from: previousQueue, p: CGFloat(p))
                ZStack(alignment: .leading) {
                    count(previousQueue.count).opacity(1 - p).offset(y: -6 * p)
                    count(total).opacity(p).offset(y: 6 * (1 - p))
                }
                .clipped()
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(queue.prefix(5).enumerated()), id: \.element) { index, _ in
                        Capsule()
                            .fill(Color.white.opacity(index == 0 ? 0.95 : 0.3))
                            .frame(width: index == 0 ? 12 : 5, height: 5)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.2).combined(with: .opacity).animation(IslandMotion.pop),
                                removal: .scale(scale: 0, anchor: .leading).combined(with: .opacity)))
                    }
                }
                count(total)
                    .contentTransition(.numericText(value: Double(total)))
                    .animation(IslandMotion.leaf, value: total)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(0.09)))
    }

    private func count(_ n: Int) -> some View {
        Text(L("1 из %@", n))
            .font(.manrope(11, weight: 680, tabular: true))
            .monospacedDigit()
            .foregroundStyle(IslandPalette.secondary)
    }

    private func filmDots(from old: [UUID], p: CGFloat) -> some View {
        let ids = Array((old + queue.filter { !old.contains($0) }).prefix(6))
        return HStack(spacing: 3) {
            ForEach(ids, id: \.self) { id in
                let was = old.firstIndex(of: id)
                let now = queue.firstIndex(of: id)
                let wasW: CGFloat = was == 0 ? 12 : 5, nowW: CGFloat = now == 0 ? 12 : 5
                let wasO = was == 0 ? 0.95 : 0.3, nowO = now == 0 ? 0.95 : 0.3
                if was != nil, now == nil {
                    Capsule().fill(Color.white.opacity(wasO * Double(1 - p)))
                        .frame(width: wasW * (1 - p), height: 5)
                        .scaleEffect(1 - p, anchor: .leading)
                } else if was == nil {
                    Capsule().fill(Color.white.opacity(nowO * Double(p)))
                        .frame(width: nowW, height: 5)
                        .scaleEffect(0.2 + 0.8 * p)
                } else {
                    Capsule().fill(Color.white.opacity(wasO + (nowO - wasO) * Double(p)))
                        .frame(width: wasW + (nowW - wasW) * p, height: 5)
                }
            }
        }
    }
}

/// Monospaced, selectable text of what is being approved, shown whole: grows up to `maxLines`, then
/// scrolls. Backed by an `NSTextView`, which lays out only what is visible, so even a huge patch
/// stays cheap. Every character is laid out left to right in logical order (a bidi override), so
/// right-to-left text cannot visually reorder a command.
///
/// The silhouette's mask does not cut an AppKit view, so the block comes in as a snapshot of the very
/// same text view (drawn once, off screen: `CodeTextView.snapshot`), an image that the silhouette masks
/// and that reveals with the card's other sections. Once the card stands still the live text view is
/// mounted under it, hidden by it (so the entrance's scaling never reaches its frames, and it is laid out
/// and drawn before it shows), then takes over (the same pixels, so the swap does not show) when the
/// silhouette has settled around it (`IslandMotion.appKitSwap`); from then on the text is selectable
/// and scrolls. A card that starts leaving before that keeps its snapshot, which leaves with it.
/// Previews, which cannot draw AppKit views, show the snapshot.
private struct CodeBlock: View {
    let text: String
    let width: CGFloat
    /// The block's reveal, as the card's sections have theirs.
    let delay: Double
    let style: AppearStyle
    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.displayScale) private var displayScale
    @State private var stage = Stage.snapshot
    /// The card began to leave (`ExitWatch`).
    @State private var leaving = false

    private enum Stage: Comparable {
        /// The snapshot shows.
        case snapshot
        /// The live view is mounted under it, invisible.
        case mounted
        /// The live view is visible but still covered by the snapshot for a frame or two, so it is surely
        /// on screen when the snapshot goes.
        case live
        /// The snapshot is gone: the live view shows.
        case settled
    }

    /// The live view is mounted this long before it shows.
    private static let mountLead = 0.05

    static let background = Color(white: 0.065)
    static let cornerRadius: CGFloat = 11
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        let layout = CodeTextView.measure(text, width: width)
        let still = staticRender || filmTime != nil
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                if !still, stage >= .mounted {
                    // Under the snapshot, whose opaque block hides it until the snapshot goes: it is on screen
                    // before it is seen, and the two never draw their text over each other.
                    ZStack(alignment: .topLeading) {
                        Self.shape.fill(Self.background)
                        LiveCodeBlock(text: text, scrolls: layout.overflows, live: stage >= .live)
                    }
                    .frame(width: width, height: layout.height)
                }
                ZStack(alignment: .topLeading) {
                    // Stills and films always draw the snapshot (a film's page is first laid out live, so the swap
                    // to the live view may already have run in wall-clock time; the live view never draws there).
                    if still || stage != .settled {
                        Self.shape.fill(Self.background)
                        snapshot(layout, scale: still ? 2 : displayScale)
                            .modifier(CodeBlockChrome(overflows: layout.overflows))
                            // Filmstrips: a card that has stood this long shows the live view, which leaves first.
                            .modifier(AppKitExit(active: still && (filmTime ?? 0) >= showTime))
                    }
                }
                .frame(width: width, height: layout.height)
                .appearAfter(delay, style: style)
                .background { if !still { ExitWatch(leaving: $leaving) } }
                // The live view under it takes the clicks.
                .allowsHitTesting(false)
            }
            if layout.overflows {
                // The overlay scroller hides itself; say explicitly that part of the request is below.
                Label {
                    Text(Self.overflowText(text))
                } icon: {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 9.5, weight: .semibold))
                }
                    .font(.manrope(10.5, weight: 580))
                    .foregroundStyle(IslandPalette.tertiary)
                    .appearAfter(delay, style: style)
            }
        }
        .task {
            guard !still else { return }
            await swapToLive()
        }
    }

    /// The block's own reveal is over (its offset below a tenth of a point) this long after its delay.
    private static let revealSettle = 0.2

    /// When the live view shows, after the card mounted.
    private var showTime: Double { max(IslandMotion.appKitSwap, delay + Self.revealSettle) }

    private func swapToLive() async {
        guard stage == .snapshot else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        let show = showTime
        do {
            try await Task.sleep(for: IslandMotion.delay(show - Self.mountLead))
            guard !leaving else { return }
            withTransaction(instant) { stage = .mounted }
            try await Task.sleep(for: IslandMotion.delay(Self.mountLead))
            guard !leaving else { return }
            withTransaction(instant) { stage = .live }
            try await Task.sleep(for: IslandMotion.delay(0.05))
            guard !leaving else { return }
            withTransaction(instant) { stage = .settled }
        } catch {
            return
        }
    }

    @ViewBuilder
    private func snapshot(_ layout: (height: CGFloat, overflows: Bool), scale: CGFloat) -> some View {
        if let image = CodeTextView.snapshot(text, width: width, height: layout.height, scale: scale) {
            Image(decorative: image, scale: scale)
                .frame(width: width, height: layout.height, alignment: .topLeading)
        } else {
            Color.clear.frame(width: width, height: layout.height)
        }
    }

    private static func overflowText(_ text: String) -> String {
        let lines = text.utf8.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        guard lines > CodeTextView.maxLines else { return L("Показано не всё — прокрути вниз") }
        return L("Показано %@ из %@ %@ — прокрути вниз", CodeTextView.maxLines, lines, IslandFormat.plural(lines, "строки", "строк", "строк"))
    }
}

/// What the block draws over its text, the snapshot's or the live view's: the rounded cut, the fade at the
/// bottom of a block that scrolls, the hairline border.
private struct CodeBlockChrome: ViewModifier {
    let overflows: Bool

    func body(content: Content) -> some View {
        content
            .clipShape(CodeBlock.shape)
            .overlay(alignment: .bottom) {
                if overflows {
                    // The cut line fades out instead of stopping mid-glyph.
                    LinearGradient(colors: [CodeBlock.background.opacity(0), CodeBlock.background],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: CodeBlock.cornerRadius,
                                                          bottomTrailingRadius: CodeBlock.cornerRadius, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .overlay(CodeBlock.shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6).allowsHitTesting(false))
    }
}

/// The live text view: invisible and ignoring the mouse until it takes over from the snapshot.
private struct LiveCodeBlock: View {
    let text: String
    let scrolls: Bool
    let live: Bool

    var body: some View {
        // Its own layer is rounded too (`CodeTextView`): an AppKit view is not always cut by SwiftUI's clip shapes.
        CodeTextView(text: text, scrolls: scrolls, live: live)
            .modifier(CodeBlockChrome(overflows: scrolls))
            .opacity(live ? 1 : 0)
            .modifier(AppKitExit(active: true))
            .allowsHitTesting(live)
    }
}

/// An AppKit view is not masked by the silhouette: it is gone in the first half of an exit. Only this
/// modifier reads the exit's progress, which changes every frame of an exit.
private struct AppKitExit: ViewModifier {
    let active: Bool
    @Environment(\.islandExitProgress) private var exitProgress

    func body(content: Content) -> some View {
        content.opacity(active ? 1 - min(1, 2 * exitProgress) : 1)
    }
}

/// Tells the block once the card has begun to leave (it reads the exit's progress, which changes every
/// frame of an exit, so nothing bigger has to).
private struct ExitWatch: View {
    @Binding var leaving: Bool
    @Environment(\.islandExitProgress) private var exitProgress

    var body: some View {
        Color.clear
            .onChange(of: exitProgress > 0) { _, exiting in
                if exiting, !leaving { leaving = true }
            }
    }
}

private struct CodeTextView: NSViewRepresentable {
    let text: String
    let scrolls: Bool
    /// False while the view waits, invisible, to take over from the snapshot; it shows unscrolled.
    var live = true

    static let maxLines = 8
    private static let fontSize: CGFloat = 11.5
    private static let lineSpacing: CGFloat = 1
    private static let inset = NSSize(width: 11, height: 8)
    private static var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    private static func attributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.baseWritingDirection = .leftToRight
        paragraph.alignment = .left
        let override = NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.override.rawValue
        return [
            .font: font,
            .foregroundColor: NSColor(white: 1, alpha: 0.9),
            .paragraphStyle: paragraph,
            .writingDirection: [NSNumber(value: override)],
        ]
    }

    final class Coordinator {
        var text: String?
        var shown = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView() }

    /// A body longer than this (UTF-8 bytes) fills in two steps: `firstFill` characters (far more than the block
    /// shows) in the card's first layout pass, the whole text on the next turn of the run loop.
    private static let deferredFill = 64 * 1024
    private static let firstFill = 16_000

    /// Builds and draws one throwaway block off screen, as a card's snapshot is drawn (`render`): TextKit's
    /// and the first text view's set-up (~40 ms) then happens once after launch, not in the first card's
    /// opening frames.
    static func warmUp() {
        _ = measure("warm up", width: 400)
        _ = render("rm -rf .build && swift build -c release\nls -la", width: 400, height: 80, scale: 2)
    }

    private static func fill(_ textView: NSTextView, _ text: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes()))
    }

    private struct SnapshotKey: Hashable {
        let text: String
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
    }

    private static var snapshots: [SnapshotKey: CGImage] = [:]

    /// The block as the live text view shows it when it takes over (unscrolled; the overlay scroller
    /// shows only while scrolling), for the card's entrance (`CodeBlock`). The last few (up to ~1 MB each)
    /// are kept: the card asks again whenever it re-renders, the next card of a queue has its own.
    static func snapshot(_ text: String, width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage? {
        let key = SnapshotKey(text: text, width: width, height: height, scale: scale)
        if let image = snapshots[key] { return image }
        guard let image = render(text, width: width, height: height, scale: scale) else { return nil }
        if snapshots.count >= 3 { snapshots.removeAll() }
        snapshots[key] = image
        return image
    }

    /// Draws the top of the block off screen at `scale`, with a text view built and drawn like the live one.
    /// Only the lines it can show are laid out (`prefix(of:)`, as `measure` does), so a huge body costs no
    /// more than a short one.
    private static func render(_ text: String, width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage? {
        let pixelsWide = Int((width * scale).rounded(.up)), pixelsHigh = Int((height * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let scroll = makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: height)
        guard let textView = scroll.documentView as? NSTextView else { return nil }
        fill(textView, prefix(of: text, lines: maxLines + 1, width: max(width - 2 * inset.width, 40)))
        scroll.tile()
        textView.sizeToFit()
        scroll.layoutSubtreeIfNeeded()
        textView.scroll(.zero)
        context.scaleBy(x: scale, y: scale)
        scroll.displayIgnoringOpacity(scroll.bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
        return context.makeImage()
    }

    private static func makeScrollView() -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = CodeNSTextView(frame: .zero, textContainer: container)
        textView.storage = storage
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.22)]
        textView.setAccessibilityLabel(L("Что будет разрешено"))

        let scroll = CodeScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.appearance = NSAppearance(named: .darkAqua)
        scroll.documentView = textView
        // Clipped by the block's own rounded rect (text and overlay scroller alike), not a rectangle.
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = CodeBlock.cornerRadius
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.masksToBounds = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.hasVerticalScroller = scrolls
        scroll.verticalScrollElasticity = scrolls ? .automatic : .none
        guard let textView = scroll.documentView as? CodeNSTextView else { return }
        if context.coordinator.text != text {
            context.coordinator.text = text
            if text.utf8.count > Self.deferredFill {
                // The visible part now; the rest never lands in the card's opening frame.
                Self.fill(textView, String(text.prefix(Self.firstFill)))
                textView.pendingText = text
                DispatchQueue.main.async { [weak textView] in
                    MainActor.assumeIsolated {
                        guard let textView, let full = textView.pendingText else { return }
                        textView.pendingText = nil
                        Self.fill(textView, full)
                    }
                }
            } else {
                textView.pendingText = nil
                Self.fill(textView, text)
            }
            textView.scroll(.zero)
        }
        if live, !context.coordinator.shown {
            // It shows at the top, exactly where the snapshot stood, whatever its set-up (sized from nothing,
            // filled, laid out) left the scroll position at.
            context.coordinator.shown = true
            textView.scroll(.zero)
        }
    }

    /// Height of the block (insets included) and whether it scrolls. Lays out only a prefix that is
    /// sure to hold more than `maxLines` lines, so a huge body costs no more than a short one.
    static func measure(_ text: String, width: CGFloat) -> (height: CGFloat, overflows: Bool) {
        let textWidth = max(width - 2 * inset.width, 40)
        let sample = prefix(of: text, lines: maxLines + 1, width: textWidth)
        let storage = NSTextStorage(string: sample.isEmpty ? " " : sample, attributes: attributes())
        let container = NSTextContainer(size: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        var fragments: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, stop in
            fragments.append(rect)
            if fragments.count > maxLines { stop.pointee = true }
        }
        let lineHeight = layout.defaultLineHeight(for: font) + lineSpacing
        let overflows = fragments.count > maxLines
        // When it scrolls, half of the next line peeks out as a hint.
        let content = overflows
            ? fragments[maxLines - 1].maxY + lineHeight / 2
            : max(layout.usedRect(for: container).height, lineHeight)
        return (ceil(content) + 2 * inset.height, overflows)
    }

    /// The whole text, or a prefix long enough to wrap to more than `lines` lines: it stops after
    /// `lines` line breaks, or after more characters than `lines` full lines can hold (a monospaced
    /// glyph is wider than half the font size).
    private static func prefix(of text: String, lines: Int, width: CGFloat) -> String {
        let perLine = Int(width / (fontSize * 0.5)) + 1
        let limit = perLine * lines * 2
        var index = text.startIndex
        var count = 0, breaks = 0
        while index < text.endIndex, count < limit {
            if text[index].isNewline {
                breaks += 1
                if breaks > lines { break }
            }
            count += 1
            index = text.index(after: index)
        }
        return String(text[..<index])
    }
}

private final class CodeNSTextView: NSTextView {
    /// A hand-built TextKit 1 stack: the text view does not own its text storage.
    var storage: NSTextStorage?
    /// The whole of a huge body, filled in on the run loop's next turn (its prefix is shown meanwhile).
    var pendingText: String?

    /// Select text with the first click even though the panel is not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class CodeScrollView: NSScrollView {
    /// Keeps the text view exactly as wide as the visible area so it wraps instead of scrolling sideways.
    override func tile() {
        super.tile()
        guard let document = documentView, document.frame.width != contentSize.width else { return }
        document.setFrameSize(NSSize(width: contentSize.width, height: document.frame.height))
    }
}
