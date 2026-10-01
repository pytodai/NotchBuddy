// A frozen copy of the island silhouette (Sources/NotchBuddy/Island/IslandShape.swift), used only to draw the app icon.
import SwiftUI

/// The island's silhouette, the same on every screen: flush with the top edge, with concave "ears"
/// (`earRadius`) that flare into the top edge the way the camera housing does, and smooth convex
/// bottom corners.
struct IslandShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(earRadius, bottomRadius) }
        set {
            earRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    static func notch(ear: CGFloat, bottom: CGFloat) -> IslandShape {
        IslandShape(earRadius: ear, bottomRadius: bottom)
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let ear = min(earRadius, rect.width / 4, rect.height / 2)
        let left = rect.minX + ear
        let right = rect.maxX - ear
        // The smooth corner spans `extent * r` along each edge; keep it inside the body.
        let extent: CGFloat = 1.28
        let r = max(0, min(bottomRadius, (right - left) / (2 * extent), (rect.height - ear) / extent))
        let span = r * extent
        let handle = r * 0.36

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.minY + ear), control: CGPoint(x: left, y: rect.minY))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - span))
        p.addCurve(to: CGPoint(x: left + span, y: rect.maxY),
                   control1: CGPoint(x: left, y: rect.maxY - handle),
                   control2: CGPoint(x: left + handle, y: rect.maxY))
        p.addLine(to: CGPoint(x: right - span, y: rect.maxY))
        p.addCurve(to: CGPoint(x: right, y: rect.maxY - span),
                   control1: CGPoint(x: right - handle, y: rect.maxY),
                   control2: CGPoint(x: right, y: rect.maxY - handle))
        p.addLine(to: CGPoint(x: right, y: rect.minY + ear))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
