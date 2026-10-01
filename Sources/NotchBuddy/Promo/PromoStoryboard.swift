import CoreGraphics
import NotchBuddyCore

// The promo video's storyboard: pure data. `NotchBuddy --render-promo <dir>` (PromoRenderer) plays it on the real island
// stage and films it. Tweak the beats, edit, camera and captions here; nothing else needs to change.
//
// Two clocks. STORY time is the island's own life: every beat (`beats`) happens at a story second, and the island's
// springs, cascades, pulses and effects run on it, at their real speed. VIDEO time is the film: the edit (`clock`) plays
// the story at 1× and may skip ahead at a cut, a dip or a dissolve (never slow motion, never a speed ramp); the camera,
// captions, titles, dips and dissolves are keyed in video seconds. Everything is a function of the video clock (nothing
// is stepped per frame), so the film is the same at any frame rate.
//
// The pace is a keynote product film's, kept tight: every beat holds 2–3 s, one camera move at a time, each eased from and to rest
// (no punch-ins, whips or match-cut runs), one caption at a time, hard cuts only on stillness. `scripts/promo/
// motion-check.py` checks a render for the jerks this rules out.
//
// Positions are unit coordinates: `.screen(x, y)` of the virtual screen, `.island(x, y)` of the island's silhouette
// box (0,0 top-left, 1,1 bottom-right; for the cursor, at the moment the move starts).

/// What the island shows (resolved by `PromoFakes`, in the render's language).
enum PromoScene: Equatable {
    /// No sessions (the notch alone).
    case empty
    /// Claude working.
    case first
    /// Claude and Codex working, Kimi finished.
    case trio
    /// Claude waiting on a permission card (Bash: git push).
    case card
    /// The card answered: Claude working on the push.
    case approved
    /// Claude finished: the "done" notice with its last message.
    case done
    /// After the notice: Claude finished, Codex working, Kimi finished.
    case settled
}

enum PromoPoint: Equatable {
    case screen(CGFloat, CGFloat)
    case island(CGFloat, CGFloat)
    /// Points of the virtual screen (the monitor's desk: `PromoDesk`).
    case points(CGFloat, CGFloat)
}

enum PromoGlow: Equatable {
    case card, finished
}

/// Settings → Остров → Стиль, and the screen the film shows.
enum PromoStyle: Equatable {
    /// «Чёлка» on the MacBook: flush with the top edge, around the camera housing.
    case notch
    /// «Островок» on the MacBook: the detached capsule below the camera housing.
    case island
    /// «Островок» on an external display without a notch (a desktop monitor on its stand, in a room): the capsule just
    /// below the top edge, as `IslandPlacement` places it on a notch-less screen.
    case monitor
}

enum PromoAction {
    /// `setContent`: a new mode (with the island's own entrance/exit unless given). `blur`: the content comes out of a
    /// blur while the silhouette opens (the app's reveal: a pre-blurred snapshot cross-fading to sharp).
    case island(IslandMode, PromoScene, entrance: IslandEntrance? = nil, exit: IslandExit? = nil,
                pulse: IslandPulse.Kind? = nil, glow: PromoGlow? = nil, blur: Bool = false)
    /// `updateData`: same mode, new sessions (rows arrive, the "+N" count grows).
    case data(PromoScene)
    /// The pointer rests on the island (it "breathes") or leaves it.
    case hover(Bool)
    /// The usage readout shows another provider (as a click on it does).
    case usage(UsageProviderChoice)
    /// Widgets the user turned on (the open island grows a tab strip).
    case tabs([WidgetKind])
    /// Another style or screen, as the controller applies it: while the island is hidden (retracted), new metrics; the
    /// next `.island` beat brings it out in the new style. Hide it first, and do it off camera (in story time a cut
    /// skips).
    case style(PromoStyle)
    /// The island drips out of the top edge (AppearDrip, behind the first session's pill).
    case drip
    /// The green "done" celebration around the island (the calm style the app plays).
    case celebrate
    /// The cursor glides to a point in `duration` seconds (a gentle arc, still at both ends).
    case cursor(PromoPoint, duration: Double)
    /// The cursor clicks: a small dip and a thin white ring.
    case click
    /// The cursor fades in or out.
    case cursorVisible(Bool)
    /// The mouse button goes down (a drag begins: the cursor dips a little and stays so) or up.
    case press(Bool)
    /// The shelf scene (`PromoShelfFilm`): the island's shelf lights up for a drop, takes the file, a tile lifts under
    /// the pointer and is dragged out.
    case shelf(PromoShelfStep)
    /// The dragged file's picture under the cursor (`PromoCarryTrack`): it appears, melts into the shelf, or settles
    /// into the Mail message as its attachment.
    case carry(PromoCarry)
    /// Finder selects the photo (it is about to be dragged).
    case select
}

