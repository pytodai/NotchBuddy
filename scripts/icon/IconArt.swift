import SwiftUI
import AppKit

/// The app icon: the top of a Mac screen with a wide notch hanging from the bezel, and in it what the island shows —
/// the Claude buddy, the activity bars, the "+2" sessions badge and the usage ring. Flat colours, no glow.
struct Icon: View {
    /// The buddy's idle frame (20 × 20 art pixels): the second argument, or `mascot-claude.png` next to the binary's cwd.
    static let mascot: NSImage? = NSImage(contentsOfFile: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "mascot-claude.png")

    /// The middle of the screen: "dunes" (the icon), or the alternatives "cursor", "trio", "list".
    static let variant = ProcessInfo.processInfo.environment["ICON_VARIANT"] ?? "dunes"

    static let side: CGFloat = 824
    static let bezel: CGFloat = 64
    static let notchWidth: CGFloat = 712
    static let notchHeight: CGFloat = 206
    static let ear: CGFloat = 40

    var body: some View {
        ZStack {
            // macOS icon grid: 1024 canvas, 824 body with a ~185 continuous corner.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.83)], startPoint: .top, endPoint: .bottom))
                .frame(width: Self.side, height: Self.side)
                .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
            ZStack(alignment: .top) {
                // A soft shadow under the notch, as on a real screen.
                IslandShape.notch(ear: Self.ear, bottom: 84)
                    .fill(Color.black.opacity(0.2))
                    .frame(width: Self.notchWidth, height: Self.notchHeight)
                    .blur(radius: 26)
                    .offset(y: Self.bezel + 10)
                Rectangle().fill(Color.black).frame(height: Self.bezel)
                IslandShape.notch(ear: Self.ear, bottom: 84)
                    .fill(Color.black)
                    .frame(width: Self.notchWidth, height: Self.notchHeight)
                    .offset(y: Self.bezel - 2)
                content
                    .frame(width: Self.notchWidth - 2 * Self.ear - 56, height: Self.notchHeight - Self.ear)
                    .offset(y: Self.bezel + Self.ear / 2 - 2)
                middle
                    .frame(width: Self.side, height: Self.side - Self.bezel - Self.notchHeight)
                    .offset(y: Self.bezel + Self.notchHeight - 8)
            }
            .frame(width: Self.side, height: Self.side, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
            // A hairline edge, so the black top still reads as the icon's edge on a dark Dock.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 3)
                .frame(width: Self.side, height: Self.side)
        }
        .frame(width: 1024, height: 1024)
    }

    static func art(_ name: String) -> NSImage? {
        let dir = (CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "mascot-claude.png") as NSString
        return NSImage(contentsOfFile: dir.deletingLastPathComponent.isEmpty ? name : dir.deletingLastPathComponent + "/" + name)
    }

    private func pixel(_ image: NSImage?, _ side: CGFloat) -> some View {
        Group {
            if let image { Image(nsImage: image).interpolation(.none).resizable().frame(width: side, height: side) }
        }
    }

    @ViewBuilder private var middle: some View {
        switch Self.variant {
        case "trio":
            // The three agents it watches, side by side.
            HStack(spacing: 40) {
                pixel(Self.art("mascot-claude.png"), 170)
                pixel(Self.art("mascot-codex.png"), 170)
                pixel(Self.art("mascot-kimi.png"), 170)
            }
            .shadow(color: .black.opacity(0.10), radius: 8, y: 6)
        case "list":
            // The open list: three sessions, one row each.
            VStack(spacing: 22) {
                row("mascot-claude.png", 300, Color(red: 0.36, green: 0.62, blue: 1.0))
                row("mascot-codex.png", 250, Color(red: 0.20, green: 0.70, blue: 0.40))
                row("mascot-kimi.png", 280, Color(red: 0.95, green: 0.62, blue: 0.20))
            }
        case "cursor":
            // The pointer heading for the notch: hover and it opens.
            CursorArrow()
                .fill(Color.black)
                .overlay(CursorArrow().stroke(Color.white, style: StrokeStyle(lineWidth: 12, lineJoin: .round)))
                .frame(width: 150, height: 228)
                .rotationEffect(.degrees(-8))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
                .offset(x: 40, y: 10)
        default:
            // A calm wallpaper: pale sky over soft dunes.
            ZStack(alignment: .bottom) {
                Dune(height: 0.62, phase: 0.1).fill(Color(red: 0.86, green: 0.80, blue: 0.72))
                Dune(height: 0.42, phase: 0.55).fill(Color(red: 0.78, green: 0.69, blue: 0.59))
                Dune(height: 0.24, phase: 0.2).fill(Color(red: 0.67, green: 0.57, blue: 0.47))
            }
            .frame(width: Self.side, height: Self.side - Self.bezel - Self.notchHeight + 8)
        }
    }

    private func row(_ name: String, _ width: CGFloat, _ dot: Color) -> some View {
        HStack(spacing: 26) {
            pixel(Self.art(name), 84)
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(Color.white.opacity(0.9)).frame(width: width, height: 20)
                Capsule().fill(Color.white.opacity(0.35)).frame(width: width * 0.7, height: 14)
            }
            Spacer()
            Circle().fill(dot).frame(width: 30, height: 30)
        }
        .padding(.horizontal, 30)
        .frame(width: 600, height: 116)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color.black))
    }

    private var content: some View {
        HStack(spacing: 0) {
            if let mascot = Self.mascot {
                Image(nsImage: mascot)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 128, height: 128)
            }
            HStack(alignment: .center, spacing: 12) {
                ForEach([28.0, 54.0, 40.0], id: \.self) { h in
                    Capsule().fill(Color(red: 0.36, green: 0.62, blue: 1.0)).frame(width: 14, height: h)
                }
            }
            .padding(.leading, 18)
            Spacer()
            Text("2:14")
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.92))
            Spacer()
            Text("+2")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .padding(.trailing, 26)
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 14)
                Circle().trim(from: 0, to: 0.68)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 78, height: 78)
        }
    }
}

@MainActor func render(_ out: String) {
    let r = ImageRenderer(content: Icon())
    r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("fail"); return }
    try! png.write(to: URL(fileURLWithPath: out)); print("ok")
}
@main struct App { static func main() { MainActor.assumeIsolated { render(CommandLine.arguments[1]) } } }

/// The macOS arrow pointer, tip at the top left.
struct CursorArrow: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + h * 0.80))
        p.addLine(to: CGPoint(x: r.minX + w * 0.27, y: r.minY + h * 0.60))
        p.addLine(to: CGPoint(x: r.minX + w * 0.45, y: r.minY + h))
        p.addLine(to: CGPoint(x: r.minX + w * 0.63, y: r.minY + h * 0.93))
        p.addLine(to: CGPoint(x: r.minX + w * 0.46, y: r.minY + h * 0.55))
        p.addLine(to: CGPoint(x: r.minX + w, y: r.minY + h * 0.55))
        p.closeSubpath()
        return p
    }
}

/// A soft dune: a smooth crest across the width, filled to the bottom.
struct Dune: Shape {
    var height: CGFloat
    var phase: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let top = r.maxY - r.height * height
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: top + r.height * 0.10 * sin(phase * 6.28)))
        let steps = 48
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let y = top + r.height * 0.10 * sin((t + phase) * 6.28) + r.height * 0.05 * sin((t * 2.3 + phase) * 6.28)
            p.addLine(to: CGPoint(x: r.minX + r.width * t, y: y))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
