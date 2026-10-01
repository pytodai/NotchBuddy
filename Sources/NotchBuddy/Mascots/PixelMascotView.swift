// Pixel mascots — animated pixel-art characters, one per agent.
//
// API
// ---
//   PixelMascotView(agent: AgentSource, state: MascotState, size: CGFloat = 30)
//   PixelMascotView(agentID: String, state: MascotState, size: CGFloat = 30)   // "claude", "codex", "kimi", else generic
//   PixelMascotView(character: MascotCharacter, state: MascotState, size: CGFloat = 30)
//       A square `size`×`size` pt view. Live Core Animation: pass a new `state` and the mascot switches at once
//       (done and error first play their one-shot intro, then loop). Reads Reduce Motion from the environment.
//
//   PixelMascotImage(character:state:size:)        Static SwiftUI image of the state's still frame, for
//                                                  `ImageRenderer` snapshots (NSViewRepresentable doesn't render there).
//
//   MascotState(status: SessionStatus)             working → .working, waitingForUser → .waiting, finished → .done,
//                                                  error → .error, idle → .idle. `.thinking` ("…" dots) is for
//                                                  thinking / compacting context; nothing maps to it automatically.
//   MascotCharacter(agent:) / (agentID:)           claude, codex, kimi, generic.
//
//   NotchBuddy --render-mascots <dir>              Sprite sheets, animated GIFs and a real-size island preview.
//
// Characters (pixel homages to each agent's own icon, in its brand colours): Claude — a coral spark with a cream
// starburst of irregular rays; Codex — the icon's round six-lobed cloud in its blue→violet gradient, whose face is
// the `>_` prompt; Kimi — a black squircle with the white `K` on its head and the blue dot; generic — a neutral grey
// blob.
//
// Sizing: the art is a 20×20 grid and is drawn at a whole number of device pixels per art pixel, the nearest to
// `size` (30 pt at 2x = 3 px per art pixel, pixel-perfect; 20 pt = 2 px). The characters fill ~14–18 of the 20
// cells, so the visible creature at 30 pt is about 21–27 pt; the rest is room for bubbles, sparkles and drops.
// Sizes that don't divide evenly snap to the nearest crisp size and may overhang the frame by a few transparent
// points — never clip the view.
//
// Motion: frames are pre-rendered once per character into one sprite strip (`MascotSpriteSheet`) and played by a
// discrete CAKeyframeAnimation on `contentsRect` — the render server drives every frame, the main thread does
// nothing per frame. Animations are removed while the view is hidden, out of a window, or its window is occluded.
// Reduce Motion: a single still frame per state; busy states (working, waiting, thinking) pulse opacity slowly.
//
// States (6–12 fps): idle — breathing + a blink (Codex blinks its `_` cursor, Kimi's dot hops); working — bobbing
// and pattering (Claude's rays spin, Kimi's dot bounces, Codex's cursor blinks fast); waiting — a hopping "!" bubble
// while it sways (or waves); done — crouch, happy bounce with a sparkle burst, then a content glow; error — a wince
// (`>_<`) and a shake, then a greyed-out slump: Codex drizzles as a rain cloud, the others shed a tear, Kimi's dot
// falls off; thinking — eyes up while "…" builds up (Codex types it after its prompt, Claude turns its rays slowly).

import AppKit
import NotchBuddyCore
import SwiftUI

enum MascotCharacter: String, CaseIterable, Hashable {
    case claude, codex, kimi, generic

    /// Claude, Codex and Kimi have their own characters; every other agent in `AgentCatalog` (Cursor, Copilot, …)
    /// gets the neutral blob until it has one.
    init(agent: AgentSource) {
        switch agent {
        case .claude: self = .claude
        case .codex: self = .codex
        case .kimi: self = .kimi
        default: self = .generic
        }
    }

    /// Agent ids as the bridge reports them ("claude", "codex", "kimi"); anything else gets the generic blob.
    init(agentID: String) {
        switch agentID.lowercased() {
        case "claude", "claude-code", "claudecode": self = .claude
        case "codex", "openai-codex": self = .codex
        case "kimi", "kimi-code", "kimicode": self = .kimi
        default: self = .generic
        }
    }
}

