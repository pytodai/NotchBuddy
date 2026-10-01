import AppKit
import SwiftUI
import NotchBuddyCore

// The contents of each settings section. Every row drops in on its own (`settingsRowIn`) as its card opens.

// MARK: - Island

struct IslandSettingsSection: View {
    @ObservedObject var store: SettingsStore
    let screens: [ScreenOption]
    /// Static renders: «Добавить приложение…» open with these apps.
    var previewPicking: [PickableApp]?
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                SettingsCaption(text: L("Открывать при наведении"))
                SettingsSegmented(selection: $store.values.hoverOpen, options: HoverOpenDelay.allCases, label: \.label)
            }
            .settingsRowIn(0)
            SettingsToggleRow(title: L("Выезжать при запросе разрешения"),
                              hint: L("Карточка откроется сама, как только агент спросит"),
                              isOn: $store.values.openOnPermission)
                .settingsRowIn(1)
            SettingsToggleRow(title: L("Закреплять открытый список"),
                              hint: L("Иначе он закрывается, как только уводишь курсор; булавка в заголовке держит его всегда"),
                              isOn: $store.values.pinOnOpen)
                .settingsRowIn(2)
            SettingsToggleRow(title: L("Показывать без сессий"),
                              hint: L("На экране без выреза остров не прячется"),
                              isOn: $store.values.showWithoutSessions)
                .settingsRowIn(3)
            SettingsDivider().settingsRowIn(4)
            VStack(alignment: .leading, spacing: 7) {
                SettingsCaption(text: L("Уведомление держится"))
                SettingsSegmented(selection: $store.values.flashDuration, options: FlashDuration.allCases, label: \.label)
            }
            .settingsRowIn(4)
            SettingsToggleRow(title: L("Показывать ответ агента при завершении"),
                              hint: L("Карточка «Готово» с последним сообщением агента: перейти, скопировать, закрыть"),
                              isOn: $store.values.showsAgentReply)
                .settingsRowIn(5)
            IslandStyleSetting(store: store, screens: screens)
                .settingsRowIn(6)
            if store.values.usesIslandStyle {
                // Only «Островок» has a capsule (and can be dragged sideways); «Чёлка» is laid out around the camera or
                // the menu bar.
                CapsuleWidthSetting(store: store)
                    .settingsRowIn(7)
                    .transition(.opacity.combined(with: .offset(y: -6)))
                IslandPositionSetting(store: store)
                    .settingsRowIn(7)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            VStack(alignment: .leading, spacing: 7) {
                SettingsCaption(text: L("Размер"))
                SettingsSegmented(selection: $store.values.size, options: IslandSize.allCases, label: \.label,
                                  picture: { size, selected in AnyView(SizePicture(size: size, selected: selected)) })
            }
            .settingsRowIn(8)
            VStack(alignment: .leading, spacing: 7) {
                SettingsCaption(text: L("Экран"))
                ScreenPicker(selection: $store.values.screen, screens: screens)
            }
            .settingsRowIn(9)
            AppFilterSetting(store: store, previewPicking: previewPicking)
                .settingsRowIn(10)
        }
        .animation(SettingsMotion.expand(reduce: reduceMotion), value: store.values.usesIslandStyle)
    }
}

/// «Ширина капсулы» (shown while a kind of screen uses «Островок»): the closed capsule at its real size above a slider
/// over 140…360 pt. The capsule morphs after the knob on the island's data spring; the closed island takes the same
/// width (and morphs to it) the moment it is on screen again. Whole even points, with a detent at the default.
private struct CapsuleWidthSetting: View {
    @ObservedObject var store: SettingsStore

    private static let range = NotchSettings.capsuleWidthRange