enum PromoShelfStep {
    case target, drop, lift, dragOut, dragOutEnd
}

enum PromoCarry {
    case lift, drop, attach
}

struct PromoBeat {
    /// Story seconds.
    var at: Double
    var action: PromoAction
    init(_ at: Double, _ action: PromoAction) {
        self.at = at
        self.action = action
    }
}

struct PromoText {
    var en: String
    var ru: String
    func callAsFunction(_ lang: PromoLanguage) -> String { lang == .ru ? ru : en }
}

/// A caption (video seconds): its words rise gently into place one after another, then fade out together by `end`.
struct PromoCaption {
    /// `.top`: white over the black bezel of a close shot.
    enum Place { case bottom, top, left }
    enum Ink { case dark, light }
    var start: Double
    var end: Double
    var text: PromoText
    var sub: PromoText?
    var place: Place = .bottom
    /// Dark type over the pale sky (zoomed-in shots), light over the dunes or black.
    var ink: Ink = .dark
    /// Type size in points of the virtual screen's width at zoom 1 (the frame is `screenWidth` points wide).
    var size: CGFloat = 58
}

/// A title card (video seconds): the name, a line under it, an optional small line, the app icon above (end card).
struct PromoTitle {
    var start: Double
    /// nil: stays to the end.
    var end: Double?
    var title: String
    var line: PromoText
    var small: PromoText?
    var icon: Bool = false
}

/// The edit: from video second `at` the story continues from story second `story` (forward only), at 1×.
struct PromoClockKey {
    var at: Double
    var story: Double
    init(_ at: Double, story: Double) {
        self.at = at
        self.story = story
    }
}

/// The camera (video seconds): `zoom` × around `focus` (on the MacBook the frame's center is kept on the screen:
/// `.screen(0.5, 0)` hangs the island from the black bezel; on the monitor the camera frames the room freely).
/// Eased from the previous key, still at both ends (C2: no sudden start or stop); `cut`: jumps here.
/// Built by `PromoCameraTrack` (holds and one move at a time).
struct PromoCameraKey {
    var at: Double
    var zoom: CGFloat
    var focus: PromoPoint
    var cut: Bool
    init(_ at: Double, _ zoom: CGFloat, _ focus: PromoPoint = .screen(0.5, 0), cut: Bool = false) {
        self.at = at
        self.zoom = zoom
        self.focus = focus
        self.cut = cut
    }
}

/// The camera track: shots (cuts) and eased moves, one at a time; between them the camera holds still.
struct PromoCameraTrack {
    private(set) var keys: [PromoCameraKey] = []

    /// A new shot at `at` (a cut, or the first frame).
    mutating func cut(_ at: Double, _ zoom: CGFloat, _ focus: PromoPoint = .screen(0.5, 0)) {
        precondition(keys.last.map { at >= $0.at } ?? true, "camera keys out of order")
        keys.append(PromoCameraKey(at, zoom, focus, cut: true))
    }

