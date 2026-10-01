import AppKit
import QuartzCore
import SwiftUI
import NotchBuddyCore

/// The filmstrips `--render-effects` draws.
@MainActor
enum FXScenes {
    static var all: [FXScene] {
        [doneNotice, doneLive, doneWallpaper, donePill, doneCheck, doneNotch, doneCoalesced, doneReduced, attentionPill, attentionList, permissionCard,
         errorPill, errorReduced, sheenPill, sheenList, appearDrip, confettiNotice] + FXSwiftUIScenes.all + FXStageScenes.all
    }

    /// A mid-tone desktop behind the menu bar (black shapes and glows read differently on it).
    static let wallpaper = CGColor(srgbRed: 0.42, green: 0.47, blue: 0.56, alpha: 1)

    static var doneWallpaper: FXScene {
        var scene = doneNotice
        scene.name = "done-wallpaper"
        scene.title = "DoneCelebration · на светлых обоях"
        scene.note = "То же на средне-светлом фоне: зелёное свечение не должно превращаться в грязное пятно."
        scene.background = wallpaper
        scene.times = [0.2, 0.4, 0.54, 0.7, 0.9, 1.2]
        scene.columns = 3
        return scene
    }

    static let celebrationTimes: [Double] = [0, 0.08, 0.16, 0.24, 0.32, 0.40, 0.46, 0.54, 0.64, 0.76, 0.90, 1.05,
                                             1.2, 1.35, 1.5, 1.7]

    // MARK: Done

    static var doneNotice: FXScene {
        let m = FXMock.floating
        return FXScene(name: "done-notice", title: "DoneCelebration · уведомление «Готово»",
                       note: "Кометы бегут от ушек вниз и встречаются внизу по центру → вспышка, зелёная волна и аура, "
                           + "мягкая заливка острова; искры вылетают из галочки бейджа (anchor).",
                       metrics: m, times: celebrationTimes, build: { stage in
            let (image, size) = FXMock.notice(m)
            let g = FXMock.geometry(.flash, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            let anchor = FXMock.noticeBadge(m, canvas: stage.canvas, size: size)
            for layer in stage.addAllSlots({ DoneCelebrationLayer(slot: $0) }, following: o) {
                layer.seed = 11
                layer.play(at: stage.t0, anchor: anchor)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline) })
    }

    static var donePill: FXScene {
        let m = FXMock.floating
        return FXScene(name: "done-pill", title: "DoneCelebration · закрытый остров",
                       note: "Без якоря: искры сыплются вниз веером из точки встречи комет; волна вдвое короче, чем у высокого острова.",
                       metrics: m, times: celebrationTimes, build: { stage in
            let (image, size) = FXMock.pill(m, status: "готово", tint: SessionStatus.finished.tint)
            let g = FXMock.geometry(.collapsed, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ DoneCelebrationLayer(slot: $0) }, following: o) {
                layer.seed = 5
                layer.play(at: stage.t0)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 70, below: 80) })
    }

    /// As on screen: the closed island pops out into the notice on the flash spring (ear flare included)
    /// and the celebration starts as `IslandEffectsHostView` starts it (0.16 s later, laid out on the
    /// settled notice).
    static var doneLive: FXScene {
        let m = FXMock.floating
        return FXScene(name: "done-live", title: "DoneCelebration · вместе с появлением уведомления",
                       note: "Остров раскрывается из закрытого в уведомление пружиной flash; праздник стартует через 0.16 s, "
                           + "когда силуэт почти встал, и дальше следует за ним кадр в кадр.",
                       metrics: m, times: [0, 0.06, 0.12, 0.18, 0.26, 0.34, 0.44, 0.54, 0.64, 0.76, 0.9, 1.1, 1.3, 1.5, 1.7, 1.9],
                       build: { stage in
            let (image, size) = FXMock.notice(m)
            let pill = FXMock.geometry(.collapsed, m, CGSize(width: 250, height: m.barHeight))
            let target = FXMock.geometry(.flash, m, size)
            stage.placeIsland(pill, image: image, contentSize: size)
            let anchor = IslandEffects.noticeBadge(metrics: m, canvasWidth: stage.canvas.width, contentSize: size)
            let delay = 0.16
            var style = DoneCelebrationStyle.standard
            style.anchorBurst = max(0.3, style.anchorBurst - delay)
            for layer in stage.addAllSlots({ DoneCelebrationLayer(slot: $0) }, following: stage.outline(pill)) {
                layer.seed = 11
                layer.play(at: stage.t0 + delay, style: style, anchor: anchor, settled: stage.outline(target))
            }
            let reveal = IslandContentLayerParams.reveal(.pop, .flash).curve
            return { t in
                let g = pill.interpolated(to: target, IslandMotion.flash.progress(t))
                let pulse = IslandPulse.value(.earFlare(5), at: t)
                stage.follow(stage.outline(g, pulse: pulse), contentAlpha: Float(smoothstep(0, 0.45, reveal.progress(t))))
            }
        }, crop: { stage in stage.crop(stage.outline(FXMock.geometry(.flash, m, FXMock.notice(m).1))) })
    }

