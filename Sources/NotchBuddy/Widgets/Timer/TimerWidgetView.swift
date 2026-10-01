import SwiftUI
import NotchBuddyCore

/// The timer widget ("островок" Таймер) for a page of the open island.
///
/// Top to bottom: a header (beside the camera on a notched screen); a hero card — the soonest timer on a big
/// dial with its controls, a green "Готово" card with a celebration right after one ends, or, with nothing
/// running, a setup dial for a custom time; a row per other timer; the presets (1 / 5 / 10 / 25 мин) and the
/// custom picker. Sections cascade in as the silhouette uncovers them (`appearAfter`); timers come and go with
/// springs; starting one sends a ripple through its preset, "+1 мин" floats up from the dial.
struct TimerWidgetView: View {
    let store: TimerStore
    let metrics: IslandMetrics
    var width: CGFloat = 492
    /// The ⚙️ in the header (nil hides it).
    var openSettings: (() -> Void)?
    /// Its own title row (off on the island, where the tab strip names the tab).
    var showsHeader = true

    static let sidePadding: CGFloat = 10
    /// Rows past this many other timers collapse into "и ещё N".
    static let maxRows = 4

    var body: some View {
        let ordered = store.ordered
        let finish = store.recentFinish
        let hero: TimerItem? = finish == nil ? ordered.first : nil
        let others = Array(ordered.filter { $0.id != hero?.id }.prefix(Self.maxRows))
        let hidden = max(0, ordered.count - (hero == nil ? 0 : 1) - others.count)
        VStack(spacing: 8) {
            if showsHeader {
                header(ordered)
                    .appearAfter(0.02, style: .header)
            }
            ZStack {
                if let finish {
                    TimerDoneCard(store: store, finish: finish)
                        .id("done-\(finish.id)")
                        .transition(Self.heroSwap)
                } else if let hero {
                    TimerHeroCard(store: store, timer: hero)
                        .id("hero-\(hero.id)")
                        .transition(Self.heroSwap)
                } else {
                    TimerSetupCard(store: store)
                        .id("setup")
                        .transition(Self.heroSwap)
                }
            }
            .animation(GadgetMotion.snap, value: finish?.id)
            .animation(GadgetMotion.snap, value: hero?.id)
            .padding(.horizontal, Self.sidePadding)
            .appearAfter(0.04, style: .section)
            if !others.isEmpty || hidden > 0 {
                VStack(spacing: 6) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, timer in
                        TimerRow(store: store, timer: timer)
                            .transition(Self.rowSwap)
                            .appearAfter(0.06 + 0.022 * Double(index), style: .row)
                    }
                    if hidden > 0 {
                        Text(L("и ещё %@ %@", hidden, IslandFormat.plural(hidden, "таймер", "таймера", "таймеров")))
                            .font(GadgetFont.font(11, .semibold))
                            .foregroundStyle(IslandPalette.tertiary)
                            .contentTransition(.numericText(value: Double(hidden)))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 2)
                    }
                }
                .animation(GadgetMotion.bouncy, value: others.map(\.id))
                .padding(.horizontal, Self.sidePadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)).animation(GadgetMotion.snap))
            }
            TimerQuickStart(store: store, showsCustom: hero != nil || finish != nil)
                .padding(.horizontal, Self.sidePadding + 2)
                .padding(.top, 4)
                .appearAfter(0.08 + 0.022 * Double(others.count), style: .section)
        }
        .padding(.bottom, 14)
        .frame(width: width)
        .animation(GadgetMotion.snap, value: others.isEmpty)
        .timerTicking(store)
    }

    static var heroSwap: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)).animation(GadgetMotion.snap.delay(0.05)),
                    removal: .opacity.combined(with: .scale(scale: 1.02)).animation(.easeOut(duration: 0.12).speed(IslandMotion.speed)))
    }

    static var rowSwap: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .top)).combined(with: .offset(y: -6)),
                    removal: .opacity.combined(with: .scale(scale: 0.86)).combined(with: .offset(x: 30)))
    }

    // MARK: Header

    private func header(_ ordered: [TimerItem]) -> some View {
        let running = ordered.filter(\.isRunning).count
        let paused = ordered.count - running
        let notch = metrics.style == .notch
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                GadgetIconTile(glyph: .stopwatch, tint: TimerPalette.coral, size: 22)
                Text(L("Таймер"))
                    .font(GadgetFont.font(13.5, .bold))
                    .foregroundStyle(IslandPalette.primary)
                if !ordered.isEmpty {
                    Text("\(ordered.count)")
                        .font(GadgetFont.font(11, .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.85))
                        .contentTransition(.numericText(value: Double(ordered.count)))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 19, minHeight: 18)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .transition(.scale(scale: 0.5).combined(with: .opacity).animation(GadgetMotion.bouncy))
                }
            }
            Spacer(minLength: notch ? metrics.notchWidth + 12 : 8)
            HStack(spacing: 6) {
                // Beside a notch the wing is narrow: just the counts.
                if running > 0 {
                    TimerSummaryChip(text: notch ? "\(running)" : "\(running) \(IslandFormat.plural(running, "идёт", "идут", "идут"))",
                                     tint: TimerPalette.coral, live: true)
                }
                if paused > 0 {
                    TimerSummaryChip(text: notch ? "\(paused)" : L("%@ на паузе", paused), tint: TimerPalette.paused, live: false,
                                     glyph: notch ? .pause : nil)
                }
                if let openSettings {
                    GadgetSettingsButton(action: openSettings)
                }
            }
            .animation(GadgetMotion.snap, value: running)
            .animation(GadgetMotion.snap, value: paused)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: notch ? metrics.barHeight : 44)
        .padding(.top, notch ? 0 : 2)
    }
}

