# Island architecture: the Core Animation stage

The island's motion runs on a stage driven by the render server instead of SwiftUI animations. The SwiftUI-driven
island (`IslandRootView`) is still in the tree behind `NOTCHBUDDY_SWIFTUI_ISLAND=1` for comparison. The look: a fixed
transparent canvas, the island flush with the top edge with concave ears, one spring per change that morphs only the
shape, content that never overlaps and never leaves the shape empty for long.

## Why

SwiftUI advances an animation only in a main-thread display tick. On a busy Mac (load average 10 and up, e.g. during a
large build) the main thread misses ticks, so the island dropped frames exactly when it moved: open ~45–56 fps with
80–170 ms gaps, card ~50–59 fps, card advance ~54–60 fps. The window server itself kept compositing at 60 fps.

Core Animation animations are played by the window server. The stage commits every transition **once**, at its start
(a few keyframe animations on layers), and the main thread does no per-frame work at all. Proof: with the main thread
blocked for 300 ms right after the list starts opening, the window server's own pictures of the panel show the
silhouette growing through the whole block, within a fraction of a point of the spring (`verify` in the benchmark);
the SwiftUI island stays frozen for those 300 ms and then jumps to the end.

## Pieces

```
IslandController ── decides the mode, pointer, keyboard, screens
      │
IslandViewState ─── mode, snapshot, target geometry, flying marks, glow, pulses (the model)
      │  renderer (IslandRenderer)
IslandStage ─────── draws it: layers + pages, bakes every motion into Core Animation keyframes
  ├─ IslandTimeline      every animated value is a function of media time → CAKeyframeAnimation (120 Hz keys)
  ├─ SpringTrack         closed-form spring (== SwiftUI Spring(response:dampingRatio:)), retargets with its speed
  ├─ IslandPage          one SwiftUI content page in its own layer-backed NSHostingView
  ├─ IslandChoreography  reveal / exit / section curves as pure functions (shared with the films)
  └─ IslandEffect        one-shot overlays anchored to the island; IslandSilhouetteFollower: ones that track the shape
```

Files: `Sources/NotchBuddy/Island/Stage/`. Tests: `Tests/NotchBuddyIslandTests/`.

### Layers (on the fixed canvas, centered on its top edge)

```
IslandStageView (sublayerTransform: error shake)
├─ surface (layer-hosting)
│   ├─ behind effects
│   ├─ glow      pre-rendered nine-slice image, tinted, stretched to the body (frame keyframes, opacity keyframes)
│   ├─ shadow    pre-rendered nine-slice image (ambient drop shadow), opacity = geometry.shadow
│   └─ silhouette CAShapeLayer, path keyframes (IslandPathBuilder: always the same 9 path elements)
├─ content (layer-backed, mask = CAShapeLayer with the same path keyframes;
│   │        sublayerTransform: closed-island offset in a grown shape, fit to a narrower shape, press squish)
│   ├─ pages…  IslandPageView (opacity + sublayerTransform: reveal/exit; notch wings: half-canvas mask)
│   │            └─ shift (notch wing following its edge) └─ cascade (section mask) └─ NSHostingView (SwiftUI)
│   ├─ inside effects (masked by the silhouette)
│   └─ hero marks (the flying agent mascot: position/bounds keyframes, held inside the growing edge; its sprite
│                   frames: a discrete `contentsRect` keyframe loop, `MascotAnimator`)
└─ above effects (not masked)
```

AppKit resets `transform` on layers that back views, so view layers are only ever animated through `opacity`,
`sublayerTransform` and the path of a mask the stage owns. Layers the stage created (surface, masks, hero, effects) take
anything.

### One transition, step by step

1. `IslandController.update()` → `IslandViewState.setContent(mode, …)` (bookkeeping, spring choice, entrance, glow).
2. `IslandStage.showContent`: builds or reuses the pages of the new mode and lays them out synchronously
   (`layoutSubtreeIfNeeded`): SwiftUI reports the content size and the hero slot during that call.
   Measurements reported meanwhile are recorded, not committed (`IslandRenderer.isLayingOut`).
3. One clock (`now`), then: outgoing pages get their exit, incoming ones their reveal and section cascade, and
   `IslandViewState.commitPending()` → `geometryCommitted`: the silhouette's spring is retargeted from its current
   value **and speed**, the flying marks retarget, and everything that follows the shape is baked from `now` until
   it settles (path ×2, shadow, glow, content transform, notch wings, hero). `CATransaction.flush()`.
4. Nothing more happens on the main thread until the next change. Tidying (removing a page that left, a cascade mask)
   runs later via `stage.later`, and it does not matter when.