    private var fraction: Binding<Double> {
        Binding(
            get: { (store.values.capsuleWidth - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound) },
            set: { value in
                var width = Self.range.lowerBound + value * (Self.range.upperBound - Self.range.lowerBound)
                width = (width / 2).rounded() * 2
                if abs(width - NotchSettings.defaultCapsuleWidth) <= 3 { width = NotchSettings.defaultCapsuleWidth }
                width = NotchSettings.clampedCapsuleWidth(width)
                if width != store.values.capsuleWidth { store.values.capsuleWidth = width }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsCaption(text: L("Ширина капсулы"), trailing: L("%@ пт", Int(store.values.capsuleWidth)))
            CapsuleWidthPreview(width: CGFloat(store.values.capsuleWidth))
            HStack(spacing: 10) {
                Capsule(style: .continuous)
                    .fill(IslandPalette.tertiary)
                    .frame(width: 11, height: 5)
                    .frame(width: 18)
                SettingsSlider(value: fraction)
                Capsule(style: .continuous)
                    .fill(IslandPalette.secondary)
                    .frame(width: 18, height: 5)
                    .frame(width: 18)
            }
            Text(L("Свёрнутый островок: персонаж слева, статус справа; проект и время — при наведении."))
                .settingsFont(10.5, .medium)
                .foregroundStyle(IslandPalette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The closed «Островок» at its real size, floating below the top of a plain screen with its menu bar: the same face the
/// island draws (`IslandCapsuleFace`), its width springing after the slider like the island's shape.
private struct CapsuleWidthPreview: View {
    let width: CGFloat
    @Environment(\.islandReduceMotion) private var reduceMotion

    /// The capsule's height on any screen (`IslandPlacement` for «Островок»: a notch-less screen's virtual notch).
    private static let height = IslandMetrics.floatingBarHeight(menuBar: 24)

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 24)
            IslandCapsuleFace(width: width, height: Self.height, status: .working, usage: 42, others: 2,
                              reportsRing: false) {
                IslandMascot(source: .claude, state: .working, size: CollapsedIslandView.mascotSize)
            }
            .background(Capsule(style: .circular).fill(Color.black))
            .overlay(Capsule(style: .circular).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .padding(.top, IslandLayout.islandGap)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : IslandMotion.data.animation, value: width)
        }
        .frame(maxWidth: .infinity)
        .frame(height: IslandLayout.islandGap + Self.height + 12, alignment: .top)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// «Стиль»: «Чёлка» (flush with the top edge) or «Островок» (a capsule floating below it, like the Dynamic Island of an
/// iPhone 15 Pro), one for monitors and one for a screen with a camera notch (the MacBook's own). Per kind of screen,
/// not per display: a monitor keeps its style whatever port or dock it hangs on. Applies live (the shape morphs).
private struct IslandStyleSetting: View {
    @ObservedObject var store: SettingsStore
    let screens: [ScreenOption]

    /// The notched row shows only with such a screen connected (or when it was set to «Островок» before).
    private var showsNotched: Bool {
        screens.contains(where: \.hasNotch) || store.values.islandStyleNotched != .notch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsCaption(text: L("Стиль"))
            if showsNotched {
                row(hasNotch: false, title: L("Монитор"), symbol: "display")
                row(hasNotch: true, title: L("Экран с вырезом"), symbol: "laptopcomputer")
            } else {
                picker(hasNotch: false)
            }
            Text(L("Островок — капсула чуть ниже края экрана, как Dynamic Island на iPhone; свёрнутый — компактный."))
                .settingsFont(10.5, .medium)
                .foregroundStyle(IslandPalette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(hasNotch: Bool, title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(IslandPalette.tertiary)
                Text(title)
                    .settingsFont(11, .semibold)
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(1)
            }
            picker(hasNotch: hasNotch)
        }
    }

    private func picker(hasNotch: Bool) -> some View {
        let selection = Binding<IslandStyle>(
            get: { store.values.islandStyle(hasNotch: hasNotch) },
            set: { store.values.setIslandStyle($0, hasNotch: hasNotch) })
        return SettingsSegmented(selection: selection, options: IslandStyle.allCases, label: \.label,
                                 picture: { style, selected in
                                     AnyView(StylePicture(style: style, selected: selected))
                                 })
    }
}

/// A tiny screen with the island in a style: flush with the top edge, or a capsule floating below it.
private struct StylePicture: View {
    let style: IslandStyle
    let selected: Bool

    var body: some View {
        let ink = selected ? Color.white : Color.white.opacity(0.55)
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.1 : 0.04))
                .strokeBorder(Color.white.opacity(selected ? 0.5 : 0.22), lineWidth: 1)
                .frame(width: 40, height: 22)
            switch style {
            case .notch:
                IslandShape(earRadius: 2.4, bottomRadius: 3.2)
                    .fill(ink)
                    .frame(width: 20.8, height: 6.5)
            case .island:
                Capsule(style: .continuous)
                    .fill(ink)
                    .frame(width: 15, height: 5.5)
                    .padding(.top, 3)
            }
        }
        .frame(height: 22)
    }
}

/// A tiny screen with an island of the given size.
private struct SizePicture: View {
    let size: IslandSize
    let selected: Bool

    var body: some View {
        let (w, h): (CGFloat, CGFloat) = switch size {
        case .small: (12, 5)
        case .medium: (16, 6.5)
        case .large: (21, 8.5)
        }
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.1 : 0.04))
                .strokeBorder(Color.white.opacity(selected ? 0.5 : 0.22), lineWidth: 1)
                .frame(width: 40, height: 22)
            IslandShape(earRadius: 2.4, bottomRadius: 3.2)
                .fill(selected ? Color.white : Color.white.opacity(0.55))
                .frame(width: w + 4.8, height: h)
        }
        .frame(height: 22)
    }
}

/// Where the island lives: follow the active window, the main screen, or one display.
private struct ScreenPicker: View {
    @Binding var selection: ScreenChoice
    let screens: [ScreenOption]
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Namespace private var namespace

    private struct Option: Identifiable {
        let choice: ScreenChoice
        let title: String
        let detail: String
        let symbol: String
        var badge: String?
        var id: String { choice.rawValue }
    }

    private var options: [Option] {
        var result = [
            Option(choice: .activeWindow, title: L("Где активное окно"), detail: L("Остров переезжает вслед за окном"),
                   symbol: "macwindow.on.rectangle"),
            Option(choice: .main, title: L("Основной экран"), detail: screens.first?.name ?? L("С полосой меню"),
                   symbol: "menubar.rectangle"),
        ]
        for screen in screens {
            result.append(Option(choice: .display(id: screen.id, name: screen.name), title: screen.name,
                                 detail: screen.isMain ? L("Основной") : L("Дополнительный"),
                                 symbol: screen.hasNotch ? "laptopcomputer" : "display",
                                 badge: screen.hasNotch ? L("вырез") : nil))
        }
        if case .display(let id, let name) = selection, !screens.contains(where: { $0.id == id }) {
            result.append(Option(choice: selection, title: name.isEmpty ? L("Экран") : name, detail: L("Не подключён"),
                                 symbol: "display.trianglebadge.exclamationmark"))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(options) { option in
                row(option)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SettingsPalette.well))
    }

