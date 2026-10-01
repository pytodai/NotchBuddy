import AppKit
import SwiftUI

// MARK: - 01 Typography

struct NBSheetTypography: View {
    private func sample(_ style: NBTextStyle) -> String {
        switch style {
        case .display: return "Готово за 4:12"
        case .title: return "Почини падающие тесты"
        case .headline: return "Сделай графики плавнее и добавь анимации"
        case .body: return "Claude Code просит разрешения выполнить команду в терминале."
        case .bodyStrong: return "Выполнить команду · Изменить файлы"
        case .callout: return "Обновил hero-блок и адаптив для мобильных"
        case .caption: return "сброс через 2 ч 10 мин · 7 мин назад"
        case .eyebrow: return "Сессии · Звук · Виджеты"
        case .numeric: return "0:45   1:11   2:14   18%   42%"
        case .numericLarge: return "42%   12:08"
        case .code: return "swift build -c release 2>&1 | tail -20"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            NBSheetSection(number: "01", title: "Типографика", note: "Manrope Variable, SF Mono для кода") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(NBTextStyle.allCases.enumerated()), id: \.element) { index, style in
                        HStack(alignment: .firstTextBaseline, spacing: 20) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(style.sheetName)
                                    .font(.manrope(12, weight: 720))
                                    .foregroundStyle(NBColor.ink)
                                Text(spec(style))
                                    .font(.nbNumeric(10, weight: 560))
                                    .foregroundStyle(NBColor.inkTertiary)
                            }
                            .frame(width: 150, alignment: .leading)
                            Text(sample(style))
                                .nbText(style)
                                .foregroundStyle(color(style))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(".nbText(.\(style.rawValue))")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(NBColor.inkQuaternary)
                        }
                        .padding(.vertical, 12)
                        if index < NBTextStyle.allCases.count - 1 {
                            Rectangle().fill(NBColor.hairline).frame(height: 0.5)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 20) {
                NBSheetSection(number: "01.1", title: "Ось веса", note: "200 … 800, любой шаг") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .lastTextBaseline, spacing: 18) {
                            ForEach([300, 400, 500, 600, 700, 800] as [CGFloat], id: \.self) { w in
                                VStack(spacing: 6) {
                                    Text("Жж")
                                        .font(.manrope(34, weight: w))
                                        .foregroundStyle(NBColor.ink)
                                    Text("\(Int(w))")
                                        .font(.nbNumeric(10, weight: 600))
                                        .foregroundStyle(NBColor.inkTertiary)
                                }
                            }
                        }
                        Text("Вес подобран под чёрный фон: основной текст — 520, заголовки — 660–780.")
                            .nbText(.caption)
                            .foregroundStyle(NBColor.inkTertiary)
                    }
                }
                NBSheetSection(number: "01.2", title: "Табличные цифры", note: "часы не дрожат") {
                    HStack(alignment: .top, spacing: 28) {
                        digits(title: "Пропорциональные", tabular: false)
                        digits(title: "Табличные · .numeric", tabular: true)
                    }
                }
            }
        }
    }

    private func digits(title: String, tabular: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            NBSheetCaption(text: title)
            ForEach(["1:11", "4:08", "0:45", "11:11"], id: \.self) { value in
                Text(value)
                    .font(tabular ? .nbNumeric(20, weight: 700) : .manrope(20, weight: 700))
                    .foregroundStyle(tabular ? NBColor.ink : NBColor.inkSecondary)
            }
        }
    }

    private func spec(_ style: NBTextStyle) -> String {
        let size = style.size == style.size.rounded() ? "\(Int(style.size))" : String(format: "%.1f", style.size)
        let tracking = style.tracking == 0 ? "0" : String(format: "%+.2f", style.tracking)
        return style == .code ? "\(size) pt · SF Mono" : "\(size) pt · \(Int(style.weight)) · \(tracking)"
    }

    private func color(_ style: NBTextStyle) -> Color {
        switch style {
        case .callout, .code: return NBColor.inkSecondary
        case .caption, .eyebrow: return NBColor.inkTertiary
        default: return NBColor.ink
        }
    }
}

