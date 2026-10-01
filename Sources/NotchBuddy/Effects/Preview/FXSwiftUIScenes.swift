import SwiftUI
import NotchBuddyCore

/// Filmstrips of the SwiftUI effects (number roll, press squish, card sheen, shake), drawn at explicit
/// moments with the same curves the live modifiers animate on.
@MainActor
enum FXSwiftUIScenes {
    static var all: [FXScene] { [numberRoll, pressSquish, cardSheen, cardShake] }

    /// Near-black: `ImageRenderer` drew a pure black fill as white next to an app icon image.
    private static let pill = Color(red: 0.012, green: 0.012, blue: 0.014)

    static var numberRoll: FXScene {
        let times = [0, 0.04, 0.08, 0.12, 0.16, 0.2, 0.26, 0.34, 0.45, 0.6]
        return FXScene(name: "number-roll", title: "NumberRoll · счётчики и часы",
                       note: "Каждая изменившаяся цифра уезжает вверх (число растёт) или вниз, начиная с правой; "
                           + "появившаяся цифра раздвигает место; «:» и «%» стоят на месте. Пружина 0.42 / 0.82.",
                       metrics: FXMock.floating, times: times, columns: 5, view: { t in
            let p = NumberRoll.curve.progress(t)
            let rows: [(String, String, Color)] = [
                ("9", "10", .white),
                ("2:59", "3:00", SessionStatus.working.tint),
                ("73 %", "71 %", .white.opacity(0.8)),
                ("+2", "+3", .white.opacity(0.7)),
            ]
            return AnyView(VStack(alignment: .trailing, spacing: 10) {
                ForEach(rows.indices, id: \.self) { i in
                    let row = rows[i]
                    NumberRollFace(from: row.0, to: row.1, progress: p, font: .system(size: 17, weight: .semibold))
                        .foregroundStyle(row.2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(pill))
            .frame(width: 130))
        })
    }

    static var pressSquish: FXScene {
        // Pressed at 0, released at 0.18.
        let release = 0.18
        let times = [0, 0.04, 0.1, 0.18, 0.22, 0.27, 0.33, 0.4, 0.5, 0.62]
        return FXScene(name: "press-squish", title: "PressSquish · нажатие и отпускание",
                       note: "Под пальцем кнопка сплющивается (−6 % по высоте, +2 % по ширине), на отпускании "
                           + "пружинит за форму и успокаивается. Нажата на 0 s, отпущена на 0.18 s.",
                       metrics: FXMock.floating, times: times, columns: 5, view: { t in
            let held = PressSquishFace.value(afterPress: min(t, release))
            let squish = t <= release ? held : held * PressSquishFace.value(afterRelease: t - release)
            return AnyView(VStack(spacing: 14) {
                Text("Разрешить")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 150, height: 34)
                    .background(Capsule().fill(Color.white))
                    .modifier(PressSquishFace(squish: squish, amount: 0.07))
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .modifier(PressSquishFace(squish: squish, amount: 0.1))
            }
            .frame(width: 170, height: 96)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(pill)))
        })
    }

    static var cardSheen: FXScene {
        let times = [0.08, 0.2, 0.32, 0.44, 0.56, 0.68]
        return FXScene(name: "card-sheen", title: "fxSheen · карточка сессии при наведении",
                       note: "SwiftUI-версия блика для любых карточек: одна мягкая полоса света за 0.75 s.",
                       metrics: FXMock.floating, times: times, columns: 3, view: { t in
            AnyView(sessionCard
                .fxSheen(RoundedRectangle(cornerRadius: 16, style: .continuous), trigger: 0)
                .environment(\.islandFilmTime, t)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(pill)))
        })
    }

    static var cardShake: FXScene {
        let shake = DampedShake.error
        let times = [0, 0.03, 0.06, 0.1, 0.14, 0.2, 0.28, 0.4]
        return FXScene(name: "card-shake", title: "fxShake · встряска карточки при ошибке",
                       note: "Затухающая синусоида (6 pt, 7.5 Гц, τ 0.12 s) с лёгким поворотом; Reduce Motion — без встряски.",
                       metrics: FXMock.floating, times: times, view: { t in
            let x = shake.offset(at: t)
            return AnyView(sessionCard
                .offset(x: x)
                .rotationEffect(.degrees(x * 0.12), anchor: .top)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(pill)))
        })
    }

    private static var sessionCard: some View {
        HStack(spacing: 10) {
            AgentMark(source: .claude, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Рефакторинг парсера хуков").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text("работает 2:14").font(.system(size: 12)).foregroundStyle(SessionStatus.working.tint)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}
