import AppKit
import SwiftUI

/// The silhouette as a `CGPath` for the stage's shape layers: flush with the top edge with concave ears («Чёлка»),
/// or floating `top` points below it with round top corners («Островок»), smooth bottom corners, the pulse on top.
/// Always built from the same list of elements, even when the shape has no width or height, or sits mid-way between
/// the two styles, so Core Animation interpolates between any two of them point by point.
enum IslandPathBuilder {
    /// Proportions of the smooth (continuous) corners: a corner of radius r spans `extent × r` along each edge.
    static let extent: CGFloat = 1.28
    static let handle: CGFloat = 0.36

    /// `closed` false: the outline for strokes, without the top edge where the island meets the screen's edge (a
    /// detached island's top edge is part of its outline: then the last segment draws it).
    static func path(_ g: IslandGeometry, pulse: IslandPulse, canvasWidth: CGFloat, closed: Bool = true) -> CGPath {
        let d = g.detachment
        let boost = max(0, pulse.earBoost)
        let h = max(0, g.height + pulse.dh)
        let w = max(0, g.width) + 2 * boost
        let rect = CGRect(x: canvasWidth / 2 - w / 2, y: max(0, g.top), width: w, height: h)
        // Round early while growing, soft while shrinking; a very shallow island is as round as it can be (a drop, not
        // a strip with square corners).
        let k = 0.27 + 0.23 * max(0, 1 - h / 30)
        let shallow = min(IslandLayout.openBottom, h * k)
        let bottomRadius = max(g.bottom, shallow)
        // A detached capsule has no ears: its pulse widens it instead of flaring them.
        let earRadius = max(0, g.ear) + boost * (1 - d)
        let crownRadius = max(0, max(g.crown, shallow * d))

        let ear = max(0, min(earRadius, rect.width / 4, rect.height / 2))
        let left = rect.minX + ear
        let right = rect.maxX - ear
        let top = rect.minY
        // The top corner is concave (the ear) or convex (the crown), never both: the larger wins by the difference, so a
        // morph between the styles passes through a square corner.
        // Detached («Островок») corners are circular arcs (a true capsule when closed, like the Dynamic Island); attached
        // («Чёлка») ones keep the smooth continuous curve.
        let ext = extent + (1 - extent) * d
        let hnd = handle + (0.4477 - handle) * d
        let concave = max(0, ear - crownRadius)
        let convexLimit = max(0, min((right - left) / (2 * ext), rect.height / (2 * ext)))
        let convex = min(max(0, crownRadius - ear), convexLimit)
        let topSpan = convex * ext
        let topHandle = convex * hnd
        let r = max(0, min(bottomRadius, (right - left) / (2 * ext), (rect.height - max(concave, topSpan)) / ext))
        let span = r * ext
        let bottomHandle = r * hnd

        let start = CGPoint(x: left - concave + topSpan, y: top)
        let end = CGPoint(x: right + concave - topSpan, y: top)
        let p = CGMutablePath()
        p.move(to: start)
        // Top-left: a concave ear (a quadratic arc, written as a cubic) or a convex corner; the other one is empty.
        p.addCurve(to: CGPoint(x: left, y: top + concave + topSpan),
                   control1: CGPoint(x: left - concave / 3 + topHandle, y: top),
                   control2: CGPoint(x: left, y: top + concave / 3 + topHandle))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - span))
        p.addCurve(to: CGPoint(x: left + span, y: rect.maxY),
                   control1: CGPoint(x: left, y: rect.maxY - bottomHandle),
                   control2: CGPoint(x: left + bottomHandle, y: rect.maxY))
        p.addLine(to: CGPoint(x: right - span, y: rect.maxY))
        p.addCurve(to: CGPoint(x: right, y: rect.maxY - span),
                   control1: CGPoint(x: right - bottomHandle, y: rect.maxY),
                   control2: CGPoint(x: right, y: rect.maxY - bottomHandle))
        p.addLine(to: CGPoint(x: right, y: top + concave + topSpan))
        p.addCurve(to: end,
                   control1: CGPoint(x: right, y: top + concave / 3 + topHandle),
                   control2: CGPoint(x: right + concave / 3 - topHandle, y: top))
        if closed {
            p.closeSubpath()
        } else {
            // Attached, the top edge is the screen's (nothing to stroke): the segment has no length. Detached, it closes
            // the outline.
            p.addLine(to: CGPoint(x: end.x + (start.x - end.x) * d, y: top))
        }
        return p
    }
}