// MARK: - 02 Color

struct NBSheetColor: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            NBSheetSection(number: "02", title: "Статусы", note: "каждый акцент в шести силах: base · bright · deep · soft · edge · glow") {
                HStack(spacing: 14) {
                    ForEach(NBAccent.statuses) { accent in
                        accentCard(accent, icon: icon(for: accent))
                    }
                }
            }
            NBSheetSection(number: "02.1", title: "Интерфейс и агенты", note: "акцент агента — только в его знаке и чипе") {
                HStack(spacing: 14) {
                    ForEach(NBAccent.interface + NBAccent.agents) { accent in
                        accentCard(accent, icon: agentIcon(accent))
                    }
                }
            }
            HStack(alignment: .top, spacing: 20) {
                NBSheetSection(number: "02.2", title: "Чернила", note: "контраст на чёрном / на карточке") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(NBColor.inkLevels, id: \.name) { level in
                            HStack(spacing: 14) {
                                Text("Почини тесты")
                                    .nbText(.headline)
                                    .foregroundStyle(Color.white.opacity(level.opacity))
                                    .frame(width: 180, alignment: .leading)
                                Text(level.name)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(NBColor.inkTertiary)
                                    .frame(width: 110, alignment: .leading)
                                Text(ratio(level.opacity, over: 0))
                                    .font(.nbNumeric(11, weight: 700))
                                    .foregroundStyle(NBColor.inkSecondary)
                                    .frame(width: 58, alignment: .trailing)
                                Text(ratio(level.opacity, over: 0.065))
                                    .font(.nbNumeric(11, weight: 700))
                                    .foregroundStyle(NBColor.inkTertiary)
                                    .frame(width: 58, alignment: .trailing)
                            }
                        }
                    }
                }
                NBSheetSection(number: "02.3", title: "Свечение", note: ".nbGlow") {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 26) {
                            ForEach([NBAccent.working, .waiting, .done, .error], id: \.id) { accent in
                                VStack(spacing: 10) {
                                    Circle().fill(accent.fill)
                                        .frame(width: 22, height: 22)
                                        .nbGlow(accent.base, radius: 12)
                                    NBSheetCaption(text: accent.name)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        HStack(spacing: 12) {
                            NBChip("работает", icon: .working, accent: .working, style: .filled)
                                .nbGlow(NBAccent.working.base, radius: 10, intensity: 0.5)
                            NBChip("готово", icon: .done, accent: .done, style: .filled)
                                .nbGlow(NBAccent.done.base, radius: 10, intensity: 0.5)
                            NBIconTile(icon: .sparkle, accent: .magic, size: 28)
                                .nbGlow(NBAccent.magic.base, radius: 12, intensity: 0.5)
                        }
                    }
                }
            }
            NBSheetSection(number: "02.4", title: "Поверхности и высота", note: "на чёрном высоту даёт свет, а не тень") {
                HStack(spacing: 14) {
                    ForEach(NBElevation.allCases) { elevation in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(elevation.sheetName)
                                .nbText(.bodyStrong)
                                .foregroundStyle(NBColor.ink)
                            Text(note(elevation))
                                .nbText(.caption)
                                .foregroundStyle(NBColor.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        .nbSurface(elevation, radius: NBRadius.card)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func note(_ e: NBElevation) -> String {
        switch e {
        case .inset: return "код, дорожки, поля"
        case .flat: return "строки без фона"
        case .raised: return "карточки сессий"
        case .floating: return "меню и поповеры"
        case .overlay: return "тосты поверх всего"
        }
    }

    private func icon(for accent: NBAccent) -> NBIcon {
        switch accent.id {
        case "working": return .working
        case "waiting": return .waiting
        case "done": return .done
        case "error": return .error
        default: return .idle
        }
    }

    private func agentIcon(_ accent: NBAccent) -> NBIcon {
        switch accent.id {
        case "brand": return .settings
        case "neutral": return .terminal
        case "magic": return .sparkle
        default: return .agent
        }
    }

    private func ratio(_ opacity: Double, over gray: Double) -> String {
        let r = NBContrast.ratio(NBContrast.whiteOver(gray: gray, opacity: opacity), Color(white: gray))
        return String(format: "%.1f:1", r)
    }

    private func accentCard(_ accent: NBAccent, icon: NBIcon) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                NBIconView(icon, size: 18, color: accent.base, tone: accent.base.opacity(0.24), loops: true)
                Text(accent.name)
                    .nbText(.bodyStrong)
                    .foregroundStyle(accent.bright)
                    .lineLimit(1)
            }
            HStack(spacing: 0) {
                ForEach([accent.bright, accent.base, accent.deep], id: \.self) { c in
                    Rectangle().fill(c)
                }
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent.soft)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(accent.edge, lineWidth: 0.75))
                    .frame(height: 22)
                Capsule().fill(accent.fill)
                    .frame(height: 22)
                    .shadow(color: accent.glow, radius: 6)
            }
            Text(hex(accent.base))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(NBColor.inkTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nbSurface(.raised, radius: NBRadius.card, accent: accent)
    }

    private func hex(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

// MARK: - 03 Icons

struct NBSheetIcons: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(NBIcon.Group.allCases.enumerated()), id: \.element) { index, group in
                NBSheetSection(number: "03.\(index + 1)", title: group.title,
                               note: index == 0 ? "сетка 24, линия 1.8, скруглённые концы, второй тон" : nil) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(118), spacing: 12), count: 8),
                              alignment: .leading, spacing: 14) {
                        ForEach(group.icons) { icon in
                            cell(icon, tint: tint(icon))
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 20) {
                NBSheetSection(number: "03.5", title: "Размеры", note: "12 … 48 pt, линия не тоньше 1.25 pt") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach([NBIcon.settings, .terminal, .done], id: \.self) { icon in
                            HStack(alignment: .center, spacing: 22) {
                                ForEach([12, 14, 16, 20, 24, 32, 48] as [CGFloat], id: \.self) { size in
                                    NBIconView(icon, size: size, color: icon == .done ? NBAccent.done.base : NBColor.ink)
                                        .frame(width: 48, height: 48)
                                }
                            }
                        }
                    }
                }
                NBSheetSection(number: "03.6", title: "Состояния", note: "value") {
                    VStack(alignment: .leading, spacing: 14) {
                        stateRow(.soundOn, values: [1, 0.5, 0], labels: ["вкл", "", "выкл"])
                        stateRow(.play, values: [0, 0.5, 1], labels: ["▶", "", "❚❚"])
                        stateRow(.pin, values: [0, 0.5, 1], labels: ["", "", "закреплён"])
                        stateRow(.battery, values: [0.9, 0.4, 0.12], labels: ["90%", "40%", "12%"])
                    }
                }
            }
        }
    }

    private func tint(_ icon: NBIcon) -> NBAccent? {
        switch icon {
        case .working: return .working
        case .waiting: return .waiting
        case .done: return .done
        case .error: return .error
        case .idle: return .idle
        case .sparkle: return .magic
        default: return nil
        }
    }

    private func cell(_ icon: NBIcon, tint: NBAccent?) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.03)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                NBIconView(icon, size: 30, color: tint?.base ?? NBColor.ink,
                           tone: tint.map { $0.base.opacity(0.24) }, loops: icon.loops)
            }
            .frame(width: 64, height: 64)
            VStack(spacing: 2) {
                Text(icon.title)
                    .font(.manrope(11.5, weight: 680))
                    .foregroundStyle(NBColor.ink)
                Text(".\(icon.rawValue)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(NBColor.inkTertiary)
            }
        }
        .frame(width: 118)
    }

    private func stateRow(_ icon: NBIcon, values: [Double], labels: [String]) -> some View {
        HStack(spacing: 18) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                VStack(spacing: 4) {
                    NBIconView(icon, size: 26, value: v)
                    NBSheetCaption(text: labels[i].isEmpty ? String(format: "%.1f", v) : labels[i])
                }
                .frame(width: 60)
            }
        }
    }
}