    private func row(_ option: Option) -> some View {
        let selected = isSelected(option.choice)
        return Button {
            withAnimation(SettingsMotion.control(reduce: reduceMotion)) { selection = option.choice }
        } label: {
            HStack(spacing: 10) {
                RadioMark(on: selected)
                Image(systemName: option.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : IslandPalette.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .settingsFont(12, .semibold)
                            .foregroundStyle(Color.white.opacity(selected ? 1 : 0.85))
                            .lineLimit(1)
                        if let badge = option.badge {
                            Text(badge)
                                .settingsFont(9.5, .bold)
                                .foregroundStyle(IslandPalette.secondary)
                                .padding(.horizontal, 5)
                                .frame(height: 14)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                    }
                    Text(option.detail)
                        .settingsFont(10.5, .medium)
                        .foregroundStyle(IslandPalette.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 38)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                        .matchedGeometryEffect(id: "screen", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }

    private func isSelected(_ choice: ScreenChoice) -> Bool {
        switch (choice, selection) {
        case (.display(let a, _), .display(let b, _)): return a == b
        default: return choice == selection
        }
    }
}

/// A radio circle; the dot springs in.
struct RadioMark: View {
    let on: Bool
    @Environment(\.settingsAccent) private var accent
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(on ? 0 : 0.3), lineWidth: 1.2)
            Circle().fill(accent.color)
                .scaleEffect(on ? 1 : 0.2)
                .opacity(on ? 1 : 0)
            Circle().fill(accent.onColor).frame(width: 6, height: 6)
                .scaleEffect(on ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.6), value: on)
    }
}

// MARK: - Sounds

struct SoundSettingsSection: View {
    @ObservedObject var model: SettingsPageModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var previewer: SoundPreviewer

    var body: some View {
        let on = store.values.soundsEnabled
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggleRow(title: L("Звуки уведомлений"), hint: L("Когда агент закончил, ждёт тебя или спрашивает"),
                              isOn: $store.values.soundsEnabled)
                .settingsRowIn(0)
            VStack(alignment: .leading, spacing: 6) {
                SettingsCaption(text: L("Громкость"), trailing: L("%@\u{00A0}%%", Int((store.values.soundVolume * 100).rounded())))
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(IslandPalette.tertiary)
                    SettingsSlider(value: $store.values.soundVolume, enabled: on) {
                        previewer.play(store.values.sound(for: .finished).isEmpty ? "Glass" : store.values.sound(for: .finished),
                                       volume: store.values.soundVolume)
                    }
                    Image(systemName: "speaker.wave.3.fill", variableValue: store.values.soundVolume)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IslandPalette.secondary)
                        .frame(width: 18)
                }
            }
            .opacity(on ? 1 : 0.4)
            .settingsRowIn(1)
            SettingsDivider().settingsRowIn(2)
            ForEach(Array(SoundEvent.allCases.enumerated()), id: \.element) { index, event in
                SoundEventRow(event: event, model: model, store: store, previewer: previewer)
                    .settingsRowIn(3 + index)
            }
            .opacity(on ? 1 : 0.4)
            .allowsHitTesting(on)
        }
    }
}

private struct SoundEventRow: View {
    let event: SoundEvent
    @ObservedObject var model: SettingsPageModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var previewer: SoundPreviewer
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.settingsAccent) private var accent

    var body: some View {
        let name = store.values.sound(for: event)
        let open = model.soundPicker == event
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                EventGlyph(event: event)
                Text(event.title)
                    .settingsFont(12.5, .semibold)
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer(minLength: 8)
                PlayButton(playing: previewer.playing == name && !name.isEmpty, enabled: !name.isEmpty) {
                    previewer.toggle(name, volume: store.values.soundVolume)
                }
                Button {
                    withAnimation(SettingsMotion.expand(reduce: reduceMotion)) {
                        model.soundPicker = open ? nil : event
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(SettingsSounds.label(name))
                            .lineLimit(1)
                            .contentTransition(.interpolate)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .heavy))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .frame(width: 88)
                }
                .buttonStyle(SettingsButtonStyle(kind: .neutral))
            }
            if open {
                SoundChips(selection: name) { picked in
                    store.values.sounds[event] = picked
                    if picked.isEmpty { previewer.stop() } else { previewer.play(picked, volume: store.values.soundVolume) }
                }
                .padding(.leading, 34)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -6)).animation(.easeOut(duration: 0.2).delay(0.05).speed(IslandMotion.speed)),
                    removal: .opacity.animation(.easeOut(duration: 0.1).speed(IslandMotion.speed))))
            }
        }
    }
}

/// The event's colored glyph (the island's status colors).
private struct EventGlyph: View {
    let event: SoundEvent

    var body: some View {
        let (symbol, tint): (String, Color) = switch event {
        case .finished: ("checkmark", SessionStatus.finished.tint)
        case .attention: ("bell.fill", SessionStatus.waitingForUser.tint)
        case .permission: ("hand.raised.fill", SessionStatus.working.tint)
        case .error: ("exclamationmark", SessionStatus.error.tint)
        }
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .heavy))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.white.opacity(0.07)))
    }
}

/// ▶ / animated waveform while the sound plays.
private struct PlayButton: View {
    let playing: Bool
    let enabled: Bool
    let action: () -> Void
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "speaker.wave.2.fill" : "play.fill")
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: playing && !reduceMotion)
                .foregroundStyle(Color.white.opacity(playing ? 1 : 0.85))
        }
        .buttonStyle(IslandIconButtonStyle(size: 26, active: playing))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(playing ? L("Остановить") : L("Послушать"))
    }
}

/// Every available sound as a chip; picking one plays it.
private struct SoundChips: View {
    let selection: String
    let pick: (String) -> Void
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach([""] + SettingsSounds.catalog, id: \.self) { name in
                let selected = name == selection
                Button {
                    withAnimation(SettingsMotion.control(reduce: reduceMotion)) { pick(name) }
                } label: {
                    HStack(spacing: 4) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8.5, weight: .heavy))
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(SettingsSounds.label(name))
                            .settingsFont(11, selected ? .bold : .semibold)
                    }
                    .foregroundStyle(selected ? Color.white : IslandPalette.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(selected ? SettingsPalette.selection : Color.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(selected ? SettingsPalette.selectionStroke : .clear, lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.92))
            }
        }
    }
}