    /// Holds until `start`, then eases to `zoom`/`focus` by `end`.
    mutating func move(_ start: Double, _ end: Double, to zoom: CGFloat, _ focus: PromoPoint = .screen(0.5, 0)) {
        guard let last = keys.last else { preconditionFailure("a move needs a shot first") }
        precondition(start >= last.at && end > start, "camera moves overlap")
        keys.append(PromoCameraKey(start, last.zoom, last.focus))
        keys.append(PromoCameraKey(end, zoom, focus))
    }
}

/// Black over the whole frame (video seconds): fades in from `start` to `full`, holds, fades out by `end`.
struct PromoDip {
    var start: Double
    var full: Double
    var hold: Double
    var end: Double
    var opacity: Double = 1
}

/// A cross-dissolve (video seconds): the last frame before `at` (a still moment) fades out over the next shot in
/// `length` seconds. The clock and the camera usually cut at `at` too.
struct PromoDissolve {
    var at: Double
    var length: Double
}

enum PromoLanguage: String {
    case en, ru
}

struct PromoStoryboard {
    /// Video seconds.
    var duration: Double
    /// Settings → Остров → Размер for the film (1 = "normal").
    var islandWidthScale: CGFloat
    /// Virtual screen width in points (the height follows the output's aspect): 1512 pt is a 14" MacBook Pro's default
    /// "looks like" width; the open list takes `IslandLayout.listShare` of it (600 pt, its minimum). The monitor's
    /// screen has the same size in the film.
    var screenWidth: CGFloat
    var beats: [PromoBeat]
    var clock: [PromoClockKey]
    var camera: [PromoCameraKey]
    var captions: [PromoCaption]
    var titles: [PromoTitle]
    var dips: [PromoDip]
    var dissolves: [PromoDissolve] = []

    /// When Codex and Kimi join, when the permission card arrives, when it is approved and when Claude finishes, in
    /// story seconds (the fakes stamp their events).
    static let trioAt = 2.2
    static let cardAt = 12.8
    static let approveAt = 14.8
    static let doneAt = 16.0

    // MARK: Clocks

    /// The story second shown at video second `v`.
    func story(at v: Double) -> Double { Self.story(at: v, clock) }

    static func story(at v: Double, _ keys: [PromoClockKey]) -> Double {
        guard let key = keys.last(where: { $0.at <= v }) else { return v }
        return key.story + (v - key.at)
    }