/// Every icon large (56 pt), to judge the drawing itself.
struct NBSheetIconsLarge: View {
    var body: some View {
        NBSheetSection(number: "03.7", title: "Крупно", note: "56 pt: видно второй тон и скругления") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 18), count: 9), alignment: .leading, spacing: 18) {
                ForEach(NBIcon.allCases) { icon in
                    VStack(spacing: 6) {
                        NBIconView(icon, size: 56, loops: icon.loops)
                        NBSheetCaption(text: icon.title)
                    }
                    .frame(width: 96)
                }
            }
        }
    }
}

// MARK: - 04.1 Motion curves

/// Every motion token plotted: progress over time, overshoot visible above the 1.0 line.
struct NBSheetMotionCurves: View {
    private let tokens: [(String, String, MotionCurve, NBAccent)] = [
        ("press", "0.20 / 0.62", NBMotion.press, .working),
        ("release", "0.36 / 0.52 · отскок", NBMotion.release, .working),
        ("hover", "0.26 / 0.82", NBMotion.hover, .neutral),
        ("knob", "0.34 / 0.64", NBMotion.knob, .brand),
        ("pill", "0.36 / 0.74", NBMotion.pill, .brand),
        ("fill", "0.62 / 0.86", NBMotion.fill, .done),
        ("morph", "0.40 / 0.74", NBMotion.morph, .magic),
        ("pop", "0.32 / 0.56", NBMotion.pop, .waiting),
        ("iconHover", "0.44 / 0.60", NBMotion.iconHover, .magic),
        ("iconWobble", "easeOut 0.62 с", NBMotion.iconWobble, .error),
        ("celebrate", "easeOut 0.9 с", NBMotion.celebrate, .done),
        ("fade", "easeOut 0.16 с", NBMotion.fade, .idle),
    ]