// MARK: - Agents and hooks

struct AgentSettingsSection: View {
    @ObservedObject var hooks: HookSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let agents = AgentCatalog.settingsAgents
            ForEach(Array(agents.enumerated()), id: \.element) { index, source in
                AgentHookRow(source: source, hooks: hooks)
                    .settingsRowIn(index)
                if index < agents.count - 1 {
                    SettingsDivider().settingsRowIn(index)
                }
            }
            MoreAgentsRow()
                .settingsRowIn(3)
            SettingsNote(text: L("Перед каждым изменением — резервная копия в ~/.notchbuddy/backups. Чужие хуки не трогаются."),
                         symbol: "clock.arrow.circlepath")
                .settingsRowIn(4)
        }
    }
}

private struct AgentHookRow: View {
    let source: AgentSource
    @ObservedObject var hooks: HookSettingsModel
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let report = hooks.reports[source]
        let busy = hooks.busy.contains(source)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentMark(source: source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .settingsFont(12.5, .bold)
                        .foregroundStyle(Color.white)
                    HStack(spacing: 5) {
                        StatusDot(color: color(report?.status, busy: busy), size: 6, pulsing: busy)
                            .keyframeAnimator(initialValue: CGFloat(1), trigger: hooks.successTick[source] ?? 0) { dot, scale in
                                dot.scaleEffect(scale)
                            } keyframes: { _ in
                                KeyframeTrack {
                                    SpringKeyframe(2.2, duration: IslandMotion.t(0.16), spring: IslandMotion.kspring(0.2, 0.6))
                                    SpringKeyframe(1, duration: IslandMotion.t(0.4), spring: IslandMotion.kspring(0.35, 0.55))
                                }
                            }
                        Text(busy ? L("Выполняется…") : report?.status.settingsLabel ?? L("Проверяю…"))
                            .settingsFont(11, .semibold)
                            .foregroundStyle(color(report?.status, busy: busy).opacity(0.95))
                            .contentTransition(.interpolate)
                    }
                    .animation(IslandMotion.leaf, value: report?.status)
                }
                Spacer(minLength: 6)
                actions(report, busy: busy)
            }
            if let hint = hint(report?.status) {
                Text(hint)
                    .settingsFont(11, .medium)
                    .foregroundStyle(IslandPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }
            if let note = hooks.notes[source] {
                SettingsNote(text: note.text, tone: tone(note.kind))
                    .padding(.leading, 38)
                    .transition(.opacity.combined(with: .offset(y: -4)).animation(IslandMotion.leaf))
            }
        }
        .animation(SettingsMotion.expand(reduce: reduceMotion), value: hooks.notes[source])
    }

    @ViewBuilder
    private func actions(_ report: HookReport?, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if busy {
                BusySpinner(size: 13, color: IslandPalette.secondary)
                    .frame(width: 26, height: 26)
                    .transition(.scale.combined(with: .opacity))
            } else if let report {
                if !report.existingFiles.isEmpty, report.status != .agentMissing {
                    Button { hooks.reveal(source) } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(IslandIconButtonStyle(size: 26))
                    .help(L("Показать файл настроек"))
                }
                switch report.status {
                case .agentMissing:
                    Text(L("не установлен"))
                        .settingsFont(11, .semibold)
                        .foregroundStyle(IslandPalette.tertiary)
                case .notInstalled, .error:
                    Button(L("Подключить")) { hooks.install(source) }
                        .buttonStyle(SettingsButtonStyle(kind: .accent))
                case .installed:
                    Button(L("Переустановить")) { hooks.install(source) }
                        .buttonStyle(SettingsButtonStyle(kind: .neutral))
                    ConfirmButton(title: L("Удалить"), confirmTitle: L("Удалить?")) { hooks.uninstall(source) }
                case .partial:
                    Button(L("Починить")) { hooks.install(source) }
                        .buttonStyle(SettingsButtonStyle(kind: .accent))
                    ConfirmButton(title: L("Удалить"), confirmTitle: L("Удалить?")) { hooks.uninstall(source) }
                }
            }
        }
        .animation(SettingsMotion.control(reduce: reduceMotion), value: busy)
    }

    private func hint(_ status: HookInstallStatus?) -> String? {
        switch (source, status) {
        case (.codex, .partial(let detail)?):
            return L("%@. Codex запускает только доверенные хуки — «Починить» запишет доверие в ~/.codex/config.toml.", detail.prefix(1).uppercased() + detail.dropFirst())
        case (.codex, .installed?), (.codex, .notInstalled?):
            return L("Хуки заодно отмечаются доверенными в ~/.codex/config.toml — иначе Codex их не запускает.")
        case (.kimi, let s?) where s != .agentMissing:
            return L("Только статус и уведомления: разрешать инструменты нужно в самом Kimi.")
        case (_, .error(let message)?):
            return message
        case (_, let s?) where s != .agentMissing && !AgentSource.allCases.contains(source):
            // Catalog agents: what the island can do for them.
            return AgentCatalog.descriptor(for: source)?.capabilityNote
        default:
            return nil
        }
    }

    private func color(_ status: HookInstallStatus?, busy: Bool) -> Color {
        if busy { return SessionStatus.working.tint }
        switch status {
        case .installed?: return SettingsPalette.success
        case .partial?: return SettingsPalette.warning
        case .error?: return SettingsPalette.danger
        case .notInstalled?, .agentMissing?, nil: return Color(white: 0.55)
        }
    }

    private func tone(_ kind: HookSettingsModel.Note.Kind) -> SettingsNote.Tone {
        switch kind {
        case .success: return .success
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}

/// A dashed placeholder: more agents are coming.
private struct MoreAgentsRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(IslandPalette.tertiary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Другие агенты"))
                    .settingsFont(12.5, .semibold)
                    .foregroundStyle(IslandPalette.secondary)
                Text(L("Новые агенты появятся здесь сами"))
                    .settingsFont(11, .medium)
                    .foregroundStyle(IslandPalette.tertiary)
            }
            Spacer()
            SoonBadge()
        }
    }
}

