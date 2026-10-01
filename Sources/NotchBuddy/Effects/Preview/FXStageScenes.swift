import AppKit
import QuartzCore
import SwiftUI
import NotchBuddyCore

/// Filmstrips of the effects exactly as the island plays them on its stage (`IslandEffectsDirector`): the calm "done"
/// celebration, the attention rings and the permission rim (followers baked from a silhouette motion), the red rim
/// flash and the hover sheen.
@MainActor
enum FXStageScenes {
    static var all: [FXScene] { [calmDoneNotice, calmDoneNotch, calmDonePill, attention, permissionRim, errorRim, sheen] }

    private static func done(_ name: String, _ title: String, metrics m: IslandMetrics, notice: Bool) -> FXScene {
        FXScene(name: name, title: title,
                note: "Как на острове: тонкие зелёные линии обегают контур и встречаются внизу, одно чёткое кольцо уходит "
                    + "от контура, немного искр у галочки, без ауры.",
                metrics: m, times: FXScenes.celebrationTimes, build: { stage in
            let (image, size) = notice ? FXMock.notice(m)
                : FXMock.pill(m, status: "готово", tint: SessionStatus.finished.tint)
            let g = FXMock.geometry(notice ? .flash : .collapsed, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            let anchor = notice ? FXMock.noticeBadge(m, canvas: stage.canvas, size: size) : nil
            for layer in stage.addAllSlots({ DoneCelebrationLayer(slot: $0) }, following: o) {
                layer.seed = 11
                layer.play(at: stage.t0, style: .calm, anchor: anchor)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 60, below: notice ? 64 : 80) })
    }

    static var calmDoneNotice: FXScene {
        done("island-done-notice", "Остров · «Готово» (calm)", metrics: FXMock.floating, notice: true)
    }

    static var calmDoneNotch: FXScene {
        done("island-done-notch", "Остров · «Готово» у выреза (calm)", metrics: FXMock.notched, notice: true)
    }

    static var calmDonePill: FXScene {
        done("island-done-pill", "Остров · «Готово» в закрытом острове (calm)", metrics: FXMock.floating, notice: false)
    }

    /// A follower on a settled island: its tracks are baked from a motion that stands still.
    private static func follow(_ follower: IslandSilhouetteFollower, stage: FXStage, g: IslandGeometry) {
        let host = CALayer()
        host.frame = stage.canvas
        host.actions = FXLayer.noActions
        stage.front.addSublayer(host)
        follower.attach(to: host)
        let timeline = IslandTimeline()
        let motion = IslandSilhouetteMotion(canvasWidth: stage.canvas.width, target: g, sample: { _ in (g, IslandPulse()) })
        follower.follow(motion, timeline: timeline, from: stage.t0, until: stage.t0 + 1.0 / 60)
    }

    static var attention: FXScene {
        let m = FXMock.floating
        return FXScene(name: "island-attention", title: "Остров · ждёт тебя (кольца + дышащий ободок)",
                       note: "Тонкий оранжевый ободок дышит по краю, раз в 2.4 с от контура уходит одно тонкое кольцо.",
                       metrics: m, times: [0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8, 2.1], build: { stage in
            let (image, size) = FXMock.pill(m, status: "ждёт 0:45", tint: SessionStatus.waitingForUser.tint)
            let g = FXMock.geometry(.collapsed, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            follow(IslandAttentionFollower(tint: SessionStatus.waitingForUser.tint, reduceMotion: false), stage: stage, g: g)
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 60, below: 60) })
    }

    static var permissionRim: FXScene {
        let m = FXMock.floating
        return FXScene(name: "island-permission", title: "Остров · карточка разрешения (тонкий ободок)",
                       note: "Ободок цвета карточки медленно дышит (2.8 с); свой ореол карточки остаётся как был.",
                       metrics: m, times: [0, 0.7, 1.4, 2.1], build: { stage in
            let (image, size) = FXMock.card(m)
            let g = FXMock.geometry(.permission, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            follow(IslandPermissionRim(tint: SessionStatus.waitingForUser.tint, reduceMotion: false), stage: stage, g: g)
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 40, below: 40) })
    }

    static var errorRim: FXScene {
        let m = FXMock.floating
        return FXScene(name: "island-error", title: "Остров · ошибка (красный ободок)",
                       note: "Вместе со встряской: край вспыхивает красным и гаснет, без ауры вокруг.",
                       metrics: m, times: [0, 0.05, 0.1, 0.2, 0.35, 0.5, 0.7, 0.85], build: { stage in
            let (image, size) = FXMock.pill(m, status: "ошибка", tint: SessionStatus.error.tint)
            let g = FXMock.geometry(.collapsed, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            stage.add(ErrorFlashLayer(slot: .front), following: o).play(at: stage.t0)
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 60, below: 50) })
    }

    static var sheen: FXScene {
        let m = FXMock.floating
        return FXScene(name: "island-sheen", title: "Остров · наведение (мягкий блик)",
                       note: "Полоса света один раз проходит по острову, едва заметно (пик 8.5 %).",
                       metrics: m, times: [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.72], build: { stage in
            let (image, size) = FXMock.pill(m, status: "работает 2:14", tint: SessionStatus.working.tint)
            let g = FXMock.geometry(.collapsed, m, size, hovering: true)
            stage.placeIsland(g, image: image, contentSize: size)
            let layer = stage.add(HoverSheenLayer(slot: .front), following: stage.outline(g))
            layer.look.peak = 0.085
            layer.sweep(at: stage.t0, force: true)
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 50, below: 40) })
    }
}