    static var doneCheck: FXScene {
        let m = FXMock.floating
        return FXScene(name: "done-check", title: "DoneCelebration · галочка рисуется самим эффектом",
                       note: "drawsCheck: где своего бейджа нет, эффект сам рисует галочку в точке anchor и осыпает её искрами.",
                       metrics: m, times: [0.1, 0.18, 0.26, 0.34, 0.42, 0.5, 0.6, 0.75, 0.9, 1.1, 1.3, 1.6], build: { stage in
            let (image, size) = FXMock.pillWithCheckSlot(m)
            let g = FXMock.geometry(.collapsed, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            let anchor = CGPoint(x: stage.canvas.midX - size.width / 2 + 12 + 8, y: m.barHeight / 2)
            var style = DoneCelebrationStyle.standard
            style.drawsCheck = true
            for layer in stage.addAllSlots({ DoneCelebrationLayer(slot: $0) }, following: o) {
                layer.seed = 17
                layer.play(at: stage.t0, style: style, anchor: anchor)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 50, below: 50) })
    }

    static var doneNotch: FXScene {
        let m = FXMock.notched
        return FXScene(name: "done-notch", title: "DoneCelebration · вырез (quiet)",
                       note: "«Готово» в полосе выреза: облегчённый стиль .quiet, искры из бейджа слева от камеры.",
                       metrics: m, times: celebrationTimes, build: { stage in
            let (image, size) = FXMock.notice(m)
            let g = FXMock.geometry(.flash, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            let anchor = FXMock.noticeBadge(m, canvas: stage.canvas, size: size)
            for layer in stage.addAllSlots({ DoneCelebrationLayer(slot: $0) }, following: o) {
                layer.seed = 3
                layer.play(at: stage.t0, style: .quiet, anchor: anchor)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 40, below: 70) })
    }

    static var doneCoalesced: FXScene {
        let m = FXMock.floating
        return FXScene(name: "done-coalesced", title: "DoneCelebration · три сессии подряд",
                       note: "CelebrationCoalescer: первая — полностью (0 s), следующие — «анкор» поверх (0.55 s, 1.0 s), без перезапуска.",
                       metrics: m, times: [0, 0.2, 0.4, 0.55, 0.65, 0.8, 1.0, 1.1, 1.25, 1.45, 1.7, 2.0], build: { stage in
            let (image, size) = FXMock.notice(m)
            let g = FXMock.geometry(.flash, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            var coalescer = CelebrationCoalescer()
            for layer in stage.addAllSlots({ DoneCelebrationLayer(slot: $0) }, following: o) {
                layer.seed = 21
            }
            for at in [0.0, 0.2, 0.55, 1.0] {
                let decision = coalescer.register(at: at)
                for case let layer as DoneCelebrationLayer in stage.effects {
                    switch decision {
                    case .play(let intensity): layer.play(at: stage.t0 + at, intensity: intensity)
                    case .encore: layer.play(at: stage.t0 + at, style: .encore)
                    case .absorb: break
                    }
                }
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline) })
    }

    static var doneReduced: FXScene {
        let m = FXMock.floating
        return FXScene(name: "done-reduced", title: "DoneCelebration · Reduce Motion",
                       note: "Только затухания: аура, заливка и контур появляются и гаснут, ничего не движется.",
                       metrics: m, times: [0, 0.2, 0.36, 0.6, 0.9, 1.2], columns: 3, build: { stage in
            let (image, size) = FXMock.notice(m)
            let g = FXMock.geometry(.flash, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ DoneCelebrationLayer(slot: $0) }, following: o) {
                layer.play(at: stage.t0, reduceMotion: true)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline) })
    }

    // MARK: Attention

    static var attentionPill: FXScene {
        let m = FXMock.floating
        return FXScene(name: "attention-pill", title: "AttentionPulse · закрытый остров",
                       note: "Оранжевые кольца по одному уходят от контура и гаснут; ободок дышит в такт (период 2.2 s, 30 fps).",
                       metrics: m, times: [0, 0.12, 0.25, 0.4, 0.55, 0.7, 0.85, 0.95, 1.1, 1.3, 1.5, 1.9], build: { stage in
            let (image, size) = FXMock.pill(m, status: "ждёт 0:45", tint: SessionStatus.waitingForUser.tint)
            let g = FXMock.geometry(.collapsed, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ AttentionPulseLayer(slot: $0) }, following: o) {
                layer.loopOrigin = stage.t0
                layer.setActive(true)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 48, below: 40) })
    }

    static var attentionList: FXScene {
        let m = FXMock.notched
        return FXScene(name: "attention-list", title: "AttentionPulse · открытый список (вырез)",
                       note: "Те же кольца вокруг большого острова: дальше (16 pt), но так же мягко.",
                       metrics: m, times: [0.1, 0.4, 0.7, 1.0], build: { stage in
            let (image, size) = FXMock.list(m)
            let g = FXMock.geometry(.expanded, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ AttentionPulseLayer(slot: $0) }, following: o) {
                layer.loopOrigin = stage.t0
                layer.setActive(true)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 30, below: 36) })
    }