// MARK: - Usage

struct UsageSettingsSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggleRow(title: L("Лимиты Claude через API"),
                              hint: L("Берёт вход Claude Code из связки ключей и спрашивает api.anthropic.com не чаще раза в 5 минут. Выключено — только statusLine, без сети."),
                              isOn: $store.values.claudeUsageViaAPI)
                .settingsRowIn(0)
            SettingsToggleRow(title: L("Лимиты Kimi через API"),
                              hint: L("Пока Kimi Code вошёл: читает его вход (не меняя его) и спрашивает api.kimi.com не чаще раза в 5 минут. Codex — по его журналам на этом Mac, без сети."),
                              isOn: $store.values.kimiUsageViaAPI)
                .settingsRowIn(1)
            SettingsToggleRow(title: L("Кольцо на свёрнутом острове"),
                              hint: L("Сколько лимита израсходовано, рядом с сессией"),
                              isOn: $store.values.showsUsageRing)
                .settingsRowIn(2)
            VStack(alignment: .leading, spacing: 7) {
                SettingsCaption(text: L("Чьи лимиты показывать"), trailing: store.values.usageProvider.label)
                SettingsSegmented(selection: $store.values.usageProvider, options: UsageProviderChoice.allCases, label: \.label)
                Text(L("«Авто» — все агенты с данными, а кольцо — агента на острове. Клик по лимитам в списке тоже переключает."))
                    .settingsFont(10.5, .medium)
                    .foregroundStyle(IslandPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsRowIn(2)
            SettingsDivider().settingsRowIn(2)
            VStack(alignment: .leading, spacing: 7) {
                SettingsCaption(text: L("Обновлять лимиты"))
                SettingsSegmented(selection: $store.values.usageRefresh, options: UsageRefreshInterval.allCases, label: \.label)
            }
            .settingsRowIn(2)
        }
    }
}

// MARK: - Hotkey

struct HotkeySettingsSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var recorder: HotkeyRecorder
    @ObservedObject var hotkey: GlobalHotkey
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggleRow(title: L("Открывать остров сочетанием"),
                              hint: L("Из любой программы; клавиатуру остров не забирает"),
                              isOn: $store.values.hotkeyEnabled)
                .settingsRowIn(0)
            ComboWell(combo: store.values.hotkey, recorder: recorder, status: statusLine, enabled: store.values.hotkeyEnabled)
                .settingsRowIn(1)
            HStack(spacing: 8) {
                if recorder.isRecording {
                    Button(L("Отменить")) { recorder.cancel() }
                        .buttonStyle(SettingsButtonStyle(kind: .neutral))
                } else {
                    Button {
                        recorder.start()
                    } label: {
                        Label(L("Записать сочетание"), systemImage: "record.circle")
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .accent))
                }
                Spacer(minLength: 0)
            }
            .animation(SettingsMotion.control(reduce: reduceMotion), value: recorder.isRecording)
            .settingsRowIn(2)
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Или выбери готовое"))
                    .settingsFont(11, .semibold)
                    .foregroundStyle(IslandPalette.tertiary)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    // Only the ones this Mac has not taken for itself.
                    ForEach(HotkeyCombo.presets.filter { hotkey.systemConflict($0) == nil }, id: \.self) { preset in
                        PresetChip(combo: preset, selected: preset == store.values.hotkey) {
                            withAnimation(SettingsMotion.control(reduce: reduceMotion)) {
                                store.values.hotkey = preset
                                store.values.hotkeyEnabled = true
                            }
                        }
                    }
                }
            }
            .settingsRowIn(3)
        }
    }

    private var statusLine: (String, Color) {
        guard store.values.hotkeyEnabled else { return (L("Выключено"), Color(white: 0.55)) }
        switch hotkey.status {
        case .active(let combo):
            if let app = HotkeyClashes.app(combo) { return (L("Работает · может мешать: %@", app), SettingsPalette.warning) }
            return (Lc("hotkey", "Работает"), SettingsPalette.success)
        case .taken: return (L("Занято другой программой — выбери другое"), SettingsPalette.warning)
        case .system(_, let name): return (L("Занято macOS: «%@» — выбери другое", name), SettingsPalette.warning)
        case .off: return (L("Включится, как только остров его подхватит"), Color(white: 0.6))
        }
    }
}

