import SwiftUI

extension NBIcon {
    /// The set's own icon for an SF Symbol name the island's views name their glyphs by (nil: nothing in the set
    /// fits, the symbol stays).
    static func replacing(symbol: String) -> NBIcon? {
        switch symbol {
        case "terminal", "apple.terminal", "keyboard": return .terminal
        case "pencil", "pencil.line", "square.and.pencil", "doc.badge.plus": return .edit
        case "doc.text", "photo": return .read
        case "magnifyingglass": return .search
        case "globe", "network": return .web
        case "person.2": return .agent
        case "map", "list.bullet.clipboard", "checklist": return .plan
        case "questionmark.bubble", "lock.open": return .question
        case "sparkles": return .sparkle
        case "hourglass": return .waiting
        case "puzzlepiece.extension": return .mcp
        case "wrench", "wrench.and.screwdriver", "stop.circle", "scope": return .wrench
        case "calendar", "calendar.badge.clock": return .calendar
        case "bell", "bell.fill": return .bell
        case "exclamationmark", "exclamationmark.triangle.fill", "exclamationmark.circle.fill": return .error
        case "moon.zzz.fill": return .idle
        case "checkmark", "checkmark.circle.fill": return .check
        case "xmark": return .close
        case "folder", "folder.fill": return .folder
        case "doc.on.doc": return .copy
        case "arrow.up.right": return .jump
        case "chevron.down": return .chevron
        case "clock", "timer": return .timer
        case "gearshape", "gearshape.fill": return .settings
        case "tray", "tray.full": return .tray
        default: return nil
        }
    }
}

/// A glyph named like an SF Symbol, drawn from NotchBuddy's own icon set when the set has it (`NBIcon.replacing`),
/// else the symbol itself. `size` is the point size the symbol was set in; the set's icon gets a box that looks as
/// big.
struct IslandSymbol: View {
    let name: String
    var size: CGFloat
    var weight: Font.Weight = .semibold
    /// nil: the ink of the control it sits in (`islandInk`, set by the island's button styles).
    var color: Color?
    var value: Double?
    var active = false
    var loops = false

    @Environment(\.islandInk) private var ink

    init(_ name: String, size: CGFloat, weight: Font.Weight = .semibold, color: Color? = nil, value: Double? = nil,
         active: Bool = false, loops: Bool = false) {
        self.name = name
        self.size = size
        self.weight = weight
        self.color = color
        self.value = value
        self.active = active
        self.loops = loops
    }

    var body: some View {
        let color = color ?? ink
        if let icon = NBIcon.replacing(symbol: name) {
            NBIconView(icon, size: (size * 1.45).rounded(), color: color, value: value, active: active, loops: loops)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
        }
    }
}

private struct IslandInkKey: EnvironmentKey { static let defaultValue = Color.white }

extension EnvironmentValues {
    /// The foreground of the control an icon sits in (the set's icons are drawn in an explicit color).
    var islandInk: Color {
        get { self[IslandInkKey.self] }
        set { self[IslandInkKey.self] = newValue }
    }
}