    /// The first video second that shows story second `s`.
    static func video(at s: Double, _ keys: [PromoClockKey]) -> Double {
        var lo = 0.0, hi = 600.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if story(at: mid, keys) < s { lo = mid } else { hi = mid }
        }
        return hi
    }

    // MARK: The film

    @MainActor static let standard: PromoStoryboard = {
        // The edit: the MacBook plays straight through (story = video); at the dissolve to the monitor the story skips
        // the three seconds in which the island retracts, restyles and comes out again on the other screen.
        let monitorAt = 28.8
        let M = monitorAt
        let clock = [PromoClockKey(monitorAt, story: monitorAt + 3)]
        /// Story second at video second `v` (for beats in the monitor's part).
        func s(_ v: Double) -> Double { story(at: v, clock) }
        // The shelf scene's spots on the monitor's desk: the photo in Finder, the shelf's front slot (its ghost tile,
        // `ShelfWidgetView`'s layout under the tab strip), the message's attachment.
        let photo = PromoPoint.points(PromoDesk.photoIcon.midX, PromoDesk.photoIcon.midY)
        let frontSlot = PromoPoint.points(756 - 300 + 10 + 8 + 45, 6 + 48 + 44 + 8 + 50)
        let letter = PromoPoint.points(PromoDesk.attachmentOnScreen.midX - 12, PromoDesk.attachmentOnScreen.midY - 14)

        let beats: [PromoBeat] = [
            // Hook (MacBook, «Чёлка»): only the notch, then the first session drips out of it; Codex and Kimi join.
            PromoBeat(0, .island(.hidden, .empty)),
            PromoBeat(0, .cursor(.screen(0.66, 0.42), duration: 0)),
            PromoBeat(0, .cursorVisible(false)),
            PromoBeat(0.5, .drip),
            PromoBeat(0.5, .island(.collapsed, .first)),
            PromoBeat(trioAt, .data(.trio)),

            // At a glance, then hover: the list, with the agents' mascots.
            PromoBeat(8.6, .cursorVisible(true)),
            PromoBeat(8.7, .cursor(.island(0.62, 0.6), duration: 0.9)),
            PromoBeat(9.8, .hover(true)),
            PromoBeat(9.8, .island(.expanded, .trio, blur: true)),
            PromoBeat(12.0, .cursor(.screen(0.68, 0.48), duration: 0.8)),
            PromoBeat(12.2, .hover(false)),
            PromoBeat(12.2, .island(.collapsed, .trio)),

            // A permission card arrives and is approved from the island.
            PromoBeat(cardAt, .island(.permission, .card, glow: .card)),
            PromoBeat(13.4, .cursor(.island(0.80, 0.80), duration: 0.9)),
            PromoBeat(approveAt - 0.15, .click),
            PromoBeat(approveAt, .island(.collapsed, .approved, exit: .sent)),
            PromoBeat(approveAt + 0.3, .cursor(.screen(0.70, 0.55), duration: 0.8)),

            // Done: the card with the agent's last message, and the green celebration.
            PromoBeat(doneAt, .island(.flash, .done, glow: .finished)),
            PromoBeat(doneAt + 0.14, .celebrate),
            PromoBeat(18.9, .island(.collapsed, .settled)),

            // Usage (after the cut): open the list, click through the providers on its readout ("Авто" shows Kimi's,
            // the agent at work; then Claude's, then Codex's).
            PromoBeat(19.8, .cursor(.island(0.62, 0.55), duration: 0.9)),
            PromoBeat(20.85, .hover(true)),
            PromoBeat(20.85, .island(.expanded, .settled, blur: true)),
            PromoBeat(21.3, .cursor(.island(0.285, 0.08), duration: 0.8)),
            PromoBeat(22.35, .click),
            PromoBeat(22.4, .usage(.claude)),
            PromoBeat(23.25, .click),
            PromoBeat(23.3, .usage(.codex)),

            // Settings, one beat (the camera steps back, so the gear is in the frame when it is clicked); then closed
            // again.
            PromoBeat(23.9, .cursor(.island(0.852, 0.075), duration: 0.9)),
            PromoBeat(25.2, .click),
            PromoBeat(25.25, .island(.page(IslandSettings.pageID), .settled)),
            PromoBeat(27.6, .cursor(.screen(0.74, 0.62), duration: 0.8)),
            PromoBeat(27.8, .hover(false)),
            PromoBeat(27.8, .island(.collapsed, .settled)),
            PromoBeat(28.3, .cursorVisible(false)),

            // Off camera (the dissolve skips it): the island moves to the external monitor as «Островок», with the
            // widgets turned on.
            PromoBeat(M + 0.2, .island(.hidden, .settled)),
            PromoBeat(M + 0.3, .style(.monitor)),
            PromoBeat(M + 0.3, .tabs([.agents, .music, .calendar, .shelf])),
            PromoBeat(M + 0.4, .island(.collapsed, .settled)),
            PromoBeat(M + 0.4, .cursor(.screen(0.64, 0.40), duration: 0)),

            // The monitor: the capsule floats below the top edge; it opens, then a widget (one click on its tab).
            PromoBeat(s(M + 3.5), .cursorVisible(true)),
            PromoBeat(s(M + 3.6), .cursor(.island(0.6, 0.55), duration: 0.9)),
            PromoBeat(s(M + 4.6), .hover(true)),
            PromoBeat(s(M + 4.6), .island(.expanded, .settled, blur: true)),
            PromoBeat(s(M + 5.2), .cursor(musicTab, duration: 0.7)),
            PromoBeat(s(M + 6.1), .click),
            PromoBeat(s(M + 6.15), .island(.tab(.music), .settled)),

            // The shelf: the pointer leaves the island (it closes) for the photo in Finder, and drags it up to the
            // island: it opens into the shelf, lit for the drop; the photo lands in the front slot.
            PromoBeat(s(M + 7.2), .cursor(photo, duration: 1.0)),
            PromoBeat(s(M + 7.4), .hover(false)),
            PromoBeat(s(M + 7.4), .island(.collapsed, .settled)),
            PromoBeat(s(M + 8.45), .press(true)),
            PromoBeat(s(M + 8.45), .select),
            PromoBeat(s(M + 8.6), .carry(.lift)),
            PromoBeat(s(M + 8.65), .cursor(.island(0.2, 0.5), duration: 1.0)),
            PromoBeat(s(M + 9.5), .hover(true)),
            PromoBeat(s(M + 9.5), .shelf(.target)),
            PromoBeat(s(M + 9.5), .island(.tab(.shelf), .settled, blur: true)),
            PromoBeat(s(M + 9.9), .cursor(frontSlot, duration: 0.7)),
            PromoBeat(s(M + 10.85), .press(false)),
            PromoBeat(s(M + 10.85), .carry(.drop)),
            PromoBeat(s(M + 10.85), .shelf(.drop)),
            PromoBeat(s(M + 11.4), .shelf(.lift)),

            // …and out again: the photo's tile is dragged into the message; the island closes behind it.
            PromoBeat(s(M + 11.95), .press(true)),
            PromoBeat(s(M + 12.1), .shelf(.dragOut)),
            PromoBeat(s(M + 12.1), .carry(.lift)),
            PromoBeat(s(M + 12.15), .cursor(letter, duration: 1.3)),
            PromoBeat(s(M + 13.7), .press(false)),
            PromoBeat(s(M + 13.7), .carry(.attach)),
            PromoBeat(s(M + 13.7), .shelf(.dragOutEnd)),
            PromoBeat(s(M + 13.75), .hover(false)),
            PromoBeat(s(M + 13.75), .island(.collapsed, .settled)),
            PromoBeat(s(M + 14.5), .cursorVisible(false)),
        ]

        // The camera: holds, and one eased move at a time. On the MacBook the island hangs from the black bezel
        // (`.screen(0.5, 0)`); on the monitor the room is framed freely (`monitor(zoom, top:)` puts the screen's top
        // edge `top` of the way down the frame).
        let top = PromoPoint.screen(0.5, 0)
        var camera = PromoCameraTrack()
        // Hook: close on the notch, a slow push while the island drips out.
        camera.cut(0, 2.8, top)
        camera.move(0.6, 3.8, to: 3.0, top)
        // (Under the title's black.) At a glance: the closed island, close; pull back for the list.
        camera.cut(5.0, 2.3, top)
        camera.move(8.4, 9.8, to: 1.6, top)
        // Permission card and «Готово»: a slow push, then still.
        camera.move(12.4, 15.2, to: 1.72, top)
        // Cut (on stillness: the island has closed): the list's header, for the usage readout.
        camera.cut(19.7, 2.4, .screen(0.415, 0))
        // Settings: step back first (the gear and the tall page), to the framing the dissolve matches.
        camera.move(23.7, 25.2, to: 1.15, top)
        // The monitor: the same framing of its screen, then a pull back to the whole display in the room…
        camera.cut(M, 1.15, monitor(1.15, top: 0))
        camera.move(M, M + 2.0, to: 0.62, .screen(0.5, 0.537))
        // …and a push in to the capsule.
        camera.move(M + 2.5, M + 4.3, to: 1.6, monitor(1.6, top: 0.16))
        // The shelf: the island and Finder on its left, then (following the photo out) the island and Mail.
        camera.move(M + 7.3, M + 8.7, to: 1.3, .points(660, 210))
        camera.move(M + 12.2, M + 13.9, to: 1.3, .points(852, 210))

        let captions: [PromoCaption] = [
            PromoCaption(start: 1.0, end: 3.4,
                         text: PromoText(en: "Your coding agents, live in the notch.", ru: "Ваши ИИ-агенты — прямо в чёлке.")),
            PromoCaption(start: 6.7, end: 8.9,
                         text: PromoText(en: "Every session. At a glance.", ru: "Все сессии. С одного взгляда.")),
            PromoCaption(start: 10.1, end: 12.3,
                         text: PromoText(en: "Hover for the details.", ru: "Наведите — и всё видно.")),
            PromoCaption(start: 13.1, end: 15.4,
                         text: PromoText(en: "Approve without leaving your flow.", ru: "Разрешайте, не отрываясь от работы.")),
            PromoCaption(start: 16.3, end: 18.8,
                         text: PromoText(en: "Know when it’s done. And what it said.", ru: "Видно, что готово. И что агент ответил.")),
            PromoCaption(start: 21.5, end: 23.8,
                         text: PromoText(en: "Every agent’s limits. One click.", ru: "Лимиты каждого агента. В один клик."),
                         place: .top, ink: .light),
            PromoCaption(start: 25.6, end: 27.9,
                         text: PromoText(en: "Make it yours.", ru: "Настройте под себя."),
                         sub: PromoText(en: "Sounds, shortcut, language.", ru: "Звуки, горячая клавиша, язык."),
                         place: .left, size: 50),
            PromoCaption(start: M + 0.9, end: M + 3.1,
                         text: PromoText(en: "Or float it on any display.", ru: "Или островком — на любом мониторе.")),
            PromoCaption(start: M + 5.3, end: M + 7.6,
                         text: PromoText(en: "Optional widgets.", ru: "Виджеты — по желанию."),
                         sub: PromoText(en: "Off by default.", ru: "По умолчанию выключены.")),
            PromoCaption(start: M + 9.0, end: M + 11.4,
                         text: PromoText(en: "Drop files on the island.", ru: "Бросьте файлы на островок."),
                         sub: PromoText(en: "The shelf keeps them close.", ru: "Полка подержит их под рукой.")),
            PromoCaption(start: M + 12.4, end: M + 14.7,
                         text: PromoText(en: "…and take them anywhere.", ru: "…и забирайте куда угодно.")),
        ]

        let endAt = M + 15.3
        let titles: [PromoTitle] = [
            PromoTitle(start: 4.2, end: 6.0, title: "Notchbuddy",
                       line: PromoText(en: "For Claude Code, Codex and Kimi.", ru: "Для Claude Code, Codex и Kimi.")),
            PromoTitle(start: endAt, end: nil, title: "Notchbuddy",
                       line: PromoText(en: "Free. Private. No telemetry.", ru: "Бесплатно. Приватно. Без телеметрии."),
                       small: PromoText(en: "github.com/pytodai/NotchBuddy", ru: "github.com/pytodai/NotchBuddy"), icon: true),
        ]

        let dips: [PromoDip] = [
            PromoDip(start: 0, full: 0, hold: 0, end: 0.7),
            PromoDip(start: 3.6, full: 4.1, hold: 6.1, end: 6.6),
            PromoDip(start: M + 14.5, full: M + 15.2, hold: 99, end: 99),
        ]

        return PromoStoryboard(duration: endAt + 3.0, islandWidthScale: 1, screenWidth: 1512, beats: beats, clock: clock,
                               camera: camera.keys, captions: captions, titles: titles, dips: dips,
                               dissolves: [PromoDissolve(at: monitorAt, length: 0.8)])
    }()

    /// The music tab in the open island's tab strip (agents, music, calendar, shelf).
    static let musicTab = PromoPoint.island(0.105, 0.05)

    /// A monitor shot at `zoom` whose frame shows the screen's top edge `top` of the way down (0: at the frame's top),
    /// centered (`PromoCompositor.anchorY` is where the focus sits in the frame).
    static func monitor(_ zoom: CGFloat, top: CGFloat) -> PromoPoint {
        .screen(0.5, (PromoCompositor.anchorY - top) / zoom)
    }
}