/// The current combo as keycaps; while recording, the modifiers being held and a blinking slot.
private struct ComboWell: View {
    let combo: HotkeyCombo
    @ObservedObject var recorder: HotkeyRecorder
    let status: (String, Color)
    let enabled: Bool
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.islandStaticRender) private var staticRender

    var body: some View {
        let recording = recorder.isRecording
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                if recording {
                    ForEach(recorder.heldModifiers.symbols, id: \.self) { symbol in
                        Keycap(text: symbol, size: 32, lit: true)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                    BlinkingSlot()
                } else {
                    // Keyed by combo and position: a new combo's keys pop in one after another.
                    ForEach(Array(combo.keycaps.caps(of: combo).enumerated()), id: \.element.id) { index, cap in
                        Keycap(text: cap.text, size: 32, lit: enabled)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.6).combined(with: .opacity)
                                    .animation(.spring(response: 0.34, dampingFraction: 0.62).delay(0.04 * Double(index)).speed(IslandMotion.speed)),
                                removal: .opacity.animation(.easeOut(duration: 0.1).speed(IslandMotion.speed))))
                    }
                }
            }
            .frame(height: 36)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: recorder.rejections) { content, x in
                content.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-7, duration: IslandMotion.t(0.05))
                    CubicKeyframe(6, duration: IslandMotion.t(0.07))
                    CubicKeyframe(-4, duration: IslandMotion.t(0.07))
                    CubicKeyframe(0, duration: IslandMotion.t(0.08))
                }
            }
            HStack(spacing: 6) {
                if recording {
                    StatusDot(color: SettingsPalette.danger, size: 6, pulsing: true)
                    Text(recorder.lastRejected ?? L("Нажми сочетание · Esc — отмена"))
                        .settingsFont(11, .semibold)
                        .foregroundStyle(recorder.lastRejected == nil ? IslandPalette.secondary : SettingsPalette.warning)
                } else {
                    StatusDot(color: status.1, size: 6)
                    Text(status.0)
                        .settingsFont(11, .semibold)
                        .foregroundStyle(status.1.opacity(0.95))
                }
            }
            .contentTransition(.interpolate)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SettingsPalette.well)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(recording ? 0.28 : 0.05),
                                  style: StrokeStyle(lineWidth: recording ? 1 : 0.5, dash: recording ? [5, 4] : [])))
        }
        .animation(SettingsMotion.control(reduce: reduceMotion), value: recording)
        .animation(SettingsMotion.control(reduce: reduceMotion), value: recorder.heldModifiers)
        .animation(SettingsMotion.control(reduce: reduceMotion), value: combo)
    }
}

private extension HotkeyCombo {
    struct Cap: Identifiable {
        let id: String
        let text: String
    }
}

private extension Array where Element == String {
    func caps(of combo: HotkeyCombo) -> [HotkeyCombo.Cap] {
        enumerated().map { HotkeyCombo.Cap(id: "\(combo.rawValue)#\($0.offset)", text: $0.element) }
    }
}

/// "…" slot that blinks while waiting for a key.
private struct BlinkingSlot: View {
    @Environment(\.islandStaticRender) private var staticRender
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            .frame(width: 32, height: 32)
            .overlay(Text("?").settingsFont(14, .bold).foregroundStyle(Color.white.opacity(0.5)))
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !staticRender else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever().speed(IslandMotion.speed)) { dim = true }
            }
    }
}

private struct PresetChip: View {
    let combo: HotkeyCombo
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(combo.display)
                .settingsFont(11.5, .bold)
                .foregroundStyle(selected ? Color.white : IslandPalette.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(selected ? SettingsPalette.selection : Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(selected ? SettingsPalette.selectionStroke : .clear, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
    }
}

// MARK: - Widgets

struct WidgetSettingsSection: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.islandReduceMotion) private var reduceMotion
    /// The row being dragged, and how far.
    @State private var dragging: WidgetKind?
    @State private var dragOffset: CGFloat = 0

    private static let rowHeight: CGFloat = 46
    private static let spacing: CGFloat = 4
    private static var pitch: CGFloat { rowHeight + spacing }

    var body: some View {
        let widgets = store.values.widgets
        let from = dragging.flatMap { kind in widgets.firstIndex { $0.kind == kind } }
        let target = from.map { min(max($0 + Int((dragOffset / Self.pitch).rounded()), 0), widgets.count - 1) }
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Вкладки открытого острова. Включённый островок показывает и своё «живое» состояние в свёрнутом: трек, встречу, таймер. Потяни за ручку, чтобы поменять порядок."))
                .settingsFont(11, .medium)
                .foregroundStyle(IslandPalette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .settingsRowIn(0)
            VStack(spacing: Self.spacing) {
                ForEach(Array(widgets.enumerated()), id: \.element.kind) { index, entry in
                    let lifted = entry.kind == dragging
                    WidgetRow(entry: entry, lifted: lifted, isOn: binding(entry.kind), handle: handleGesture(entry.kind))
                        .frame(height: Self.rowHeight)
                        .offset(y: lifted ? dragOffset : shift(index, from: from, to: target))
                        .zIndex(lifted ? 1 : 0)
                        .animation(lifted ? nil : SettingsMotion.control(reduce: reduceMotion), value: target)
                        .settingsRowIn(1 + index)
                }
            }
            WidgetDetailSettings(store: store)
                .settingsRowIn(1 + widgets.count)
        }
    }

    /// Rows between the dragged row's place and its target make room.
    private func shift(_ index: Int, from: Int?, to: Int?) -> CGFloat {
        guard let from, let to, index != from else { return 0 }
        if from < to, index > from, index <= to { return -Self.pitch }
        if from > to, index >= to, index < from { return Self.pitch }
        return 0
    }

    private func handleGesture(_ kind: WidgetKind) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if dragging != kind {
                    withAnimation(SettingsMotion.press) { dragging = kind }
                }
                dragOffset = value.translation.height
            }
            .onEnded { _ in
                let widgets = store.values.widgets
                guard let from = widgets.firstIndex(where: { $0.kind == kind }) else { return }
                let to = min(max(from + Int((dragOffset / Self.pitch).rounded()), 0), widgets.count - 1)
                var transaction = Transaction(animation: SettingsMotion.control(reduce: reduceMotion))
                transaction.disablesAnimations = false
                withTransaction(transaction) {
                    store.values.moveWidget(from: from, to: to)
                    dragging = nil
                    dragOffset = 0
                }
            })
    }

    private func binding(_ kind: WidgetKind) -> Binding<Bool> {
        Binding(get: { store.values.widgets.first { $0.kind == kind }?.enabled ?? false },
                set: { on in
                    guard let index = store.values.widgets.firstIndex(where: { $0.kind == kind }) else { return }
                    store.values.widgets[index].enabled = on
                })
    }
}

