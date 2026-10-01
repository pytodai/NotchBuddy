import SwiftUI
import NotchBuddyCore

/// A number (or clock, or percentage) that rolls like an odometer when it changes: each changed digit
/// slides out and the new one slides in, up when the number grows and down when it shrinks, the rightmost
/// digit first; digits that appear or go away roll in or out and the text's width follows. Other
/// characters (":", " %") stay put. Reduce Motion: a cross-fade.
///
///     NumberRoll("2:14", font: .system(size: 12, weight: .medium))
struct NumberRoll: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var stagger: Double = 0.12

    @State private var from: String?
    @State private var progress: Double = 1
    @State private var shown: String
    @Environment(\.islandReduceMotion) private var islandReduce
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @Environment(\.islandStaticRender) private var staticRender

    init(_ text: String, font: Font = .system(size: 13, weight: .semibold), stagger: Double = 0.12) {
        self.text = text
        self.font = font
        self.stagger = stagger
        _shown = State(initialValue: text)
    }

    /// The roll's spring: quick out of the gate, a soft landing with the slightest overshoot.
    static let curve = MotionCurve.spring(0.42, 0.82)

    var body: some View {
        NumberRollFace(from: from ?? shown, to: shown, progress: progress, font: font, stagger: stagger,
                       plain: islandReduce || systemReduce)
            .onChange(of: text) { old, new in
                guard !staticRender else {
                    shown = new
                    return
                }
                // Mid-roll: continue from what shows now (the target so far).
                from = shown
                shown = new
                progress = 0
                withAnimation(Self.curve.animation) { progress = 1 }
            }
            .accessibilityLabel(text)
    }
}

/// `NumberRoll` at a given moment of a roll from `from` to `to` (`progress` 0 … 1; a spring may overshoot).
struct NumberRollFace: View, Animatable {
    var from: String
    var to: String
    var progress: Double
    var font: Font
    var stagger: Double = 0.12
    var plain = false

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let columns = NumberRollPlan.columns(from: from, to: to)
        let direction: CGFloat = NumberRollPlan.direction(from: from, to: to) == .up ? 1 : -1
        let rolling = columns.filter(\.changes).count
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                let p = column.changes
                    ? NumberRollPlan.columnProgress(progress, index: rank(column, in: columns), count: rolling, stagger: stagger)
                    : 1
                NumberRollColumn(column: column, p: p, direction: direction, font: font, plain: plain)
            }
        }
        .fixedSize()
    }

    /// Among the changing columns, how far from the right this one is (the rightmost rolls first).
    private func rank(_ column: NumberRollPlan.Column, in columns: [NumberRollPlan.Column]) -> Int {
        columns.filter { $0.changes && $0.index < column.index }.count
    }
}

private struct NumberRollColumn: View {
    let column: NumberRollPlan.Column
    /// 0 … 1 (a spring may overshoot a little past 1).
    let p: Double
    let direction: CGFloat
    let font: Font
    let plain: Bool

    var body: some View {
        let q = min(max(p, 0), 1)
        let changes = column.changes
        let blur = changes && !plain ? 1.4 * sin(.pi * q) : 0
        // The old glyph and the new one share a cell whose width eases from the old's to the new's.
        RollCell(p: changes ? q : 1) {
            glyph(changes ? column.old : nil)
                .modifier(RollGlyph(shift: plain ? 0 : -CGFloat(p) * direction, opacity: 1 - smoothstep(0, 0.7, q), blur: blur))
            glyph(column.new)
                .modifier(RollGlyph(shift: changes && !plain ? CGFloat(1 - p) * direction : 0,
                                    opacity: changes ? smoothstep(0.2, 0.9, q) : 1, blur: blur))
        }
        // Soft edges above and below instead of a hard cut: glyphs roll in and out of a fade.
        .padding(.vertical, 3)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .padding(.vertical, -3)
    }

    private func glyph(_ c: Character?) -> some View {
        Text(c.map(String.init) ?? "").font(font).monospacedDigit().fixedSize()
    }
}

/// A glyph `shift` line heights off its place (+1: one line below).
private struct RollGlyph: ViewModifier {
    let shift: CGFloat
    let opacity: Double
    let blur: Double

    func body(content: Content) -> some View {
        content
            .visualEffect { view, proxy in
                view.offset(y: shift * proxy.size.height * 0.85)
            }
            .opacity(opacity)
            .blur(radius: blur)
    }
}

/// Two glyphs (old, new) centered in one cell as wide as `old` … `new` at `p`.
private struct RollCell: Layout {
    var p: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let a = subviews[0].sizeThatFits(.unspecified)
        let b = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: max(0, a.width + (b.width - a.width) * CGFloat(p)), height: max(a.height, b.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
        }
    }
}