/// A soft light (or shadow) around the silhouette's body, rendered once and stretched to the body as it moves
/// (nine-slice: the corners stay as rendered, the edges stretch), so a moving silhouette never redraws a blur.
/// Its flat top sits above the canvas: the island continues behind the top edge.
@MainActor
struct IslandSurfaceImage {
    let image: CGImage
    let scale: CGFloat
    /// Room around the shape (the blur fades out within it).
    let pad: CGFloat
    /// How far below the body the light reaches further (a `y` offset of the shadow).
    let dy: CGFloat
    let caps: NSEdgeInsets

    /// The glow of `IslandGlow` (as `GlowImage`, white: tinted per glow).
    static let glow = IslandSurfaceImage(image: GlowImage.image, scale: GlowImage.scale, pad: GlowImage.pad,
                                         dy: GlowImage.dy, caps: NSEdgeInsets(top: GlowImage.caps.top, left: GlowImage.caps.leading,
                                                                              bottom: GlowImage.caps.bottom, right: GlowImage.caps.trailing))

    /// The ambient drop shadow (`.shadow(radius: 22, y: 10)` of the silhouette), black; its opacity is the geometry's.
    static let shadow: IslandSurfaceImage = {
        let radius: CGFloat = 22
        let dy: CGFloat = 10
        let pad = (radius * 2.2).rounded(.up)
        let corner = IslandLayout.openBottom
        let side = 2 * (2 * pad + corner) + 8
        let away: CGFloat = 8 * (side + 2 * pad)
        // Round all around: attached, the top corners stay above the canvas (the island continues behind the top edge);
        // detached («Островок»), they round the capsule's shadow.
        let view = RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.black)
            .frame(width: side, height: side)
            .offset(x: away)
            .shadow(color: .black, radius: radius, x: -away, y: 0)
            .padding(pad)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = renderer.cgImage ?? GlowImage.image
        return IslandSurfaceImage(image: image, scale: 2, pad: pad, dy: dy,
                                  caps: NSEdgeInsets(top: 2 * pad, left: 2 * pad + corner, bottom: 2 * pad + corner,
                                                     right: 2 * pad + corner))
    }()

    /// `contentsCenter` for the caps.
    var contentsCenter: CGRect {
        let w = CGFloat(image.width) / scale, h = CGFloat(image.height) / scale
        guard w > caps.left + caps.right, h > caps.top + caps.bottom else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        // Layer contents are laid out with a top-left origin in a flipped layer; `contentsCenter` is in unit
        // coordinates of the image, whose first row is its top.
        return CGRect(x: caps.left / w, y: caps.top / h,
                      width: (w - caps.left - caps.right) / w, height: (h - caps.top - caps.bottom) / h)
    }

    /// Where the stretched image goes for a body `bodyWidth` wide and `height` tall, centered on the canvas, `top` below
    /// its top edge. Attached (`detachment` 0) its flat top sits above the canvas: the island continues behind the top
    /// edge. Detached (1, «Островок») the light rounds the capsule's top too.
    func frame(bodyWidth: CGFloat, height: CGFloat, top: CGFloat = 0, detachment: CGFloat = 0,
               canvasWidth: CGFloat) -> CGRect {
        let width = max(0, bodyWidth) + 2 * pad
        let bottom = max(0, top) + max(0, height) + dy + pad
        let attachedY = -2 * pad
        let detachedY = max(0, top) + dy - pad
        let y = attachedY + (detachedY - attachedY) * min(max(detachment, 0), 1)
        return CGRect(x: canvasWidth / 2 - width / 2, y: y, width: width, height: max(0, bottom - y))
    }

    /// The image with its light in `color` (the glow's tint).
    func tinted(_ color: NSColor) -> CGImage {
        let key = color.usingColorSpace(.sRGB).map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent)" } ?? "\(color)"
        if let hit = IslandSurfaceImage.tints[key] { return hit }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        // The light keeps its alpha and takes the color.
        context.setBlendMode(.sourceIn)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        let tinted = context.makeImage() ?? image
        if IslandSurfaceImage.tints.count > 16 { IslandSurfaceImage.tints.removeAll() }
        IslandSurfaceImage.tints[key] = tinted
        return tinted
    }

    private static var tints: [String: CGImage] = [:]
}