private struct WidgetRow: View {
    let entry: WidgetEntry
    let lifted: Bool
    @Binding var isOn: Bool
    let handle: AnyGesture<DragGesture.Value>
    @State private var hoveringHandle = false
    @State private var cursorPushed = false

    private func setGrabCursor(_ on: Bool) {
        guard on != cursorPushed else { return }
        cursorPushed = on
        if on { NSCursor.openHand.push() } else { NSCursor.pop() }
    }

    var body: some View {
        let kind = entry.kind
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hoveringHandle || lifted ? IslandPalette.secondary : Color.white.opacity(0.3))
                .frame(width: 22, height: 36)
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoveringHandle = hovering
                    setGrabCursor(hovering)
                }
                .onDisappear { setGrabCursor(false) }
                .gesture(handle)
            Image(systemName: kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(kind.isAvailable ? kind.tint : Color(white: 0.28)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                .opacity(kind.isAvailable ? 1 : 0.8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(kind.title)
                        .settingsFont(12.5, .semibold)
                        .foregroundStyle(Color.white.opacity(kind.isAvailable ? 0.95 : 0.7))
                    if !kind.isAvailable { SoonBadge() }
                }
                Text(kind.subtitle)
                    .settingsFont(10.5, .medium)
                    .foregroundStyle(IslandPalette.tertiary)
            }
            Spacer(minLength: 6)
            if kind.isRequired {
                Text(L("Всегда"))
                    .settingsFont(11, .semibold)
                    .foregroundStyle(IslandPalette.tertiary)
                    .padding(.trailing, 4)
            } else {
                SettingsToggle(isOn: $isOn, enabled: kind.isAvailable)
            }
        }
        .padding(.trailing, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(lifted ? 0.13 : 0.045))
                .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: lifted ? 10 : 0, y: lifted ? 4 : 0)
        }
        .scaleEffect(lifted ? 1.025 : 1)
        .animation(SettingsMotion.press, value: lifted)
    }
}

// MARK: - Appearance

struct AppearanceSettingsSection: View {
    @ObservedObject var store: SettingsStore
    let systemReduce: Bool
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                SettingsCaption(text: L("Акцент настроек"), trailing: store.values.accent.label)
                HStack(spacing: 0) {
                    ForEach(AccentChoice.allCases, id: \.self) { accent in
                        Swatch(accent: accent, selected: accent == store.values.accent, namespace: namespace) {
                            withAnimation(SettingsMotion.control(reduce: reduceMotion)) { store.values.accent = accent }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SettingsPalette.well))
                Text(L("Цвет переключателей и выбора на этой странице. Сам остров — чёрный с белым, цвет только у статусов."))
                    .settingsFont(10.5, .medium)
                    .foregroundStyle(IslandPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsRowIn(0)
            SettingsDivider().settingsRowIn(1)
            VStack(alignment: .leading, spacing: 7) {
                SettingsCaption(text: L("Анимации"))
                SettingsSegmented(selection: $store.values.motion, options: MotionPreference.allCases, label: \.label)
                Text(motionHint)
                    .settingsFont(11, .medium)
                    .foregroundStyle(IslandPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
                    .animation(IslandMotion.leaf, value: store.values.motion)
            }
            .settingsRowIn(1)
        }
    }

    private var motionHint: String {
        switch store.values.motion {
        case .system:
            return systemReduce ? L("В системе включено «Уменьшение движения» — остров двигается сдержанно.")
                : L("Пружины, всплески и встряска — как задумано. Следует за «Уменьшением движения» в системе.")
        case .full: return L("Полные анимации, даже если в системе включено «Уменьшение движения».")
        case .reduced: return L("Короткие пружины без отскока, без встряски и летящего значка.")
        }
    }
}

private struct Swatch: View {
    let accent: AccentChoice
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if selected {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                        .frame(width: 30, height: 30)
                        .matchedGeometryEffect(id: "ring", in: namespace)
                }
                Circle()
                    .fill(accent.color)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .heavy))
                    .foregroundStyle(accent.onColor)
                    .scaleEffect(selected ? 1 : 0.2)
                    .opacity(selected ? 1 : 0)
            }
            .frame(width: 36, height: 36)
            .scaleEffect(hovering && !selected ? 1.12 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.88))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.6).speed(IslandMotion.speed), value: hovering)
        .animation(.spring(response: 0.34, dampingFraction: 0.62).speed(IslandMotion.speed), value: selected)
        .help(accent.label)
    }
}

// MARK: - Language

/// «Язык · Language»: Авто (macOS) / Русский / English, applied at once — every string on the island, in the menu bar
/// menu, alerts and notices follows (`L10n`).
struct LanguageSettingsSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsCaption(text: L("Язык интерфейса"))
            SettingsSegmented(selection: $store.values.language, options: AppLanguage.allCases, label: \.label)
            Text(hint)
                .settingsFont(11, .medium)
                .foregroundStyle(IslandPalette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate)
                .animation(IslandMotion.leaf, value: store.values.language)
        }
        .settingsRowIn(0)
    }

    private var hint: String {
        switch store.values.language {
        case .auto:
            return L("Как в macOS — сейчас %@. Переключается сразу, без перезапуска.", L10n.shared.language.nameInSentence)
        case .ru, .en:
            return L("Переключается сразу, без перезапуска: остров, меню, уведомления и настройки.")
        }
    }
}

// MARK: - Privacy and logs