/// "2 идут" with a live dot.
struct TimerSummaryChip: View {
    let text: String
    let tint: GadgetTint
    let live: Bool
    /// In place of the dot.
    var glyph: GadgetGlyph?

    var body: some View {
        HStack(spacing: 5) {
            if let glyph {
                GadgetIcon(glyph: glyph, size: 9, color: tint.hi)
            } else {
                Circle()
                    .fill(tint.hi)
                    .frame(width: 5, height: 5)
                    .modifier(Breathing(active: live))
            }
            Text(text)
                .font(GadgetFont.font(11, .semibold))
                .foregroundStyle(tint.hi.opacity(0.95))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(tint.lo.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.hi.opacity(0.16), lineWidth: 0.6))
        .fixedSize()
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }
}

/// A round ⚙️ that turns a little under the pointer.
struct GadgetSettingsButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.white : IslandPalette.secondary)
                .rotationEffect(.degrees(hovering ? 60 : 0))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(GadgetPressStyle(scale: 0.88))
        .onHover { inside in withAnimation(GadgetMotion.hover) { hovering = inside } }
        .help(L("Настройки"))
    }
}

// MARK: - Hero

/// The soonest timer on a big dial: name, when it ends, pause / +1 мин / cancel.
struct TimerHeroCard: View {
    let store: TimerStore
    let timer: TimerItem

