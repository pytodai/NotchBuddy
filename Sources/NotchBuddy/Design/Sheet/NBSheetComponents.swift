import SwiftUI

// MARK: - 05 Components

struct NBSheetComponents: View {
    private let states: [(String, NBForcedState?)] = [
        ("покой", .rest), ("наведение", .hover), ("нажатие", .press), ("выключена", nil),
    ]

    private let kinds: [(String, String, NBIcon, NBButtonStyle.Kind)] = [
        ("primary", "Разрешить", .check, .primary),
        ("secondary", "Всегда", .sparkle, .secondary),
        ("destructive", "Запретить", .close, .destructive),
        ("accent · done", "Готово", .check, .accent(.done)),
        ("tinted · working", "Перейти", .jump, .tinted(.working)),
        ("ghost", "В терминал", .terminal, .ghost),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            NBSheetSection(number: "05", title: "Кнопки", note: "нажатие — сплющивание и отскок, наведение — блик и свечение") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        Color.clear.frame(width: 120, height: 1)
                        ForEach(states, id: \.0) { state in
                            NBSheetCaption(text: state.0).frame(width: 206, alignment: .leading)
                        }
                    }
                    ForEach(kinds, id: \.0) { kind in
                        HStack(spacing: 16) {
                            Text(kind.0)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(NBColor.inkTertiary)
                                .frame(width: 120, alignment: .leading)
                            ForEach(states, id: \.0) { state in
                                NBButton(kind.1, icon: kind.2, kind: kind.3, stretches: true) {}
                                    .environment(\.nbForcedState, state.1 ?? .rest)
                                    .disabled(state.1 == nil)
                                    .frame(width: 206)
                            }
                        }
                    }
                    Rectangle().fill(NBColor.hairline).frame(height: 0.5).padding(.vertical, 4)
                    HStack(spacing: 14) {
                        Text("размеры")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(NBColor.inkTertiary)
                            .frame(width: 120, alignment: .leading)
                        ForEach(NBButtonStyle.Size.allCases, id: \.self) { size in
                            NBButton(size == .small ? "Малая" : size == .regular ? "Обычная" : "Крупная",
                                     icon: .jump, kind: .secondary, size: size) {}
                        }
                        Spacer().frame(width: 12)
                        ForEach([NBIcon.settings, .soundOn, .pin, .copy, .close], id: \.self) { icon in
                            NBButton(icon: icon, kind: .secondary) {}
                        }
                        ForEach([NBIcon.settings, .folder], id: \.self) { icon in
                            NBButton(icon: icon, kind: .ghost) {}
                                .environment(\.nbForcedState, .hover)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 20) {
                NBSheetSection(number: "05.1", title: "Переключатели", note: "пружинящая ручка") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 22) {
                            toggle("выкл", false, .rest)
                            toggle("вкл", true, .rest)
                            toggle("наведение", true, .hover)
                            toggle("нажатие", false, .press)
                            toggle("готово", true, .rest, accent: .done)
                            toggle("работает", true, .rest, accent: .working)
                        }
                        Toggle("Звуки уведомлений", isOn: .constant(true))
                            .toggleStyle(NBToggleStyle())
                            .frame(width: 330)
                    }
                }
                NBSheetSection(number: "05.2", title: "Сегменты", note: "плашка скользит") {
                    VStack(alignment: .leading, spacing: 14) {
                        NBSegmentedPicker(selection: .constant(1), options: [
                            .init(0, "Компактно", icon: .tray),
                            .init(1, "Подробно", icon: .read),
                            .init(2, "Авто", icon: .sparkle),
                        ])
                        .frame(width: 330)
                        NBSegmentedPicker(selection: .constant("claude"), options: [
                            .init("claude", "Claude"), .init("codex", "Codex"), .init("kimi", "Kimi"),
                        ], accent: .brand)
                        .frame(width: 330)
                        NBSegmentedPicker(selection: .constant(0), options: [
                            .init(0, icon: .soundOn), .init(1, icon: .bell), .init(2, icon: .soundOff),
                        ])
                        .frame(width: 150)
                        .environment(\.nbForcedState, NBForcedState(hovered: true, pressed: nil))
                    }
                }
            }
            NBSheetSection(number: "05.3", title: "Чипы, бейджи, клавиши", note: "числа перекатываются, чипы выпрыгивают") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        NBChip("работает", icon: .working, accent: .working, count: 2)
                        NBChip("ждёт", icon: .waiting, accent: .waiting, count: 1)
                        NBChip("ошибка", icon: .error, accent: .error, count: 1)
                        NBChip("готово", icon: .done, accent: .done, count: 3)
                        NBChip("простаивает", accent: .idle, dot: true)
                        NBChip("новое", icon: .sparkle, accent: .magic, style: .filled)
                    }
                    HStack(spacing: 8) {
                        NBChip("Claude", accent: .claude, style: .filled)
                        NBChip("Codex", accent: .codex, style: .filled)
                        NBChip("Kimi", accent: .kimi, style: .filled)
                        NBChip("Claude", accent: .claude, selected: true)
                        NBChip("Bash", icon: .terminal, style: .outline)
                        NBChip("Edit", icon: .edit, style: .outline)
                            .environment(\.nbForcedState, .hover)
                        NBChip("weather-app", icon: .folder, style: .neutral, onRemove: {})
                        Spacer().frame(width: 10)
                        NBBadge(count: 3)
                        NBBadge(count: 12, accent: .brand)
                        Spacer().frame(width: 10)
                        NBKeycap(text: "⌘Y", highlighted: true)
                        NBKeycap(text: "⌘N")
                        NBKeycap(text: "⌘T")
                    }
                }
            }
            HStack(alignment: .top, spacing: 20) {
                NBSheetSection(number: "05.4", title: "Прогресс", note: "заливка на пружине, светящаяся голова") {
                    VStack(alignment: .leading, spacing: 16) {
                        usage("5 часов", 0.18, "сброс через 2 ч 10 мин")
                        usage("7 дней", 0.42, "сброс через 3 д 4 ч")
                        usage("Opus", 0.74, "сброс в пн 09:00")
                        usage("Лимит", 0.93, "почти исчерпан")
                        HStack(spacing: 18) {
                            ForEach([0.18, 0.42, 0.74, 0.93], id: \.self) { v in
                                NBProgressRing(value: v, lineWidth: 3.5, size: 38) {
                                    Text("\(Int(v * 100))")
                                        .font(.nbNumeric(10.5, weight: 760))
                                        .foregroundStyle(NBColor.ink)
                                }
                            }
                            NBProgressRing(value: 0.62, accent: .done, lineWidth: 2.5, size: 22)
                            NBProgressRing(value: 0.3, accent: .brand, lineWidth: 2.5, size: 22)
                        }
                    }
                    .frame(width: 458)
                }
                NBSheetSection(number: "05.5", title: "Ползунки", note: "ручка растёт, пузырь со значением") {
                    VStack(alignment: .leading, spacing: 22) {
                        slider("покой", 0.35, .rest)
                        slider("наведение", 0.55, .hover)
                        slider("перетаскивание", 0.7, .press).padding(.top, 14)
                        NBSlider(value: .constant(4), range: 0...8, step: 1, accent: .done,
                                 format: { "\(Int($0)) с" })
                            .environment(\.nbForcedState, .press)
                            .padding(.top, 14)
                    }
                    .frame(width: 458)
                }
            }
        }
    }

    private func toggle(_ caption: String, _ on: Bool, _ state: NBForcedState, accent: NBAccent = .brand) -> some View {
        VStack(spacing: 8) {
            NBSwitch(isOn: .constant(on), accent: accent)
                .environment(\.nbForcedState, state)
            NBSheetCaption(text: caption)
        }
    }

    private func usage(_ title: String, _ value: Double, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).nbText(.bodyStrong).foregroundStyle(NBColor.ink)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.nbNumeric(13, weight: 760))
                    .foregroundStyle(NBAccent.usage(value).bright)
            }
            NBProgressBar(value: value, marks: [0.8])
            Text(note).nbText(.caption).foregroundStyle(NBColor.inkTertiary)
        }
    }

    private func slider(_ caption: String, _ value: Double, _ state: NBForcedState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NBSheetCaption(text: caption)
            NBSlider(value: .constant(value), minimumIcon: .soundOff, maximumIcon: .soundOn)
                .environment(\.nbForcedState, state)
        }
    }
}