    var body: some View {
        NBSheetSection(number: "04.1", title: "Кривые движения", note: "пружины: response / damping · 0 … 0.9 с") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 6), spacing: 14) {
                ForEach(tokens, id: \.0) { token in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(token.0).font(.manrope(11.5, weight: 720)).foregroundStyle(NBColor.ink)
                            Spacer(minLength: 4)
                        }
                        Text(token.1).font(.nbNumeric(9.5, weight: 600)).foregroundStyle(NBColor.inkTertiary)
                        plot(token.2, accent: token.3)
                            .frame(height: 58)
                    }
                    .padding(12)
                    .nbSurface(.raised, radius: 14)
                }
            }
        }
    }

    private func plot(_ curve: MotionCurve, accent: NBAccent) -> some View {
        Canvas { ctx, size in
            let duration = 0.9
            let top: CGFloat = 1.25
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(v) / top * size.height }
            var one = Path()
            one.move(to: CGPoint(x: 0, y: y(1)))
            one.addLine(to: CGPoint(x: size.width, y: y(1)))
            ctx.stroke(one, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var line = Path()
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            let steps = 90
            for i in 0...steps {
                let t = duration * Double(i) / Double(steps)
                let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(steps), y: y(curve.progress(t)))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                area.addLine(to: p)
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [accent.base.opacity(0.28), accent.base.opacity(0)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(accent.bright), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - 04 Icon motion

struct NBSheetIconMotion: View {
    enum Drive {
        case hover
        case value(Double, Double)
        case loop
    }

    struct Film: Identifiable {
        var icon: NBIcon
        var drive: Drive
        var accent: NBAccent?
        var id: String { "\(icon.rawValue)-\(label)" }

        var label: String {
            switch drive {
            case .hover: return "наведение"
            case .value: return "состояние"
            case .loop: return "цикл"
            }
        }
    }

    static let frames = 9

    static let films: [Film] = [
        Film(icon: .settings, drive: .hover),
        Film(icon: .pin, drive: .value(0, 1), accent: .brand),
        Film(icon: .soundOn, drive: .value(1, 0)),
        Film(icon: .play, drive: .value(0, 1)),
        Film(icon: .jump, drive: .hover),
        Film(icon: .copy, drive: .value(0, 1)),
        Film(icon: .folder, drive: .hover),
        Film(icon: .chevron, drive: .value(0, 1)),
        Film(icon: .close, drive: .hover),
        Film(icon: .done, drive: .value(0, 1), accent: .done),
        Film(icon: .error, drive: .hover, accent: .error),
        Film(icon: .working, drive: .loop, accent: .working),
        Film(icon: .waiting, drive: .loop, accent: .waiting),
        Film(icon: .idle, drive: .loop, accent: .idle),
        Film(icon: .terminal, drive: .loop),
        Film(icon: .web, drive: .loop),
        Film(icon: .agent, drive: .hover),
        Film(icon: .edit, drive: .hover),
        Film(icon: .mcp, drive: .hover),
        Film(icon: .wrench, drive: .hover),
        Film(icon: .plan, drive: .hover),
        Film(icon: .bell, drive: .hover, accent: .waiting),
        Film(icon: .sparkle, drive: .hover, accent: .magic),
        Film(icon: .calendar, drive: .hover),
        Film(icon: .tray, drive: .hover),
        Film(icon: .cpu, drive: .loop),
        Film(icon: .next, drive: .hover),
        Film(icon: .battery, drive: .value(1, 0.1)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            films
            NBSheetMotionCurves()
        }
    }

    private var films: some View {
        NBSheetSection(number: "04", title: "Движение иконок",
                       note: "кадры сняты с тех же кривых, что играют вживую (NBMotion)") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)],
                      alignment: .leading, spacing: 14) {
                ForEach(Self.films) { film in
                    row(film)
                }
            }
        }
    }

    private func row(_ film: Film) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(film.icon.title)
                    .font(.manrope(11.5, weight: 700))
                    .foregroundStyle(NBColor.ink)
                Text("\(film.label) · \(film.icon.motionNote)")
                    .font(.manrope(9.5, weight: 600))
                    .foregroundStyle(NBColor.inkTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 104, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<Self.frames, id: \.self) { i in
                    frame(film, index: i)
                }
            }
        }
    }

    private func frame(_ film: Film, index: Int) -> some View {
        let f = Double(index) / Double(Self.frames - 1)
        var state = NBIconState(hover: 0, value: film.icon.defaultValue, phase: film.icon.loops ? film.icon.restPhase : 0)
        switch film.drive {
        case .hover:
            let curve = film.icon.hoverCurve
            state.hover = curve.progress(pow(f, 1.35) * 0.62)
        case .value(let from, let to):
            let p = film.icon.valueCurve.progress(pow(f, 1.35) * (film.icon == .done ? 0.95 : 0.55))
            state.value = from + (to - from) * p
        case .loop:
            state.phase = f * Double(Self.frames - 1) / Double(Self.frames)
        }
        let color = film.accent?.base ?? NBColor.ink
        return NBIconGlyph(icon: film.icon, color: color, tone: color.opacity(0.22), accent: nil,
                           hover: state.hover, value: state.value, phase: state.phase)
            .frame(width: 26, height: 26)
            .frame(width: 42, height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(index == 0 ? 0.07 : 0.035)))
    }
}