Data changes (a session's status, a row added) re-render SwiftUI inside the page; a new content size or hero slot
reaches `contentMeasured` / `heroSlotMeasured` → `retarget` → `geometryRetargeted` (the owner spring). A hero slot
sliding with a SwiftUI animation is followed at most 15×/s (`heroSlotMoved`).

Hovering the closed island builds the list page ahead (`prepare(.expanded)`, 30 ms after the hover grow is
committed), so a hover-open lays out nothing: its motion starts ~3 ms after the decision. The list built ahead counts as
fresh until it is shown (`IslandPageModel.revealed`: its rows still cascade in), so it is kept for
`IslandStage.listAheadLifetime` (4 s) and reused by the next hover or open (one build per hover sequence, ~27 ms of
layout with the dense rows); other pages built ahead are used within 0.35 s or rebuilt.

### Timeline and springs

`IslandTimeline.run(layer, keyPath, from:until:sample:)` samples a function of media time at 120 Hz into a linear
`CAKeyframeAnimation` (begin time = the transition's `now`, `fillMode = .both`) and sets the model value to the end
value. The same functions are kept: `value(_:_:at:)` answers "what is on screen at t" (exits start from the current
pose), and in film mode (`filming = true`) `apply(at:)` draws any moment exactly (`--render-perf`).

Why keyframes and not `CASpringAnimation`: a spring animation's initial velocity is one number for the whole path, so a
change of mind mid-flight (the pointer leaves mid-open) would jump in speed; `SpringTrack.retargeted` keeps every
component's value and speed, and pulses (ear flare, gulp, latch) add on top of the path.

## How features plug in

### A content page (settings, a widget page)

```swift
// Once at launch (e.g. in IslandController.start or the feature's own setup):
IslandPages.register(IslandPageSpec(id: "settings", width: { IslandLayout.listWidth($0) }) { context in
    AnyView(SettingsPage(state: context.state, actions: context.actions, width: context.width))
})

// From a button inside the island (the list header's ⚙️):
Button { actions.showPage("settings") } label: { Image(systemName: "gearshape.fill") }
// Back to the list:
actions.showPage(nil)
```

The real settings page is registered in `IslandSettings.register()`: a narrower column (`IslandLayout.settingsWidth`)
and a page model that outlives the page, so the open section survives closing and reopening.

Widget pages (`MusicWidgetView`, `CalendarWidgetView`, `ShelfWidgetView`) register the same way; their compact
"live activity" views belong in the closed island (`CollapsedIslandView`), see below.

- The page is `IslandMode.page("settings")` / `IslandContentKind.page("settings")`: an open mode, shown instead of the
  list while the island is open (it closes like the list once the pointer leaves unless pinned, see `IslandOpenState`;
  the page is forgotten when the island closes). Cards and notices still take precedence.
- The silhouette sizes itself to the page's measured natural size (keep the page `context.width` wide; any height).
  List → page → list is a morph (the open spring), the page reveals like the list.
- Stagger its parts with `.appearAfter(delay, style:)` (header `0.02 .header`, rows `0.035 + 0.022·i .row`, a footer
  after the last row): on the stage they fade in one after another in Core Animation.
- The page reads `context.state` (observed): reading `state.snapshot`, `state.pinned`, … re-renders it.
- For a new built-in kind instead of a registered page: add an `IslandPageID`, map a mode to it in
  `IslandStage.pageIDs(for:)` and draw it in `IslandPageContent`.

### Header buttons (⚙️, 🔊, pin)

The header is plain SwiftUI inside the list page (`ExpandedIslandView.header`): `SoundButton`, `PinButton`, and any new
button next to them with `.buttonStyle(IslandIconButtonStyle(size: 24, active: …))` and a localized `.help(L("…"))`. Buttons
take clicks once the page is interactive (`IslandMotion.interactiveDelay` = 0.18 s after it came in); they need
nothing from the stage. A button that opens a page calls `actions.showPage(id)`.

### Text on a page (RU / EN)

Every string a page shows goes through `L(…)` (`NotchBuddyCore/L10n/L10n.swift`): `Text(L("Сессии"))`,
`.help(L("Закрепить открытым"))`, `L("ждёт %@", clock)`, `Lp(count, "сессия|сессии|сессий")`; add the key to both
`Resources/{ru,en}.lproj/Localizable.strings` (`L10nTests` fails otherwise). Call `L` inside `body` (or a computed
property read there), never in a `static let`: the call is what subscribes the view to the language, so Settings →
«Язык · Language» redraws the page in place, and the silhouette follows its new size like any data change
(`contentMeasured` → retarget). Strings kept in models (usage notes, timer labels) store the Russian key (`LKey`) and
are translated where shown. Check a page in English with `NOTCHBUDDY_LANG=en NotchBuddy --render-…`; the two
languages differ in length both ways, so let text truncate or wrap rather than fixing widths to one of them.

### Session rows / expandable cards

Rows are `SessionRowView`s inside the list page. Everything a row does in place (hover, a status change, expanding) is
SwiftUI inside the page; when the page's size changes, the silhouette follows with the spring that owns the shape
(`IslandMotion.data` after a transition). For an expanding card animate the row's own change with the same spring
(`withAnimation(IslandMotion.data.animation)`), so the row and the silhouette land together. Rules for any page content:

- do not animate the page's entrance in SwiftUI (no `.transition` on the page root, no blur): the stage reveals the
  page and its `.appearAfter` sections;
- sections present when the page comes in are revealed by the stage; a section that appears later (a row arriving in
  the open list) animates in SwiftUI with the same `AppearAfter` curve;
- the agent mascot that should fly between the closed island, the list and the card is a `HeroSlot(session:size:)`
  (or `HeroSlot(key:size:mascot:)` for a fixed state, e.g. the card's `.waiting`); see "Pixel mascots" below;
- the list is scrollable past five rows; its rows must keep a stable identity (`id: \.element.id`).

### Pixel mascots (the agent's avatar everywhere on the island)

Every agent avatar on the island is its animated pixel mascot (`Sources/NotchBuddy/Mascots`, API notes at the top of
`PixelMascotView.swift`): session cards, the closed island's live activity (the primary session), the permission card
header (`.waiting`) and notices (`.done` / `.waiting`). Brand app icons (`AgentMark` / `AgentAppIcon`) stay where
the brand reads better: Settings' hooks list, the menu bar menu, usage.

- State: `MascotState(session:)` — working splits into `.thinking` (the turn started, no tool has run yet) and
  `.working` (from the first tool call to the end of the turn, so it does not flicker per call); waiting, done,
  error, idle map one to one. `HeroSlot(session:size:)` plays a state's intro (done's jump, error's fall) only when the
  status changed within 3 s (`mascotIntroIsFresh`), so a list opening over old sessions does not replay them.
- Drawing: in a page, `IslandMascot` → `PixelMascotView` (an `NSViewRepresentable` hosting `PixelMascotLayer`); the
  hero mark (`HeroMark`) is the same sprite strip on the stage's hero layer. Both only commit layer animations
  (`MascotAnimator`: the strip as `contents`, a discrete `CAKeyframeAnimation` on `contentsRect`, intro then loop):
  the render server steps the frames, the main thread does nothing per frame. The hero follows its session's state on
  every snapshot (`IslandRenderer.snapshotChanged`).
- Crisp: slots report the square the sprite is drawn in (`HeroSlot.sprite(in:scale:)`: whole device pixels per art
  pixel, `PixelMascotLayer.crispSide`), so a flying mascot lands pixel-exact where the slot's own would be. Sizes: 34 pt
  rows and 32 pt card header → 30 pt sprite; the closed island and notch strips use 28 pt (30 pt sprite on Retina,
  20 pt at 1x).
- Paused when unseen: a page mascot removes its animations when its view is hidden (a retired persistent page), out of
  a window (a discarded page) or the window is occluded (panel ordered out, display asleep); the hero pauses with the
  panel's occlusion (`IslandStageView`). A slot whose session is the hero draws nothing (no hidden animation).
- Previews (`islandStaticRender`) draw the still frame (`PixelMascotImage`); films step the frames by their own clock
  (`islandFilmTime` → `PixelMascotImage(time:)`, the flying hero in `IslandStage.apply(at:)` while filming), so the
  promo (`--render-promo`) shows the mascots moving.
- Reduce Motion: no hero; a page mascot shows its still frame (busy states pulse opacity slowly).
- The mascot view never takes clicks (`hitTest` → nil): a card's button and the island get them.
- Characters: `MascotCharacter(agent:)` — Claude, Codex and Kimi have their own; every other `AgentCatalog` agent
  (Cursor, Copilot, Cline, Grok, future ones) is the generic blob, VoiceOver still names the agent (`displayName`).
- Cost, measured with the mascots on (release, `scripts/perf-bench.sh`, load 5–8): «Чёлка» 10 runs and «Островок» 5
  runs, open / close / flash / card / card advance at 60.0 fps on screen, worst frame 16.7 ms; latencies open 3 ms,
  flash 7–9 ms, card 21 ms.

### Effects anchored to the island (the green "done" celebration)

```swift
state.playEffect(IslandCelebration(tint: SessionStatus.finished.tint))   // sparks out of the lower edge
state.playEffect(IslandRipple(tint: SessionStatus.finished.tint))        // a ring leaving the outline
```

A one-shot effect is `IslandEffect` (`IslandStageEffects.swift`): pick `placement` (`.behind` the silhouette, `.inside` it and masked, or `.above` it
unmasked), build layers in the given container, animate them (bake with `context.timeline.run(...)` to have them
filmed too, or plain Core Animation), return the duration; the stage removes the container afterwards.
`IslandEffectContext` gives the target silhouette (`geometry`, `body` rect, `outline` path without its top edge),
`now`, `reduceMotion` (return 0 to skip). The "finished" celebration is played by `IslandEffectsDirector`
(`Effects/IslandStageFX.swift`) once the notice is on the island.
The canvas bounds effects: `IslandLayout.shadowMargin` (56 pt) around the largest island.

An effect that stays and must track the shape while it moves (an attention rim, a permission aura, a sheen across the
body) is an `IslandSilhouetteFollower`: `stage.addFollower(f)` gives it a layer in its placement, and on every
re-bake (a transition, a hover, a data change) calls `follow(motion, timeline:, from:, until:)` with the silhouette's
motion (`IslandSilhouetteMotion`: `geometry(at:)`, `outline(at:closed:)`, `body(at:)`); the follower bakes its own
tracks (`timeline.run(layer, "path", …) { t in motion.outline(at: t) }`) and so moves with the shape in the render
server, costing the main thread nothing per frame. `removeFollower(f)` takes it away. Example: `IslandOutlineGlow`.
Avoid layer shadows and filters on moving layers (the render server blurs them every frame): pre-render soft light
into images (as the glow and the shadow do) or stack strokes.

Effects written for the SwiftUI island go through `IslandEffectsHostView`, which follows the animated geometry frame
by frame (`update(geometry:)` → `follow(FXOutline)`): on the stage that would be main-thread work per frame. To use one
on the stage, wrap its looping layers as a follower whose `follow` bakes what `follow(FXOutline)` sets, and fire its
one-shots (`DoneCelebrationLayer.play(at:…)`, error, confetti, drip) from an `IslandEffect.play` with the context's
target outline; `FX.now(layer)` times are media times, the same clock as `context.now`.

### The closed island (live activity, compact widgets)

`ClosedIslandContent` is drawn by the closed page: the widget live activity the arbitration chose, or
`CollapsedIslandView` (see «Widgets» below). Beside a notch it is drawn twice (`closedLeft`, `closedRight`),
each cut at the canvas' center, so each wing can follow its edge of the silhouette while the shape is narrower than
the content: both copies must render identically (they do: same inputs). A one-shot animation keyed with `OneShots`
plays in the first copy to claim it (the left one, laid out first).

## What is wired

- **Type and icons.** Manrope everywhere on the island through one loader, `NBTypography` (registered in `main.swift`;
  `SessionFont` and `SettingsFont` delegate to it); tabular digits for clocks and counts, SF Mono for code. Glyphs come
  from the icon set (`NBIconView`); views that name glyphs by SF Symbol go through `IslandSymbol`, which draws the
  set's icon when it has one (`NBIcon.replacing(symbol:)`) and takes its color from the control it sits in
  (`islandInk`, set by `IslandButtonStyle` and the cards' pill buttons, which also play the icons' hover gestures).
  Looping icons are Core Animation sprites; a hidden page pauses them (`IslandPageModel.paused` → `nbLoopsPaused`).
- **List.** `ExpandedIslandView` = `IslandListHeader` + `SessionCardList` + usage. The header never wraps:
  beside a notch each side is fitted to its wing (`NotchWingsLayout` + `ViewThatFits`), the status chips give way
  first (full → compact → mini → the most urgent one). Buttons: ⚙️ (`IslandGlyphButton(.settings)` →
  `actions.showPage(IslandSettings.pageID)`), 🔊 (`SettingsStore.values.soundsEnabled`), 📌. The expanded card lives in
  `IslandViewState.expandedSession` (kept list → settings → list, forgotten when the island closes).
- **Settings.** `IslandSettings.register()` puts `SettingsPage` on the stage as a page; the × goes back to the list,
  the menu bar's «Настройки…» (⌘,) opens it (`IslandController.showSettings`). `IslandController.applySettings` reads
  `SettingsStore` live: hover delay (`restDwell`/`maxDwell`, «По клику» never opens on hover), «Показывать запросы
  сразу» (off: a request waits in the pulsing closed island until opened), «Показывать без сессий» (a quiet pill on a
  screen without a notch), «Закреплять при открытии», notice length (`AppModel.flashSeconds`), usage refresh and API
  switch (`AppModel.setUsageRefreshInterval`, `usageSourceChanged`), size (`IslandLayout.widthScale`: the widths
  morph, the canvas is always sized for the largest), screen (`ScreenLocator.preferredScreen`), motion (Reduce
  Motion override), the usage ring widget, the global hotkey (`GlobalHotkey` → `toggleFromHotkey`) and hotkey
  recording (`IslandKeyFocus.setRecording`: the panel takes keys only while the pointer is on the island). Sounds go
  through `SettingsSounds` per event (finished, attention, permission, error).
- **Permission strip beside a notch.** «Нужно разрешение» → «Нужен ответ» → the icon alone, whichever fits the left
  wing: it never slides under the camera housing.
- **Effects** (`Effects/IslandStageFX.swift`, `IslandEffectsDirector`; thin lines, no soft auras):
  a "finished" notice plays `DoneCelebrationLayer` in the `.calm` style (behind / inside / above, anchored to the
  notice's check, coalesced with `CelebrationCoalescer`: then `.calmEncore`, then absorbed); the closed island of a
  waiting session carries `IslandAttentionFollower` (breathing rim + a ring every 2.4 s, the ring rests while the
  shape moves); a permission card carries `IslandPermissionRim`; the closed island's failure adds a red rim flash to
  the shake; the hover grow sweeps a faint sheen (at most every 1.4 s). One-shots are `IslandEffect`s laid out on the
  target silhouette; followers bake their paths from the stage's motion. Not wired: `AppearDrip` (it would change the
  appear motion) and confetti. Filmstrips: `--render-effects` (`island-*` scenes); the stage films cannot
  draw Core Animation one-shots, so `film-flash` shows the notice alone.
- **Copy.** Status labels and tool names come from the catalog (`SessionStrings`: `SessionStatus.label`,
  `ToolStyle.displayName`).

## Widgets ("островки": music, calendar, shelf, timer, system, usage, hotkey)

The open island has tabs: «Агенты» (the list) and every widget switched on in Settings → Островки
(`NotchSettings.widgets`: kind, on/off and order; «Агенты» is always on; out of the box it is the only one, so there is
no strip). The closed island shows one live activity, chosen by rank. Files: `Widgets/IslandWidgets.swift` (hub,
pages, closed content), `Island/IslandTabs.swift` (strip, swipes, usage footer), `NotchBuddyCore/IslandActivity.swift`
(ranking, usage selection).

- **Hub.** `WidgetHub.shared` owns the widgets' services and starts each only while its widget is on
  (`apply(_:)`, called from `IslandController.applySettings`): `NowPlayingService` (player notifications),
  `CalendarService` (EventKit; asks only on a click), `TimerStore`, `SystemMonitor` (samples only while its page is on
  screen), `ShelfWidget` (the drag detector's monitors), plus `AgentUsageHub` (Claude from `AppModel.usage`, Codex from
  its rollouts, Kimi when «Лимиты Kimi через API» is on). Everything the island reads is observed
  (`withObservationTracking`) and coalesced into `onChange` → `IslandController.scheduleUpdate`. A running timer
  re-ranks at the moment it enters its last 10 s (one timer, no polling). Previews and films put
  `WidgetHub.preview(...)` in `shared`.
- **Pages.** Each widget is a registered page `widget.<kind>` (`IslandWidgetPages.register()`); `IslandMode.tab(kind)`
  is `.expanded` for «Агенты» and `.page("widget.<kind>")` for a widget, `IslandMode.tab` reads it back. A page leaves
  the strip's room free (`IslandTabs.headerBlock`) and draws its widget below it (timer and system without their own
  title rows; the calendar keeps its date header; music is padded to the list's width).
- **Strip.** `IslandPageID.tabs` is a page of its own over the tab's content (`isTabContent` pages go under it), kept
  like the card chrome: while tabs swap it stays live and never re-reveals; it measures nothing (the silhouette follows
  the tab's content). Its SwiftUI pill glides on the transition's spring (`IslandViewState.activeTab` is set inside
  `setContent`'s animation), the active tab shows its name when there is room (`IslandTabs.style`: named → icons →
  compact, so six tabs fit a notch wing at every size), inactive tabs carry a dot when their widget has something going
  on (`WidgetHub.badge`). ⚙️ 🔊 📌 and, on «Агенты», the status chips sit on the right. It takes clicks as soon as it
  has settled in, not after each tab's own `interactiveDelay`. Beside a notch it lives in the notch strip: tabs in the
  left wing, buttons in the right.
- **Switching.** A click on a tab, or a horizontal trackpad swipe while the pointer is on the open island
  (`TabSwipeTracker`: the axis is decided after 8 pt, 38 pt of sideways travel switches once per gesture, fingers to
  the left = next tab, momentum swallowed, vertical scrolls reach the content; on the shelf only a swipe on the header
  switches, its row of files scrolls sideways). `IslandController.update` sees two tab modes and calls `setContent` with
  `IslandEntrance.slide(forward:)` / `IslandExit.slide(forward:)`: the old tab slides 18 pt away and is gone by ~60 ms,
  the new one comes 26 pt from its side from ~40 ms (`RevealParams.dx`, `ExitParams.dx`, baked like every pose), the
  silhouette morphs to the new tab's size on the open-to-open spring. A tab the pointer rests on in the strip, or the one
  a sideways swipe heads for, is built ahead (`IslandStage.prepareTab`, kept 2 s), so the switch commits without laying
  anything out. At the strip's end a swipe flares the ears instead.
- **Opening.** A click on the closed island (or a hover open, or the hotkey) opens on the tab of the live activity it
  shows, else on the last tab (`tabForOpening`); the page a hover would open is the one built ahead while the pointer
  rests (`IslandViewState.openTarget`). ⚙️ on a widget's tab opens settings with «Островки» expanded; × goes back to
  that tab.
- **Closed island.** `ClosedIslandContent` draws `IslandSnapshot.activity` (`WidgetHub.activity` →
  `IslandActivityArbiter`): permission cards and notices are overlays above all of this; then a file dragged toward the
  island > an agent waiting > a timer finishing or just finished > a meeting within the reminder window > agents working
  (or failed) > music playing > a timer running > low battery > the shelf's files > any other session. A widget's
  activity keeps the closed island out even with no session; the flying agent mark and the attention rim belong to the
  agents' pill only. Faces swap without overlap (out in 80 ms, in from 60 ms). The calendar pill takes no clicks (the
  click opens the tab where «Подключиться» is). A timer running out plays the calm celebration on the island.
- **Shelf drops.** The panel never takes a drag that started elsewhere, except a file drag the shelf wants
  (`capture = onIsland && (!(buttonsDown && ignoresMouseEvents) || shelf.wantsDrop)`); over the island the island opens
  on «Полка» (`dragOpen`) and the drop lands on the shelf's page; dropped, the island behaves like a hover-opened one;
  a tile dragged out keeps it open. While the island is hidden the detector aims at the closed island's place.
- **Usage.** In the list's header strip (`IslandUsageStrip`): one agent,
  `UsageSelection.shown` (the chosen one; «Авто»: the main session's agent with numbers, else Claude, else anyone), its
  mark and name and every window compactly («5ч 42% · 2ч10м │ 7д 18% · 3д4ч», giving way to fewer details); on a tabbed
  island it is the first row of «Агенты». A click on the strip or on the closed island's ring (`UsageRingSlot` reports
  its rect, `IslandStageView.onUsageRing` takes the click) steps to `UsageSelection.next` (Авто → Claude → Codex → Kimi,
  skipping agents without numbers; `NotchSettings.usageProvider`, also in Settings → Лимиты). The ring shows the chosen
  agent's first window, with «Авто» the shown session's agent's.
- **Hotkey.** ⌃⌥N, on by default (settings schema v3 moves a stored ⌃⌥Space, macOS' "Select next source in Input menu", to it),
  Carbon `RegisterEventHotKey` (no permission, no activation). Before registering and in the recorder the combo is
  checked against the Mac's enabled shortcuts (`CopySymbolicHotKeys` → `HotkeyClashes.system`, `GlobalHotkey.Status.system`
  names it); the presets avoid them and well-known app shortcuts (`HotkeyClashes.app` warns about those): opens the island on the tab it would open on (not
  pinned: it waits for the pointer to come and go, a click elsewhere or the hotkey again), or closes it. Configurable in Settings → Горячая клавиша; the menu bar menu shows it.
- **Menu bar.** «Островки» lists the widgets with checkmarks (the same store as Settings), «Порядок и настройки…».
- **Previews.** `NotchBuddy --render-widgets <dir>` films the real stage with sample data: `widgets-tabs-*` (every
  tab), `widgets-closed-*` (every live activity), `film-switch-*` (both directions, a quick double swipe),
  `film-open-activity-*`, `film-settings-from-tab-*`, with the continuity check; `NOTCHBUDDY_WIDGET_FILMS=tabs,closed`
  picks parts. The widgets' own renders (`--render-music`, `--render-calendar`, `--render-shelf`,
  `--render-timer-system`, `--render-usage`) still draw every state of each widget.
- **Benchmark.** `scripts/perf-bench.sh --tabs` gives the dev instance a strip (Агенты, Таймер, Система) and switches
  tabs each run: once cold (as a swipe does) and twice as a click after the pointer rested on the tab.

Results (release, 10 runs, `--tabs`, load average 10–11): every transition at 59.7–60.0 fps on screen with a worst
frame of 16.7 ms, except one compositor drop in 30 tab switches and one in 10 cards (33.3 ms each, `srv/tr` 0.10). A
tab switch starts 24 ms after the click on average over the mix, with one bake each; without building ahead it takes
36 ms (worst main-thread stall 171 ms), with it 16 ms (worst 65–80 ms). Open 7 ms, flash 16 ms, card 35 ms.

## Open, pin, leave (`IslandOpenState`)

Why the island is open apart from cards and notices, and when it closes, is one pure value
(`Island/IslandOpenState.swift`, tests: `IslandOpenStateTests`): the opener (hover, click, remote = hotkey / menu bar,
drop), the pin, whether the pointer has visited, and since when it has been off the island. An island opened from afar
that the pointer never reaches closes after `remoteVisitWindow` (4 s), and when another app comes to the front
(`NSWorkspace.didActivateApplicationNotification`). The controller feeds it
every pointer check (events, the tracker's watchdog, and its own `leaveWatch`: a 10 Hz timer with 30 ms tolerance that
runs only while the island is open, unpinned, on screen and not showing a card or a file drag) and asks
`shouldClose(now:held:)`. `held` = a mouse button down, a Notchbuddy menu tracking (a set of the menus that began
tracking, emptied when the run loop is not in its tracking mode, so a lost "end" cannot hold it), a card, a file drag, a
screen move, a shelf tile dragged out (`ShelfStore.draggingOut`, let go 0.5 s after every button is up even if the drag-end
callback never comes); the leave counts from when it lets go. A due close that is held logs what holds it, once per set
(`island: close postponed, held by …`). A click
never pins; 📌 (list header, tab strip, settings page) and «Закреплять открытый список» do. Wake, screens-wake and
Space changes re-check at once; a global mouse-down closes a remote open the pointer never visited.

## Styles: «Чёлка» and «Островок»

Settings → Остров → Стиль, per kind of screen (`NotchSettings.islandStyleMonitors` / `islandStyleNotched`) rather than
per display, since a monitor's UUID can change when it is plugged in another way. `ScreenLocator.style` resolves it into the placement: `IslandMetrics.gap` is 0 for Чёлка and
`IslandLayout.islandGap` (6 pt) below the top edge for Островок (below the camera housing on a notched screen, laid out
as `.floating`). `IslandLayout.geometry` takes the Чёлка shape and detaches it: `top = gap`, no ears (same total width:
the body takes their room), `crown` (convex top corners) = `bottom`; hidden, it shrinks into its own middle.

- `IslandGeometry.top` / `.crown` are two more components of the spring vector, so a switch is one morph on the
  `morph` spring (`IslandViewState.morph(to:)` → `IslandStage.gapChanged` + retarget): the ears shrink while the crown
  grows, passing through a square corner, and the shape slides down by the gap.
- `IslandPathBuilder` draws both (and everything between) with the same 9 elements: each top corner is one cubic that
  is either the concave ear or the convex crown; the open outline for strokes ends with the top edge when detached.
- Pages are laid out at `metrics.gap` (`IslandPage.layout(in:top:)`) so AppKit / SwiftUI hit-test where they are drawn;
  the content group's transform adds `top(t) − gap` while the shape moves. Heroes add the gap to their slots; the shadow
  and glow nine-slices round the capsule's top (`IslandSurfaceImage.frame(…top:detachment:)`).
- `IslandHitShape` knows the crown and counts the strip between the capsule and the screen's top edge as the island;
  detached, its corners are circles like the path's (a closed capsule's ends are half circles at any width).
- Closed, the capsule is `IslandCapsuleFace` (`CollapsedIslandView`): mascot at the leading end, live status at the
  trailing end, the usage ring when `IslandCapsule.fit` finds room, no text. It is exactly Settings → Остров → «Ширина
  капсулы» wide (`IslandLayout.capsuleWidth`, 140–360 pt, default 190) and `IslandLayout.geometry` takes a detached
  closed island's width from its content without adding the ears, so the silhouette is that width. The width is an
  input of `ClosedIslandContent` / `CollapsedIslandView` (`IslandViewState.capsuleWidth`, set by
  `IslandController.applySettings` inside the data spring's animation): a change re-renders only the closed pages, the
  new size retargets the shape on the data spring and the face's ends slide on the same spring. Widget faces in
  «Островок» get the ears' margin as padding instead. Films: `NOTCHBUDDY_FILM_SETS=island NOTCHBUDDY_FILMS=capsule-width,
  capsule-140,capsule-190,capsule-360,capsule-face-waiting,… NotchBuddy --render-perf <dir>`.
- On a screen without a notch both styles share one canvas (`canvasSize` always reserves the gap), so the panel never
  resizes; on a notched screen the metrics' layout changes and the island retracts and emerges as for a screen move.
- Benchmark: `scripts/perf-bench.sh --style island` (the dev instance only, `--perf-send style island`).

### Sideways: a dragged «Островок»

A «Островок» can be dragged along the top edge of its screen (horizontally only).

- **Panel.** As tall as the canvas and as wide as its screen (and at least the canvas), so the island can sit anywhere
  along the top without the panel moving or resizing (`IslandController.panelFrame`); still transparent and click-through
  except over the island. Its content is `IslandSlideView`, which places the fixed canvas (`IslandStage.view`) centered
  on the anchor plus `frameShift`.
- **Slide.** `IslandStage.slide` is one more spring track: the island's center offset from the anchor
  (`IslandViewState.targetShift`: the drag position while dragging, else the stored offset clamped so the target
  silhouette stays `IslandLayout.edgeMargin` inside the screen, `IslandLayout.shiftRange`; 0 for «Чёлка»). It moves the
  whole canvas rigidly: on every commit the canvas' AppKit frame jumps to the target (hit tests land there) and the
  slider's `sublayerTransform` carries `slide(t) − target`, baked like any track (render server, one transaction, exactly
  0 once settled so nothing rests on a fraction of a point). Retargets keep their speed like the shape's.
- **Drag.** `IslandStageView.mouseDragged` → `IslandController.dragClosedIsland` → `IslandDrag` (pure math in
  `IslandDragMath`, tested): 4 pt sideways turns a press into a drag; the capsule leaves its place at zero speed and
  catches up with the pointer within ~30 pt (no jump), follows it 1:1, rubber-bands past the margin (≤ 8 pt), and each
  mouse event is one `dragSlide` (a transform, nothing baked or laid out). Let go, it settles on `IslandMotion.drop`
  (0.40/0.78) inside the screen, onto the center within 24 pt (a haptic tick when it crosses the center). The capsule
  lifts while dragged (the press squish gives way to the hover grow); `IslandOpenState.beginDrag` keeps hover and clicks
  from opening or pinning it; after the drop it opens only once the pointer has left and come back. A drag starts from
  where the island is drawn: pressed again while it still settles after a drop, the capsule is caught there
  (`IslandStage.holdSlide`) and stays under the pointer.
- **Grab out of the open island.** The hover opens the island ~0.1 s after the pointer rests, so re-dragging a capsule
  usually starts on the open island. A press on an open island (hover- or click-opened, not pinned; list / widget tab /
  settings) where its capsule sits (`capsuleFootprint`) grabs the capsule after a clear pull, `IslandDragMath.grabThreshold`
  = 12 pt and more sideways than up or down (above the closed capsule's 8 pt click slop: a sloppy click on a tab or
  ⚙ 🔊 📌 there stays a click; the footprint covers the tab strip at the left edge and the buttons at the right).
  `beginGrab`: the content's press is released (a mouse-up far outside), the island closes (the fold heads for the
  capsule on the close spring) and the drag starts from where the capsule rests with the 12 pt threshold's lag. The fold
  is not cut short: `dragSlide` moves the slide's track rigidly while it is still moving (its remainder and speed stay,
  baked until it settles; the content swap's pins only cancel that remainder, so the leaving list still fades where it
  was and the capsule's content sits at the drag's place), so the island is drawn where it was at the grab and converges
  on the pointer as the fold plays out; its lift rides the fold's spring (`IslandViewState.setHovering(riding:)`).
  While a drag runs nothing else retargets the slide (`retargetSlide` waits for `dragShift` to clear).
- **Double click.** On the capsule's footprint, in either state (`IslandController.recenterOnDoubleClick`, from the
  panel's mouse filter, `clickCount ≥ 2`): a capsule moved aside goes back to the center and its place is kept; an
  island open over it (the hover opened it before the double click was done, or the first click did) closes as the
  capsule slides home (the close carries it there; `settleSlide` keeps a slide already heading home) and opens again only
  once the pointer has left and come back. The second press and its mouse-up are swallowed. A capsule already at the
  center ignores it (its double click stays two clicks: no open/close blip). Settings → Остров → «Сбросить положение»
  re-centers it on every screen.
- **Open from an offset.** The open island is clamped with its own width, so near an edge it opens inward. Its content
  must not travel with the slide: in a content swap that moves the slide (`IslandStage.pinPages`) incoming pages hold the
  place the island is heading for and leaving ones the place they were at (a pin on the page's `shift` cancels the slide
  until it settles); the flying mascot is pinned the same way (`pinHeroes`, its spring takes the difference). So the
  silhouette, sliding and growing with its outer edge held still, uncovers the list where it lands, exactly as at the
  center. A slide outside a content swap (a drag, a reset, a style switch) carries everything rigidly.
- **Kept per display** in `NotchSettings.islandOffsets`, keyed by `IslandDisplayKey` ("builtin", else vendor-model-serial:
  a monitor keeps its place on another port or dock), whole points, centered not stored. Used by placement, hit testing
  and click-through (`islandHitShape`: the strip above the capsule counts only at the center, where it covers no menu bar
  item), the shelf's drag detector, the open island and «Ширина капсулы» (a wider capsule is clamped again).
- **Films / tests / bench.** `NOTCHBUDDY_FILM_SETS=island NOTCHBUDDY_FILMS=capsule-left,capsule-center,capsule-right,
  drag-edge,drag-snap,drag-catch,open-from-left,open-from-right,close-to-left,grab-left NotchBuddy --render-perf <dir>`
  (screen-wide panel; the continuity check also watches the silhouette's edges sideways); `IslandDragTests`,
  `IslandSlideTests`, `IslandControllerTests` (the controller on a placement of its own, `start(on:)`: hover-open at
  «Быстро», double click, grab threshold, no jump at the grab); `scripts/perf-bench.sh --drag` ("drag", "open-offset",
  "close-offset", "grab": the hover-opened island grabbed at the left edge and pulled 360 pt).

### Where the island shows (per app)

Settings → Остров → «Где показывать»: «Во всех приложениях» (default) / «Только в выбранных» / «Везде, кроме
выбранных», each mode with its own list of apps (bundle id + name; `NotchSettings.appsShownIn` / `appsHiddenIn`), and
«Всегда показывать запросы агентов» (default on). The decision is pure (`IslandAppVisibility.isVisible`, tested): an empty
list restricts nothing, an unknown app shows it, a pending permission request or a "needs you" notice shows it with the
switch on. `FrontmostAppWatcher` follows activation, the menu bar's owner and Space changes (NotchBuddy itself and agent
apps never count: the last regular app stays), debounced 150 ms, so ⌘Tab through apps hides or shows the island once.
`IslandController.resolveMode` returns `.hidden` when the app does not allow it and the island is not open: it retracts
on the `hide` spring and the panel is ordered out (no window catches clicks); it comes back with the appear motion. An
island opened by hover, click, hotkey or «Настройки…» stays open in any app, so the settings can always be
reached. Sounds are unchanged (Settings → Звуки). «Добавить приложение…» offers the running regular apps as icons and
«Другое…» (an `NSOpenPanel` on /Applications; NotchBuddy comes forward for it, hands the front back and reopens the
settings with the apps added). Renders: `--render-settings` → `state-show-in-*`, `state-position`.

## Motion rules

- Only the silhouette's shape moves, hanging from the top edge of a fixed canvas (or floating `gap` below it, «Островок»);
  the panel never resizes.
- One spring per change (`IslandMotion.geometry(from:to:)`), retargeted with its speed on a change of mind.
- Outgoing content is gone by ~50–70 ms (`IslandExit`), incoming content starts at ~35–45 ms (`RevealParams`) and is
  readable by ~110 ms: the two never show at once and the shape is never empty for long (tested:
  `testNoOverlapNoLongBlank`).
- Content is cut by the silhouette (a Core Animation mask: AppKit views such as the code block are cut too).
- Blur only at the edges of the open island's life: an open page
  comes out of a 7 pt Gaussian blur within 120 ms of its reveal, and a closing list blurs out to 8 pt as it is drawn up
  (`IslandExit.collapse`, 150 ms; the pill reveals from 90 ms, `testCloseKeepsContentOnScreen`). It is a Core Image filter
  on the page view's layer (`layerUsesCoreImageFilters`), its radius keyframed like any other track and the filter removed
  afterwards (`IslandStage.bakeBlur`); films skip it (`render(in:)` draws no filters). Otherwise opacity and transform only.
- Open → open (list ↔ settings) reveals at 26 ms with the page's section delays halved: no blank frame
  (`testMorphHasNoBlankFrame`).
- Reduce Motion: `IslandMotion.reduced` spring, opacity-only reveals and exits, no pulses, no shake, no flying mark.

## Measuring

```bash
swift build -c release
scripts/perf-bench.sh --bin .build/release/NotchBuddy --runs 10            # this pipeline
NOTCHBUDDY_SWIFTUI_ISLAND=1 scripts/perf-bench.sh --bin .build/release/NotchBuddy --runs 10   # the SwiftUI island
scripts/perf-bench.sh --load …                                              # with `yes` × cores meanwhile
```

The bench starts a separate dev instance (`NOTCHBUDDY_PERF=1`, `NOTCHBUDDY_HOME=/tmp/notchbuddy-perf`,
`NOTCHBUDDY_SOCKET=/tmp/notchbuddy-perf.sock` unless set; its single-instance lock lives in that home; no menu bar item, keychain,
network or sounds; it never takes the pointer) next to the installed app, drives it with fake sessions over a
distributed notification (`NotchBuddy --perf-send <action>`), and summarizes `perf.log`:

| column | meaning |
|---|---|
| main | main-thread display ticks: the frame rate of SwiftUI motion (for the stage only a measure of how busy the main thread is) |
| comp / srv | frames the window server displayed (an in-panel Metal probe) / frames it skipped with a drawable waiting |
| work | per-frame island work on the main thread in the transition (the stage: 1 = its single commit) |
| latency | from the change to the committed motion |
| verify | window-server pictures of the panel during an opening with the main thread blocked for 300 ms |

`NotchBuddy --render-perf <dir>` films the real stage (film mode, virtual clock) for every transition, notch and no
notch (`NOTCHBUDDY_FILMS=open,close`, `NOTCHBUDDY_FILM_REDUCE=1`), and checks the silhouette never jumps between two
1/120 s samples. `NOTCHBUDDY_STAGE_DEBUG=1` logs every commit and the time spent laying out, baking and flushing.
`--render-previews` still draws the SwiftUI filmstrips (for comparison) and its live check runs the stage.

### Results (60 Hz display, 10 runs each; background load average 15–26, 34–52 with `yes` × 10)

| transition | SwiftUI island, background / with yes: fps (worst gap) | stage, background / with yes: on-screen fps, main-thread frames, latency |
|---|---|---|
| open (hover) | 45–56 (81–147 ms) / 49–56 (104–173 ms) | 60 / 60, 0, 3–10 ms (list built ahead) |
| close | 58–61 (33–45 ms) / 59–61 (38–50 ms) | 60 / 60, 0, 3 ms |
| card | 50–59 (56–201 ms) / 53–59 (88–109 ms) | 60 / 60, 0, 22–35 ms (card layout) |
| card advance | 54–60 (29–79 ms) / 55–60 (40–102 ms) | 60 / 60, 0, 21–28 ms |
| flash | 61 (20–28 ms) / 61 (22–45 ms) | 60 / 60, 0, 9–13 ms |
| main thread blocked 300 ms mid-open | frozen, then jumps to the end | keeps moving: 10–16 distinct heights while blocked, median error vs spring 0.0–0.4 pt |

The stage's `main` column still shows gaps (building a card, building the list ahead while hovering): that is the
main thread being busy, not the island dropping frames. The compositor dropped a frame in ~1 of 10 transitions under
load 50 in both pipelines.

With effects, settings and session cards on, the stage keeps these numbers: under load every
transition runs at 60.0 fps on screen with a worst frame of 16.7 ms; without `yes`, the rare stall is in the compositor itself.
Main thread per transition: 1 bake (a card: 2, the permission rim's follower bakes once); latencies open 2–6 ms (list
built ahead), flash 7–13 ms, card 16–32 ms. In the debug live check (`--render-previews`) a hover-open commits in
6–8 ms, a cold open (hotkey, menu) in 45–60 ms and a card in 32–44 ms.

Kept cheap on purpose: the island's icons are static on pages (a looping icon commits its sprite frames with every page
built), effects are Core Animation layers with thin strokes (no layer shadows or filters on moving layers), loops are
capped at 30 fps and pause with the page.

## Limitations

- Content build is on the main thread: a new card or notice starts moving 10–35 ms after it arrives (after its
  layout), up to ~90 ms on a saturated machine; the list is built ahead on hover.
- SwiftUI animations inside a page (a row's hover, a status glyph, the arming fill, a check drawn on) still run on the
  main thread; they are small and not part of the island's transitions.
- Sections cascade with opacity (a mask per section) rather than each dropping in with its own offset; only whole pages
  blur (opening, closing).
- A hero slot sliding with a SwiftUI animation is followed 15×/s.
- Beside a notch the closed content exists twice (two cut copies).