    var body: some View {
        let now = store.now
        let urgent = timer.isRunning && timer.displaySeconds(at: now) <= 10
        let tint = urgent ? TimerPalette.urgent : store.tint(for: timer)
        HStack(spacing: 18) {
            TimerDial(timer: timer, now: now, tint: store.tint(for: timer))
                .overlay { TimerEventEffects(store: store, id: timer.id, tint: tint, size: 96) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    if timer.label == TimerPreset.standard.last?.title {
                        TomatoIcon(size: 16)
                    }
                    Text(L(timer.label))
                        .font(GadgetFont.font(17, .bold))
                        .foregroundStyle(IslandPalette.primary)
                        .lineLimit(1)
                }
                Text(subtitle(now))
                    .font(GadgetFont.font(12.5, .medium))
                    .foregroundStyle(timer.isPaused ? TimerPalette.paused.hi.opacity(0.8) : IslandPalette.secondary)
                    .contentTransition(.interpolate)
                    .animation(GadgetMotion.fade, value: timer.isPaused)
                    .lineLimit(1)
                    .padding(.top, 3)
                Spacer(minLength: 10)
                HStack(spacing: 8) {
                    GadgetButton(kind: .primary(timer.isRunning ? tint : TimerPalette.done), height: 32,
                                 action: { store.toggle(timer.id) }) {
                        HStack(spacing: 6) {
                            TimerPlayPause(running: timer.isRunning, size: 12, color: Color.black.opacity(0.85))
                            Text(timer.isRunning ? L("Пауза") : L("Продолжить"))
                                .font(GadgetFont.font(12.5, .bold))
                                .contentTransition(.interpolate)
                        }
                        .animation(GadgetMotion.snap, value: timer.isRunning)
                    }
                    GadgetButton(kind: .secondary, height: 32, action: { store.addMinute(timer.id) }) {
                        Text(L("+1 мин"))
                            .font(GadgetFont.font(12.5, .bold))
                    }
                    GadgetButton(kind: .round, height: 32, action: { store.cancel(timer.id) }) {
                        GadgetIcon(glyph: .xmark, size: 13, color: .white.opacity(0.9), weight: 2.4)
                    }
                    .help(L("Отменить таймер"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .padding(14)
        .frame(height: 124)
        .gadgetCard(radius: 18, tint: timer.isRunning ? tint.lo : nil)
        .animation(GadgetMotion.fade, value: urgent)
    }

    private func subtitle(_ now: Moment) -> String {
        if timer.isPaused { return L("на паузе · осталось %@", TimerFormat.length(timer.remaining(at: now))) }
        let seconds = timer.displaySeconds(at: now)
        if seconds <= 10 { return L("почти готово · ещё %@\u{00A0}с", seconds) }
        guard let end = timer.endsAt(now) else { return "" }
        return L("закончится в %@", TimerClockFormat.time(end))
    }
}

/// Wall-clock times ("15:42"), 24-hour.
@MainActor
enum TimerClockFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "H:mm"
        return f
    }()

    static func time(_ date: Date) -> String { formatter.string(from: date) }
}

/// One-shot effects on a dial: a ripple when its timer starts, "+1:00" floating up when it is extended. A dial
/// mounted by the start itself (a new hero, a new row) plays the ripple as it appears.
struct TimerEventEffects: View {
    let store: TimerStore
    let id: UUID
    let tint: GadgetTint
    let size: CGFloat

    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandStaticRender) private var staticRender
    @State private var ripples = 0
    @State private var extensions = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.hi, lineWidth: 2)
                .frame(width: size, height: size)
                .keyframeAnimator(initialValue: RippleValue(), trigger: ripples) { content, v in
                    content.scaleEffect(v.scale).opacity(v.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(0.9, duration: 0.001)
                        CubicKeyframe(1.35, duration: IslandMotion.t(0.6))
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0.8, duration: 0.001)
                        CubicKeyframe(0, duration: IslandMotion.t(0.6))
                    }
                }
            Text("+1:00")
                .font(GadgetFont.font(13, .heavy))
                .foregroundStyle(tint.hi)
                .fixedSize()
                .keyframeAnimator(initialValue: RippleValue(scale: 0.6, opacity: 0, y: 0), trigger: extensions) { content, v in
                    content.scaleEffect(v.scale).opacity(v.opacity).offset(y: v.y)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(0.6, duration: 0.001)
                        SpringKeyframe(1.1, duration: IslandMotion.t(0.25), spring: IslandMotion.kspring(0.25, 0.55))
                        LinearKeyframe(1, duration: IslandMotion.t(0.6))
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(1, duration: IslandMotion.t(0.08))
                        LinearKeyframe(1, duration: IslandMotion.t(0.45))
                        CubicKeyframe(0, duration: IslandMotion.t(0.35))
                    }
                    KeyframeTrack(\.y) {
                        LinearKeyframe(-size * 0.28, duration: 0.001)
                        CubicKeyframe(-size * 0.62, duration: IslandMotion.t(0.88))
                    }
                }
        }
        .allowsHitTesting(false)
        .opacity(reduceMotion || staticRender ? 0 : 1)
        .onAppear {
            // Mounted by its own start a moment ago: the ripple still belongs to it.
            if let event = store.lastEvent, event.id == id, event.kind == .started,
               AppClock.monotonicSeconds() - event.at < 0.6 {
                ripples &+= 1
            }
        }
        .onChange(of: store.lastEvent) { _, event in
            guard let event, event.id == id else { return }
            switch event.kind {
            case .started: ripples &+= 1
            case .extended: extensions &+= 1
            default: break
            }
        }
    }
}