// MARK: - 06 Settings panel (composition)

/// The ⚙️ panel built only from design-system pieces, inside the island silhouette.
struct NBSheetSettingsMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("06")
                        .font(.nbNumeric(11, weight: 800))
                        .foregroundStyle(NBAccent.brand.bright)
                    Text("Сборка: панель настроек в раскрытом острове")
                        .font(.manrope(15, weight: 740))
                        .foregroundStyle(NBColor.ink)
                    Text("только детали дизайн-системы")
                        .nbText(.callout)
                        .foregroundStyle(NBColor.inkTertiary)
                }
                .padding(.leading, 4)
                island
            }
            HStack(alignment: .top, spacing: 28) {
                toast
                widgets
            }
        }
    }

    private var island: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                NBIconTile(icon: .settings, accent: .brand, size: 30, active: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Настройки").nbText(.title).foregroundStyle(NBColor.ink)
                    Text("NotchBuddy 1.0 · всё локально").nbText(.caption).foregroundStyle(NBColor.inkTertiary)
                }
                Spacer()
                NBButton(icon: .close, kind: .ghost, size: .small) {}
            }
            NBSegmentedPicker(selection: .constant(0), options: [
                .init(0, "Остров", icon: .sparkle), .init(1, "Звук", icon: .soundOn),
                .init(2, "Виджеты", icon: .calendar), .init(3, "Агенты", icon: .agent),
            ])
            NBSectionHeader("Остров")
            NBGroup {
                NBSettingsRow(icon: .tray, accent: .brand, title: "Вид списка", subtitle: "Карточки сессий") {
                    NBSegmentedPicker(selection: .constant(1), options: [.init(0, "Кратко"), .init(1, "Подробно")], height: 24)
                        .frame(width: 150)
                }
                NBRowDivider()
                NBSettingsRow(icon: .pin, accent: .magic, iconValue: 1, title: "Открывать при наведении",
                              subtitle: "Задержка 90 мс, закрытие через 350 мс") {
                    NBSwitch(isOn: .constant(true))
                }
                NBRowDivider()
                NBSettingsRow(icon: .done, accent: .done, title: "Праздновать «Готово»", subtitle: "Зелёная вспышка и салют") {
                    NBSwitch(isOn: .constant(true), accent: .done)
                }
            }
            NBSectionHeader("Звук") {
                NBChip("вкл", accent: .done, dot: true)
            }
            NBGroup {
                NBSettingsRow(icon: .soundOn, accent: .working, title: "Звуки", subtitle: "«Готово» и «ждёт тебя»") {
                    NBSwitch(isOn: .constant(true))
                }
                NBRowDivider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Громкость").nbText(.bodyStrong).foregroundStyle(NBColor.ink)
                        Spacer()
                        Text("70%").font(.nbNumeric(12, weight: 700)).foregroundStyle(NBColor.inkSecondary)
                    }
                    NBSlider(value: .constant(0.7), minimumIcon: .soundOff, maximumIcon: .soundOn)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            NBSectionHeader("Агенты")
            HStack(spacing: 8) {
                NBChip("Claude", accent: .claude, selected: true)
                NBChip("Codex", accent: .codex, selected: true)
                NBChip("Kimi", accent: .kimi)
                Spacer()
                NBButton("Хуки", icon: .wrench, kind: .secondary, size: .small) {}
            }
            HStack(spacing: 8) {
                NBButton("Открыть логи", icon: .folder, kind: .ghost, size: .regular) {}
                Spacer()
                NBButton("Сбросить", kind: .destructive, size: .regular) {}
                NBButton("Готово", icon: .check, kind: .primary, size: .regular) {}
                    .environment(\.nbForcedState, .hover)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: 520)
        .background {
            IslandShape(earRadius: 14, bottomRadius: 30)
                .fill(Color.black)
                .padding(.horizontal, -14)
                .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
        }
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { desktop }
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 6, bottomLeading: 24, bottomTrailing: 24, topTrailing: 6),
                                          style: .continuous))
        .overlay(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 6, bottomLeading: 24, bottomTrailing: 24, topTrailing: 6),
                                        style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// A slice of a Mac screen: wallpaper and menu bar, the island flush with the top edge.
    private var desktop: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.30, green: 0.24, blue: 0.46), Color(red: 0.12, green: 0.13, blue: 0.24),
                                    Color(red: 0.07, green: 0.08, blue: 0.14)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [NBAccent.magic.base.opacity(0.35), .clear], center: UnitPoint(x: 0.1, y: 0.25),
                           startRadius: 0, endRadius: 320)
            RadialGradient(colors: [NBAccent.working.base.opacity(0.28), .clear], center: UnitPoint(x: 0.95, y: 0.8),
                           startRadius: 0, endRadius: 360)
            HStack {
                Text("\u{F8FF}").font(.system(size: 14))
                Text("Terminal").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("Ср 30 сент. 22:41").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Color.white.opacity(0.08))
        }
    }

    private var toast: some View {
        VStack(alignment: .leading, spacing: 10) {
            NBSheetCaption(text: "тост «Готово» · overlay")
            HStack(spacing: 12) {
                NBIconView(.done, size: 30, color: NBAccent.done.base, tone: NBAccent.done.base.opacity(0.25))
                    .nbGlow(NBAccent.done.base, radius: 10, intensity: 0.6)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Готово").nbText(.title).foregroundStyle(NBColor.ink)
                    Text("Почини падающие тесты · за 4:12").nbText(.callout).foregroundStyle(NBColor.inkSecondary)
                }
                Spacer()
                NBButton("Перейти", icon: .jump, kind: .tinted(.done), size: .small) {}
            }
            .padding(14)
            .frame(width: 440)
            .nbSurface(.overlay, radius: 18, accent: .done)
        }
    }

    private var widgets: some View {
        VStack(alignment: .leading, spacing: 10) {
            NBSheetCaption(text: "островки-виджеты из тех же деталей")
            HStack(spacing: 12) {
                widget(icon: .play, accent: .magic, title: "Музыка", value: "Nils Frahm — Says") {
                    HStack(spacing: 10) {
                        NBIconView(.previous, size: 14, color: NBColor.inkSecondary)
                        NBIconView(.pause, size: 16)
                        NBIconView(.next, size: 14, color: NBColor.inkSecondary)
                        NBProgressBar(value: 0.38, accent: .magic, height: 4)
                    }
                }
                widget(icon: .calendar, accent: .error, title: "Календарь", value: "Созвон через 12 мин") {
                    HStack(spacing: 8) {
                        NBIconView(.timer, size: 14, color: NBAccent.waiting.base, value: 0.8)
                        Text("14:30 – 15:00").font(.nbNumeric(11, weight: 680)).foregroundStyle(NBColor.inkSecondary)
                    }
                }
            }
            HStack(spacing: 12) {
                widget(icon: .battery, accent: .done, title: "Батарея", value: "72% · 3 ч 40 мин") {
                    NBProgressBar(value: 0.72, accent: .done, height: 4)
                }
                widget(icon: .cpu, accent: .working, title: "Процессор", value: "18% · 52 °C") {
                    NBProgressBar(value: 0.18, accent: .working, height: 4)
                }
            }
        }
    }

    private func widget<Extra: View>(icon: NBIcon, accent: NBAccent, title: String, value: String,
                                     @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                NBIconTile(icon: icon, accent: accent, size: 24)
                Text(title).nbText(.eyebrow).foregroundStyle(NBColor.inkTertiary)
            }
            Text(value).nbText(.bodyStrong).foregroundStyle(NBColor.ink).lineLimit(1)
            extra()
        }
        .padding(14)
        .frame(width: 204, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                          lineWidth: 0.75))
    }
}