struct PrivacySettingsSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var maintenance: SettingsMaintenance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsNote(text: L("Никакой аналитики и телеметрии. Всё остаётся на этом Mac."),
                         tone: .success, symbol: "hand.raised.fill")
                .settingsRowIn(0)
            SettingsRow(title: L("Логи"), hint: "~/Library/Logs/NotchBuddy") {
                HStack(spacing: 6) {
                    Button(L("Открыть")) { maintenance.openLogs() }
                        .buttonStyle(SettingsButtonStyle(kind: .neutral))
                    Button { maintenance.revealLogs() } label: { Image(systemName: "folder") }
                        .buttonStyle(IslandIconButtonStyle(size: 26))
                        .help(L("Показать в Finder"))
                }
            }
            .settingsRowIn(1)
            SettingsRow(title: L("Резервные копии конфигов"),
                        hint: maintenance.backups.map(BackupsMaintenance.describe) ?? L("Считаю…")) {
                HStack(spacing: 6) {
                    if maintenance.clearing {
                        BusySpinner(size: 13, color: IslandPalette.secondary)
                    } else {
                        Button { maintenance.revealBackups() } label: { Image(systemName: "folder") }
                            .buttonStyle(IslandIconButtonStyle(size: 26))
                            .help(L("Показать в Finder"))
                        ConfirmButton(title: L("Очистить"), confirmTitle: L("Удалить все?"), symbol: "trash") {
                            maintenance.clearBackups()
                        }
                        .disabled((maintenance.backups?.snapshots ?? 0) == 0)
                    }
                }
            }
            .settingsRowIn(2)
            if let message = maintenance.message {
                SettingsNote(text: message)
                    .transition(.opacity)
            }
            SettingsDivider().settingsRowIn(3)
            SettingsRow(title: L("Сбросить настройки"), hint: L("Хуки и резервные копии останутся как есть")) {
                ConfirmButton(title: L("Сбросить"), confirmTitle: L("Сбросить всё?"), symbol: "arrow.counterclockwise") {
                    withAnimation(SettingsMotion.expand(reduce: false)) { store.resetAll() }
                }
            }
            .settingsRowIn(4)
        }
    }
}

// MARK: - About

struct AboutSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                AppIconImage(size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NotchBuddy")
                        .settingsFont(16, .extraBold)
                        .foregroundStyle(.white)
                    Text(versionLine)
                        .settingsFont(11.5, .semibold)
                        .foregroundStyle(IslandPalette.secondary)
                    Text(L("Остров у выреза для Claude Code, Codex и Kimi"))
                        .settingsFont(11, .medium)
                        .foregroundStyle(IslandPalette.tertiary)
                }
                Spacer(minLength: 0)
            }
            .settingsRowIn(0)
            HStack(spacing: 6) {
                if let url = SettingsMaintenance.repositoryURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .neutral))
                } else {
                    HStack(spacing: 6) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            .settingsFont(11.5, .bold)
                            .foregroundStyle(IslandPalette.tertiary)
                        SoonBadge()
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                Button { NSWorkspace.shared.open(SettingsMaintenance.fontLicenseURL) } label: {
                    Label(L("Шрифт Manrope · OFL"), systemImage: "textformat")
                }
                .buttonStyle(SettingsButtonStyle(kind: .ghost))
                Spacer(minLength: 0)
            }
            .settingsRowIn(1)
            Text(L("Бесплатно, без аккаунтов, подписок и слежки."))
                .settingsFont(11, .medium)
                .foregroundStyle(IslandPalette.tertiary)
                .settingsRowIn(2)
        }
    }

    private var versionLine: String {
        let build = SettingsMaintenance.build.map { " (\($0))" } ?? ""
        return L("Версия %@%@", SettingsMaintenance.version, build)
    }
}

/// The app's icon (from the bundle, or from Resources/ in unbundled runs).
struct AppIconImage: View {
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color(white: 0.16))
                    .overlay(Image(systemName: "sparkles").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
    }

    @MainActor
    static let image: NSImage? = {
        if Bundle.main.bundleURL.pathExtension == "app" { return NSApp.applicationIconImage }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: repo.appendingPathComponent("Resources/AppIcon.icns"))
    }()
}

extension WidgetKind {
    /// The widget's own color (its icon tile): muted, flat, the same family as the section tiles.
    var tint: Color {
        switch self {
        case .agents: return Color(red: 0.36, green: 0.4, blue: 0.86)
        case .music: return Color(red: 0.84, green: 0.29, blue: 0.33)
        case .calendar: return Color(red: 0.86, green: 0.36, blue: 0.3)
        case .timer: return Color(red: 0.86, green: 0.54, blue: 0.18)
        case .system: return Color(red: 0.17, green: 0.56, blue: 0.56)
        case .shelf: return Color(red: 0.2, green: 0.46, blue: 0.86)
        }
    }
}

/// The settings of every widget that is switched on (each draws its own block), under the list of widgets.
private struct WidgetDetailSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let hub = WidgetHub.shared
        let on = store.values.enabledWidgets.filter { $0 != .agents }
        if !on.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SettingsDivider()
                ForEach(on, id: \.self) { kind in
                    detail(kind, hub: hub)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func detail(_ kind: WidgetKind, hub: WidgetHub) -> some View {
        switch kind {
        case .agents:
            EmptyView()
        case .music:
            MusicSettingsSection(hub: hub)
        case .calendar:
            if let calendar = hub.calendar { CalendarSettingsView(service: calendar) }
        case .timer:
            if let timer = hub.timer { TimerSettingsSection(preferences: timer.preferences) }
        case .system:
            if let system = hub.system { SystemSettingsSection(preferences: system.preferences) }
        case .shelf:
            if let shelf = hub.shelf { ShelfSettingsSection(settings: shelf.settings, width: 440, showsEnableSwitch: false) }
        }
    }
}