struct RippleValue {
    var scale: CGFloat = 1
    var opacity: Double = 0
    var y: CGFloat = 0
}

// MARK: - Setup

/// Nothing running: a dial showing the custom time, − / + and "Старт".
struct TimerSetupCard: View {
    let store: TimerStore

    var body: some View {
        let seconds = store.preferences.customSeconds
        HStack(spacing: 18) {
            ZStack {
                DialTicks(inset: 7.5 + 3.5)
                    .stroke(Color.white.opacity(0.13), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                // A kitchen timer: the custom time as a share of an hour, twisting as it changes.
                Color.clear
                    .modifier(TimerRingFace(fraction: min(seconds / 3600, 1), tint: TimerPalette.coral,
                                            size: 96, lineWidth: 7.5, head: true, glow: true))
                    .animation(GadgetMotion.bouncy, value: seconds)
                VStack(spacing: 1) {
                    TimerStepperDigits(seconds: seconds, size: seconds >= 3600 ? 15.5 : 20.5)
                    Text(L("своё время"))
                        .font(GadgetFont.font(9.6, .semibold))
                        .foregroundStyle(IslandPalette.tertiary)
                }
                .offset(y: 2)
            }
            .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Новый таймер"))
                    .font(GadgetFont.font(17, .bold))
                    .foregroundStyle(IslandPalette.primary)
                Text(L("Выбери время или начни с пресета"))
                    .font(GadgetFont.font(12.5, .medium))
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(1)
                    .padding(.top, 3)
                Spacer(minLength: 10)
                HStack(spacing: 8) {
                    TimerRepeatButton(action: { store.stepCustom(up: false) }) {
                        GadgetIcon(glyph: .minus, size: 13, color: .white.opacity(0.9), weight: 2.4)
                    }
                    .help(L("Меньше"))
                    TimerRepeatButton(action: { store.stepCustom(up: true) }) {
                        GadgetIcon(glyph: .plus, size: 13, color: .white.opacity(0.9), weight: 2.4)
                    }
                    .help(L("Больше"))
                    GadgetButton(kind: .primary(TimerPalette.coral), height: 32, action: { store.startCustom() }) {
                        HStack(spacing: 6) {
                            GadgetIcon(glyph: .play, size: 11, color: Color.black.opacity(0.85))
                            Text(L("Старт"))
                                .font(GadgetFont.font(12.5, .bold))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .padding(14)
        .frame(height: 124)
        .gadgetCard(radius: 18)
    }
}

/// The custom time rolling up or down with the direction of the change.
struct TimerStepperDigits: View {
    let seconds: TimeInterval
    let size: CGFloat
    @State private var down = false

    var body: some View {
        Text(TimerFormat.clock(Int(seconds.rounded())))
            .font(GadgetFont.font(size, .bold))
            .monospacedDigit()
            .foregroundStyle(IslandPalette.primary)
            .contentTransition(.numericText(countsDown: down))
            .animation(GadgetMotion.digits, value: seconds)
            .lineLimit(1)
            .fixedSize()
            .onChange(of: seconds) { old, new in down = new < old }
    }
}

/// A round − / + that repeats while held: after 0.4 s, then faster.
struct TimerRepeatButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    var size: CGFloat = 32

    @State private var hovering = false
    @State private var pressed = false
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        label
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(pressed ? 0.2 : hovering ? 0.16 : 0.09)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
            .scaleEffect(pressed ? 0.9 : hovering ? 1.04 : 1)
            .animation(IslandMotion.press.animation, value: pressed)
            .animation(GadgetMotion.hover, value: hovering)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        repeater = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(420))
                            var interval = 110
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(for: .milliseconds(interval))
                                interval = max(45, interval - 6)
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
            .onDisappear { repeater?.cancel() }
    }
}

// MARK: - Done

/// Right after a timer ends: the celebration on the dial, "Готово", +1 мин / Повторить / Ок.
struct TimerDoneCard: View {
    let store: TimerStore
    let finish: TimerFinish

    var body: some View {
        HStack(spacing: 18) {
            TimerCelebration(size: 96, bursts: store.preferences.celebrate, episode: finish.id.uuidString)
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Готово!"))
                    .font(GadgetFont.font(17, .bold))
                    .foregroundStyle(TimerPalette.done.hi)
                Text("\(L(finish.label)) · \(TimerFormat.length(finish.duration))")
                    .font(GadgetFont.font(12.5, .medium))
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(1)
                    .padding(.top, 3)
                Spacer(minLength: 10)
                HStack(spacing: 8) {
                    GadgetButton(kind: .primary(TimerPalette.done), height: 32, action: { store.dismissFinish() }) {
                        Text(L("Ок"))
                            .font(GadgetFont.font(12.5, .bold))
                            .frame(minWidth: 26)
                    }
                    GadgetButton(kind: .secondary, height: 32, action: { store.snooze(finish) }) {
                        Text(L("+1 мин"))
                            .font(GadgetFont.font(12.5, .bold))
                    }
                    GadgetButton(kind: .secondary, height: 32, action: { store.again(finish) }) {
                        HStack(spacing: 5) {
                            GadgetIcon(glyph: .restart, size: 12, color: .white.opacity(0.9), weight: 2.4)
                            Text(L("Повторить"))
                                .font(GadgetFont.font(12.5, .bold))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .padding(14)
        .frame(height: 124)
        .gadgetCard(radius: 18, tint: TimerPalette.done.lo)
    }
}

// MARK: - Rows

/// Another timer: a small ring, its name and end, the time, pause and cancel.
struct TimerRow: View {
    let store: TimerStore
    let timer: TimerItem
    @State private var hovering = false

    var body: some View {
        let now = store.now
        let tint = store.tint(for: timer)
        let seconds = timer.displaySeconds(at: now)
        let urgent = timer.isRunning && seconds <= 10
        HStack(spacing: 11) {
            TimerRing(timer: timer, now: now, tint: urgent ? TimerPalette.urgent : (timer.isRunning ? tint : TimerPalette.paused),
                      size: 26, lineWidth: 3.6, showsHead: true)
                .overlay { TimerEventEffects(store: store, id: timer.id, tint: tint, size: 26) }
            VStack(alignment: .leading, spacing: 1) {
                Text(L(timer.label))
                    .font(GadgetFont.font(13, .bold))
                    .foregroundStyle(IslandPalette.primary)
                    .lineLimit(1)
                Text(detail(now))
                    .font(GadgetFont.font(11, .medium))
                    .foregroundStyle(IslandPalette.tertiary)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: 6)
            TimerDigits(seconds: seconds, size: 17, urgent: urgent, weight: .bold,
                        color: timer.isRunning ? .white : Color.white.opacity(0.55))
                .modifier(Breathing(active: timer.isPaused))
            HStack(spacing: 6) {
                GadgetButton(kind: .roundTinted(timer.isRunning ? tint : TimerPalette.done), height: 26,
                             action: { store.toggle(timer.id) }) {
                    TimerPlayPause(running: timer.isRunning, size: 10.5, color: timer.isRunning ? tint.hi : TimerPalette.done.hi)
                }
                .help(timer.isRunning ? L("Пауза") : L("Продолжить"))
                GadgetButton(kind: .round, height: 26, action: { store.cancel(timer.id) }) {
                    GadgetIcon(glyph: .xmark, size: 10.5, color: .white.opacity(0.85), weight: 2.5)
                }
                .help(L("Отменить"))
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .frame(height: 46)
        .gadgetCard(radius: 14, hovering: hovering)
        .onHover { inside in withAnimation(GadgetMotion.hover) { hovering = inside } }
    }

    private func detail(_ now: Moment) -> String {
        if timer.isPaused { return L("на паузе") }
        return timer.endsAt(now).map { L("до %@", TimerClockFormat.time($0)) } ?? ""
    }
}

// MARK: - Quick start

/// "Быстрый старт": 1 / 5 / 10 / 25 мин, and (when the hero card is busy) the custom picker.
struct TimerQuickStart: View {
    let store: TimerStore
    var showsCustom: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GadgetCaption(text: L("Быстрый старт"))
                .padding(.leading, 8)
            HStack(spacing: 8) {
                ForEach(TimerPreset.standard) { preset in
                    TimerPresetChip(preset: preset, store: store)
                }
            }
            if showsCustom {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        TimerRepeatButton(action: { store.stepCustom(up: false) }, label: {
                            GadgetIcon(glyph: .minus, size: 11, color: .white.opacity(0.9), weight: 2.5)
                        }, size: 28)
                        TimerStepperDigits(seconds: store.preferences.customSeconds, size: 16)
                            .frame(minWidth: 62)
                        TimerRepeatButton(action: { store.stepCustom(up: true) }, label: {
                            GadgetIcon(glyph: .plus, size: 11, color: .white.opacity(0.9), weight: 2.5)
                        }, size: 28)
                    }
                    .padding(3)
                    .background(Capsule().fill(Color.white.opacity(0.05)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
                    Text(L("своё время"))
                        .font(GadgetFont.font(11.5, .medium))
                        .foregroundStyle(IslandPalette.tertiary)
                    Spacer(minLength: 8)
                    GadgetButton(kind: .primary(TimerPalette.coral), height: 32, action: { store.startCustom() }) {
                        HStack(spacing: 6) {
                            GadgetIcon(glyph: .play, size: 11, color: Color.black.opacity(0.85))
                            Text(L("Старт"))
                                .font(GadgetFont.font(12.5, .bold))
                        }
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .offset(y: -6)).animation(GadgetMotion.snap))
            }
        }
    }
}

/// A preset: the minutes big, its name small; a tomato on the pomodoro. Lifts and glows in its hue under the
/// pointer; a click sends a ripple through it as the timer starts.
struct TimerPresetChip: View {
    let preset: TimerPreset
    let store: TimerStore
    @State private var hovering = false
    @State private var fired = 0

    var body: some View {
        let tint = preset.minutes == 25 ? TimerPalette.tomato : TimerPalette.coral
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button {
            fired &+= 1
            store.start(preset: preset)
        } label: {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(preset.minutes)")
                        .font(GadgetFont.font(22, .heavy))
                        .foregroundStyle(hovering ? tint.hi : IslandPalette.primary)
                    Text(L("мин"))
                        .font(GadgetFont.font(11, .bold))
                        .foregroundStyle(IslandPalette.tertiary)
                }
                Text(L(preset.title))
                    .font(GadgetFont.font(10.5, .semibold))
                    .foregroundStyle(IslandPalette.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background {
                ZStack {
                    shape.fill(Color.white.opacity(hovering ? 0.1 : 0.05))
                }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(hovering ? 0.22 : 0.08), lineWidth: 0.8)
            }
            .overlay(alignment: .topTrailing) {
                if preset.minutes == 25 {
                    TomatoIcon(size: 15)
                        .rotationEffect(.degrees(hovering ? 14 : 0))
                        .offset(x: -7, y: 6)
                }
            }
            .overlay {
                shape
                    .strokeBorder(tint.hi, lineWidth: 1.5)
                    .keyframeAnimator(initialValue: RippleValue(), trigger: fired) { content, v in
                        content.scaleEffect(v.scale).opacity(v.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1, duration: 0.001)
                            CubicKeyframe(1.18, duration: IslandMotion.t(0.45))
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0.9, duration: 0.001)
                            CubicKeyframe(0, duration: IslandMotion.t(0.45))
                        }
                    }
            }
            .offset(y: hovering ? -1.5 : 0)
            .contentShape(shape)
        }
        .buttonStyle(GadgetPressStyle(scale: 0.93))
        .onHover { inside in withAnimation(GadgetMotion.hover) { hovering = inside } }
        .disabled(store.engine.timers.count >= TimerEngine.maxTimers)
        .help(L("Запустить таймер на %@", TimerFormat.length(preset.seconds)))
    }
}
