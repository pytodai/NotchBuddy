import NotchBuddyCore
import SwiftUI

/// A pixel mascot inside the island's content: live (`PixelMascotView`, frames played by the render server,
/// paused while its page is hidden or the panel is off screen), in a film (`islandFilmTime`) the frame at the film's
/// time, or, when the island is drawn to a still image (`--render-previews`), its still frame. Follows the island's
/// own Reduce Motion.
///
/// Session mascots that can fly between the closed island, the list and the card use `HeroSlot`, which draws this.
struct IslandMascot: View {
    let character: MascotCharacter
    let state: MascotState
    var size: CGFloat = 30
    var introOnAppear = true
    /// VoiceOver's name for it (`AgentSource.displayName`).
    var agentName: String?

    @Environment(\.islandStaticRender) private var staticRender
    @Environment(\.islandFilmTime) private var filmTime
    @Environment(\.islandReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    init(character: MascotCharacter, state: MascotState, size: CGFloat = 30, introOnAppear: Bool = true,
         agentName: String? = nil) {
        self.character = character
        self.state = state
        self.size = size
        self.introOnAppear = introOnAppear
        self.agentName = agentName
    }

    init(source: AgentSource, state: MascotState, size: CGFloat = 30, introOnAppear: Bool = true) {
        self.init(character: MascotCharacter(agent: source), state: state, size: size, introOnAppear: introOnAppear,
                  agentName: source.displayName)
    }

    var body: some View {
        Group {
            if let filmTime, !reduceMotion {
                // A film (`--render-promo`, stage films): the frames at the film's time since the page came in.
                let intro = introOnAppear ? 0 : MascotSpriteSheet.shared(character).timelines[state]?.introDuration ?? 0
                PixelMascotImage(character: character, state: state,
                                 size: PixelMascotLayer.crispSide(size, scale: displayScale), time: filmTime + intro)
            } else if staticRender || filmTime != nil {
                PixelMascotImage(character: character, state: state,
                                 size: PixelMascotLayer.crispSide(size, scale: displayScale))
            } else {
                PixelMascotView(character: character, state: state, size: size, introOnAppear: introOnAppear,
                                reduceMotion: reduceMotion, agentName: agentName)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}