enum MascotState: String, CaseIterable, Hashable {
    case idle, working, waiting, done, error, thinking

    init(status: SessionStatus) {
        switch status {
        case .working: self = .working
        case .waitingForUser: self = .waiting
        case .finished: self = .done
        case .error: self = .error
        case .idle: self = .idle
        }
    }
}

/// An animated pixel mascot. See the API notes at the top of this file.
struct PixelMascotView: View {
    let character: MascotCharacter
    let state: MascotState
    var size: CGFloat = 30
    /// Whether the first state shown plays its intro (done's jump, error's fall). Pass false for a view built for a
    /// state that began a while ago (a list opening over a session that finished minutes ago); later changes of
    /// state always play theirs.
    var introOnAppear = true
    /// Overrides the environment's Reduce Motion (the island follows the system setting itself).
    var reduceMotion: Bool?
    /// VoiceOver's name for it (the generic blob stands in for many agents); nil: the character's own.
    var agentName: String?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(character: MascotCharacter, state: MascotState, size: CGFloat = 30, introOnAppear: Bool = true,
         reduceMotion: Bool? = nil, agentName: String? = nil) {
        self.character = character
        self.state = state
        self.size = size
        self.introOnAppear = introOnAppear
        self.reduceMotion = reduceMotion
        self.agentName = agentName
    }

    init(agent: AgentSource, state: MascotState, size: CGFloat = 30, introOnAppear: Bool = true,
         reduceMotion: Bool? = nil) {
        self.init(character: MascotCharacter(agent: agent), state: state, size: size, introOnAppear: introOnAppear,
                  reduceMotion: reduceMotion, agentName: agent.displayName)
    }

    init(agentID: String, state: MascotState, size: CGFloat = 30) {
        self.init(character: MascotCharacter(agentID: agentID), state: state, size: size)
    }

    var body: some View {
        MascotLayerView(character: character, state: state, reduceMotion: reduceMotion ?? systemReduceMotion,
                        introOnAppear: introOnAppear)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text(agentName ?? character.accessibilityName))
            .accessibilityValue(Text(state.accessibilityName))
    }
}

/// The still frame of a state as a plain SwiftUI image (nearest-neighbour), for `ImageRenderer` snapshots.
struct PixelMascotImage: View {
    let character: MascotCharacter
    let state: MascotState
    var size: CGFloat = 30
    /// Seconds into the state (films step the frames by their own clock); nil: the still (poster) frame.
    var time: Double? = nil

    var body: some View {
        let sheet = MascotSpriteSheet.shared(character)
        let timeline = sheet.timelines[state]
        let frame = time.flatMap { t in timeline?.frame(at: t) } ?? timeline.map(\.poster) ?? 0
        if let image = sheet.frameImage(frame) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

private struct MascotLayerView: NSViewRepresentable {
    let character: MascotCharacter
    let state: MascotState
    let reduceMotion: Bool
    let introOnAppear: Bool

    func makeNSView(context: Context) -> PixelMascotNSView {
        PixelMascotNSView(frame: .zero)
    }

    func updateNSView(_ view: PixelMascotNSView, context: Context) {
        view.mascotLayer.configure(character: character, state: state, reduceMotion: reduceMotion,
                                   introOnFirstShow: introOnAppear)
    }
}

private extension MascotCharacter {
    var accessibilityName: String {
        switch self {
        case .claude: return AgentSource.claude.displayName
        case .codex: return AgentSource.codex.displayName
        case .kimi: return AgentSource.kimi.displayName
        case .generic: return L("Агент")
        }
    }
}

private extension MascotState {
    var accessibilityName: String {
        switch self {
        case .idle: return SessionStatus.idle.label
        case .working: return SessionStatus.working.label
        case .waiting: return SessionStatus.waitingForUser.label
        case .done: return SessionStatus.finished.label
        case .error: return SessionStatus.error.label
        case .thinking: return L("Думает")
        }
    }
}