    // MARK: Permission

    static var permissionCard: FXScene {
        let m = FXMock.floating
        return FXScene(name: "permission-card", title: "PermissionGlow · карточка разрешения",
                       note: "Оранжевая аура медленно дышит (2.8 s) после короткого «распускания»; снизу — тонкий ободок, гаснущий к ушкам.",
                       metrics: m, times: [0, 0.15, 0.35, 0.7, 1.4, 2.1], columns: 3, build: { stage in
            let (image, size) = FXMock.card(m)
            let g = FXMock.geometry(.permission, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ PermissionGlowLayer(slot: $0) }, following: o) {
                layer.loopOrigin = stage.t0
                layer.setActive(true)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 44, below: 50) })
    }

    // MARK: Error

    static var errorPill: FXScene {
        let m = FXMock.floating
        return FXScene(name: "error-pill", title: "ErrorFlash + встряска · закрытый остров",
                       note: "Красная вспышка ободка, аура и заливка изнутри; остров трясётся своей ErrorShake (здесь сдвиг всей сцены).",
                       metrics: m, times: [0, 0.03, 0.06, 0.1, 0.15, 0.22, 0.3, 0.4, 0.5, 0.62, 0.75, 0.9], build: { stage in
            let (image, size) = FXMock.pill(m, status: "ошибка", tint: SessionStatus.error.tint)
            let g = FXMock.geometry(.collapsed, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ ErrorFlashLayer(slot: $0) }, following: o) {
                layer.play(at: stage.t0)
            }
            return { t in stage.shift(x: ErrorShake.value(at: t)) }
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 44, below: 40) })
    }

    static var errorReduced: FXScene {
        let m = FXMock.floating
        return FXScene(name: "error-reduced", title: "ErrorFlash · Reduce Motion",
                       note: "Без встряски: красное свечение плавно появляется и гаснет.",
                       metrics: m, times: [0, 0.15, 0.33, 0.6, 0.85, 1.1], columns: 3, build: { stage in
            let (image, size) = FXMock.pill(m, status: "ошибка", tint: SessionStatus.error.tint)
            let g = FXMock.geometry(.collapsed, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ ErrorFlashLayer(slot: $0) }, following: o) {
                layer.play(at: stage.t0, reduceMotion: true)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 44, below: 40) })
    }

    // MARK: Sheen

    static var sheenPill: FXScene {
        let m = FXMock.floating
        return FXScene(name: "sheen-pill", title: "HoverSheen · наведение на закрытый остров",
                       note: "Мягкая диагональная полоса света один раз проходит по острову (обрезана его силуэтом), не чаще раза в 1.4 s.",
                       metrics: m, times: [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.72], build: { stage in
            let (image, size) = FXMock.pill(m, status: "работает 2:14", tint: SessionStatus.working.tint)
            let g = FXMock.geometry(.collapsed, m, size, hovering: true)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ HoverSheenLayer(slot: $0) }, following: o) {
                layer.sweep(at: stage.t0)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 30, below: 20) })
    }

    static var sheenList: FXScene {
        let m = FXMock.floating
        return FXScene(name: "sheen-list", title: "HoverSheen · открытый список",
                       note: "На широком острове полоса идёт дольше (до 1 s); свет ложится и на содержимое, как на стекло.",
                       metrics: m, times: [0.15, 0.35, 0.55, 0.75], build: { stage in
            let (image, size) = FXMock.list(m)
            let g = FXMock.geometry(.expanded, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ HoverSheenLayer(slot: $0) }, following: o) {
                layer.sweep(at: stage.t0)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 20, below: 20) })
    }

    // MARK: Appear

    static var appearDrip: FXScene {
        let m = FXMock.floating
        return FXScene(name: "appear-drip", title: "AppearDrip · остров «капает» из верхнего края",
                       note: "Сам остров растёт своей пружиной appear (без изменений); впереди него бежит чёрная капля, "
                           + "повисает на тонкой шейке и втягивается обратно.",
                       metrics: m, times: [0, 0.03, 0.06, 0.09, 0.12, 0.15, 0.19, 0.23, 0.28, 0.33, 0.39, 0.46],
                       background: FXScenes.wallpaper, build: { stage in
            let (image, size) = FXMock.pill(m, status: "работает 0:03", tint: SessionStatus.working.tint)
            let target = FXMock.geometry(.collapsed, m, size)
            let from = IslandLayout.geometry(mode: .hidden, metrics: m, content: size, hovering: false, pressed: false,
                                             lastPillWidth: target.width)
            stage.placeIsland(from, image: image, contentSize: size)
            let drips = stage.addAllSlots({ AppearDripLayer(slot: $0) }, following: stage.outline(from))
            for d in drips { d.play(at: stage.t0, target: stage.outline(target)) }
            let reveal = IslandContentLayerParams.reveal(.pop, .closed).curve
            return { t in
                let g = from.interpolated(to: target, IslandMotion.appear.progress(t))
                let alpha = Float(smoothstep(0, 0.45, reveal.progress(t)))
                stage.follow(stage.outline(g), contentAlpha: alpha)
            }
        }, crop: { stage in stage.crop(stage.outline(FXMock.geometry(.collapsed, m, FXMock.pill(m, status: "", tint: .white).1)),
                                       margin: 30, below: 30) })
    }

    // MARK: Confetti

    static var confettiNotice: FXScene {
        let m = FXMock.floating
        return FXScene(name: "confetti-notice", title: "Confetti-lite · веха",
                       note: "Две короткие хлопушки из нижних углов: полоски и кружки летят в стороны, кувыркаются и гаснут (~2 s).",
                       metrics: m, times: [0, 0.1, 0.2, 0.35, 0.5, 0.7, 0.9, 1.1, 1.35, 1.6, 1.85, 2.1], build: { stage in
            let (image, size) = FXMock.notice(m)
            let g = FXMock.geometry(.flash, m, size)
            stage.placeIsland(g, image: image, contentSize: size)
            let o = stage.outline(g)
            for layer in stage.addAllSlots({ ConfettiLayer(slot: $0) }, following: o) {
                layer.seed = 9
                layer.play(at: stage.t0)
            }
            return nil
        }, crop: { stage in stage.crop(stage.island!.outline, margin: 110, below: 230) })
    }
}
