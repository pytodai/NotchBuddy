import AppKit
import CoreImage
import SwiftUI

/// The promo's still art, drawn once per render: the wallpaper, the menu bar, captions, title cards and the cursor.
/// Calm and neutral: muted dunes under a pale sky; type in Manrope, dark on the sky, white on black.
@MainActor
enum PromoArt {
    // MARK: Wallpaper

    /// Layered dunes under a pale slate sky, with a little film grain (keeps H.264 from banding the gradients).
    /// `size` in pixels.
    static func wallpaper(size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(w), H = CGFloat(h)
        // CG's origin is bottom-left: y = H - top.
        func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: a)
        }
        func vertical(_ colors: [CGColor], _ stops: [CGFloat], top: CGFloat, bottom: CGFloat) {
            guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops) else { return }
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H - top), end: CGPoint(x: 0, y: H - bottom),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // Sky: pale slate at the top (the black island reads crisply against it), warming toward the horizon.
        vertical([rgb(0x9AA5B3), rgb(0xB9BCC0), rgb(0xD8CEC2)], [0, 0.42, 1], top: 0, bottom: H * 0.62)
        // A soft low sun behind the dunes.
        if let sun = CGGradient(colorsSpace: space, colors: [rgb(0xFFF4E6, 0.55), rgb(0xFFF4E6, 0)] as CFArray,
                                locations: [0, 1]) {
            ctx.drawRadialGradient(sun, startCenter: CGPoint(x: W * 0.66, y: H - H * 0.5), startRadius: 0,
                                   endCenter: CGPoint(x: W * 0.66, y: H - H * 0.5), endRadius: W * 0.42, options: [])
        }
        // Dunes, far to near: each a smooth ridge filled with a gentle vertical gradient.
        struct Dune { var base: CGFloat; var waves: [(a: CGFloat, l: CGFloat, p: CGFloat)]; var top: UInt32; var bottom: UInt32 }
        let dunes = [
            Dune(base: 0.55, waves: [(0.035, 1.3, 0.4), (0.012, 0.45, 1.9)], top: 0xBDB1A5, bottom: 0xA99D92),
            Dune(base: 0.63, waves: [(0.045, 1.05, 2.3), (0.015, 0.38, 0.7)], top: 0x9C9188, bottom: 0x877D75),
            Dune(base: 0.73, waves: [(0.05, 0.9, 4.1), (0.018, 0.33, 2.6)], top: 0x716A64, bottom: 0x5D5752),
            Dune(base: 0.84, waves: [(0.045, 1.2, 1.2), (0.02, 0.41, 5.2)], top: 0x47423F, bottom: 0x2F2C2B),
        ]
        for dune in dunes {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            let steps = 240
            var minTop = H
            for i in 0...steps {
                let x = CGFloat(i) / CGFloat(steps)
                var y = dune.base
                for wave in dune.waves { y += wave.a * sin(2 * .pi * x / wave.l + wave.p) }
                minTop = min(minTop, y * H)
                path.addLine(to: CGPoint(x: x * W, y: H - y * H))
            }
            path.addLine(to: CGPoint(x: W, y: 0))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            vertical([rgb(dune.top), rgb(dune.bottom)], [0, 1], top: minTop, bottom: H)
            ctx.restoreGState()
            // Haze over the farther dunes: the next one stands out in front.
            vertical([rgb(0xD8CEC2, 0.10), rgb(0xD8CEC2, 0)], [0, 1], top: minTop, bottom: minTop + H * 0.12)
        }
        // Vignette.
        if let vignette = CGGradient(colorsSpace: space, colors: [rgb(0x000000, 0), rgb(0x000000, 0.28)] as CFArray,
                                     locations: [0.55, 1]) {
            ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: W / 2, y: H * 0.55), startRadius: 0,
                                   endCenter: CGPoint(x: W / 2, y: H * 0.55), endRadius: hypot(W, H) * 0.62,
                                   options: [.drawsAfterEndLocation])
        }
        guard let base = ctx.makeImage() else { return nil }
        return soften(base, radius: max(1, W / 1400))
    }

    /// A slight blur (the ridges read as soft light, not vector edges) plus fine monochrome grain.
    private static func soften(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(radius)).cropped(to: extent)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let soft = context.createCGImage(blurred, from: extent, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return grain(soft, amplitude: 3)
    }

    /// Adds uniform monochrome noise of ±`amplitude` levels to every pixel (a fixed seed: every render is the same).
    /// Keeps H.264 and the GIF palette from banding the soft gradients, and stays invisible at a glance.
    private static func grain(_ image: CGImage, amplitude: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let span = UInt64(2 * amplitude + 1)
        for i in 0..<(w * h) {
            // xorshift64*
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let n = Int(((state &* 0x2545_F491_4F6C_DD1D) >> 33) % span) - amplitude
            for c in 0..<3 {
                let v = Int(pixels[i * 4 + c]) + n
                pixels[i * 4 + c] = UInt8(clamping: v)
            }
        }
        return ctx.makeImage()
    }

    // MARK: Menu bar

    static func menuBar(width: CGFloat, height: CGFloat, notch: CGFloat, lang: PromoLanguage, scale: CGFloat) -> CGImage? {
        let en = lang == .en
        let menus = en ? ["Shell", "Edit", "View"] : ["Shell", "Правка", "Вид"]
        let view = HStack(spacing: 0) {
            HStack(spacing: 19) {
                Image(systemName: "apple.logo").font(.system(size: 15, weight: .medium))
                Text(verbatim: en ? "Terminal" : "Терминал").font(.system(size: 13.5, weight: .bold))
                ForEach(menus, id: \.self) { Text(verbatim: $0).font(.system(size: 13.5, weight: .regular)) }
            }
            Spacer(minLength: notch + 40)
            HStack(spacing: 17) {
                Image(systemName: "magnifyingglass").font(.system(size: 13.5, weight: .medium))
                Image(systemName: "wifi").font(.system(size: 13.5, weight: .medium))
                Image(systemName: "battery.75percent").font(.system(size: 15, weight: .regular))
                Image(systemName: "switch.2").font(.system(size: 13, weight: .medium))
                Text(verbatim: en ? "Wed Sep 30  9:41" : "Ср 30 сент.  9:41").font(.system(size: 13.5, weight: .medium))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Color.black.opacity(0.82))
        .padding(.horizontal, 20)
        .frame(width: width, height: height)
        .background(Color.white.opacity(0.24))
        return render(view, scale: scale)
    }

    // MARK: Type (Manrope, like the app)

    /// Room around a word's glyphs (its shadow, descenders): the layout subtracts it.
    static func wordPadding(_ size: CGFloat) -> CGFloat { (size * 0.3).rounded() }

    private static func inkColor(_ ink: PromoCaption.Ink) -> Color {
        ink == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color.white
    }

    /// One word of a kinetic caption: bold, tight, dark on the pale sky or white (with a soft shadow) on dark.
    static func word(_ text: String, size: CGFloat, ink: PromoCaption.Ink, scale: CGFloat) -> CGImage? {
        let view = Text(verbatim: text)
            .font(NBTypography.font(size: size, weight: 720))
            .tracking(-size * 0.025)
            .foregroundStyle(inkColor(ink))
            .fixedSize()
            .shadow(color: Color.black.opacity(ink == .light ? 0.32 : 0), radius: size * 0.22, y: 1)
            .padding(wordPadding(size))
        return render(view, scale: scale)
    }

    /// The small line under a caption.
    static func subline(_ text: String, size: CGFloat, ink: PromoCaption.Ink, scale: CGFloat) -> CGImage? {
        let view = Text(verbatim: text)
            .font(NBTypography.font(size: size, weight: 560))
            .foregroundStyle(inkColor(ink).opacity(ink == .dark ? 0.62 : 0.74))
            .fixedSize()
            .shadow(color: Color.black.opacity(ink == .light ? 0.3 : 0), radius: size * 0.3, y: 1)
            .padding(wordPadding(size))
        return render(view, scale: scale)
    }

    /// A title card's pieces, white on black: [app icon (or nil), name, line, small line (or nil)].
    static func titlePieces(_ title: PromoTitle, lang: PromoLanguage, scale: CGFloat) -> [CGImage?] {
        var icon: CGImage?
        if title.icon, let image = AppIconImage.image {
            let side: CGFloat = 132
            var rect = NSRect(x: 0, y: 0, width: side * scale, height: side * scale)
            icon = image.cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        let name = render(Text(verbatim: title.title)
            .font(NBTypography.font(size: 92, weight: 800))
            .tracking(-2.6)
            .foregroundStyle(Color.white)
            .fixedSize()
            .padding(.horizontal, 24), scale: scale)
        let line = render(Text(verbatim: title.line(lang))
            .font(NBTypography.font(size: 34, weight: 620))
            .tracking(-0.4)
            .foregroundStyle(Color.white.opacity(0.8))
            .fixedSize()
            .padding(.horizontal, 24), scale: scale)
        let small = title.small.map { small in
            render(Text(verbatim: small(lang))
                .font(NBTypography.font(size: 22, weight: 600))
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize()
                .padding(.horizontal, 24), scale: scale)
        } ?? nil
        return [icon, name, line, small]
    }

    // MARK: Desk windows (the external monitor's desktop)

    /// A light window's chrome: white, rounded, a hairline edge and a soft shadow, with `PromoDesk.shadowPad` of room
    /// around it for the shadow.
    private static func window<C: View>(_ size: CGSize, @ViewBuilder _ content: () -> C) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return content()
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(shape.fill(Color.white))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.black.opacity(0.13), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
            .shadow(color: .black.opacity(0.20), radius: 16, y: 9)
            .padding(PromoDesk.shadowPad)
    }

    private static func trafficLights() -> some View {
        HStack(spacing: 7) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) { color in
                Circle().fill(color).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            }
        }
    }

    private static let ink = Color(red: 0.11, green: 0.11, blue: 0.12)

    /// Finder on the Downloads folder: a sidebar, a toolbar and the files as icons (Quick Look thumbnails). `selected`:
    /// that icon is selected (graphite highlight), as it is while it is dragged.
    static func finderWindow(items: [(name: String, thumbnail: ShelfThumbnail?)], selected: Int?, lang: PromoLanguage,
                             scale: CGFloat) -> CGImage? {
        let en = lang == .en
        let size = PromoDesk.finder.size
        let favorites: [(String, String)] = [
            ("clock", en ? "Recents" : "Недавние"), ("square.grid.2x2", en ? "Applications" : "Программы"),
            ("menubar.dock.rectangle", en ? "Desktop" : "Рабочий стол"), ("doc", en ? "Documents" : "Документы"),
            ("arrow.down.circle", en ? "Downloads" : "Загрузки"),
        ]
        let view = window(size) {
            ZStack(alignment: .topLeading) {
                // Sidebar: an inset panel, the window's controls at its top.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0.945))
                    .frame(width: PromoDesk.sidebar - 10, height: size.height - 12)
                    .offset(x: 6, y: 6)
                trafficLights().offset(x: 17, y: 17)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: en ? "Favorites" : "Избранное")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.38))
                        .padding(.bottom, 5)
                    ForEach(Array(favorites.enumerated()), id: \.offset) { i, entry in
                        let on = i == favorites.count - 1
                        HStack(spacing: 5) {
                            Image(systemName: entry.0).font(.system(size: 9.5, weight: .medium))
                                .frame(width: 13)
                                .foregroundStyle(Color.black.opacity(on ? 0.7 : 0.5))
                            Text(verbatim: entry.1).font(.system(size: 10, weight: .regular)).lineLimit(1)
                                .foregroundStyle(ink.opacity(0.85))
                        }
                        .padding(.horizontal, 5)
                        .frame(width: PromoDesk.sidebar - 20, height: 21, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(on ? 0.075 : 0)))
                    }
                }
                .offset(x: 11, y: 44)
                // Toolbar.
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.5))
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.22))
                    Text(verbatim: en ? "Downloads" : "Загрузки").font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(ink)
                    Spacer(minLength: 0)
                    Image(systemName: "square.grid.2x2").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.5))
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.5))
                }
                .frame(width: size.width - PromoDesk.sidebar - 26, height: PromoDesk.toolbar)
                .offset(x: PromoDesk.sidebar + 12, y: 0)
                // The files.
                ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { i, item in
                    let rect = PromoDesk.iconRect(i)
                    let on = i == selected
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(on ? 0.085 : 0))
                        .frame(width: rect.width + 10, height: rect.height + 8)
                        .offset(x: rect.minX - 5, y: rect.minY - 4)
                    deskIcon(item.thumbnail, box: rect.width)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    Text(verbatim: item.name)
                        .font(.system(size: 9.5, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Color.white : ink.opacity(0.88))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(white: 0.43).opacity(on ? 1 : 0)))
                        .frame(width: PromoDesk.cell.width - 2, height: 30, alignment: .top)
                        .offset(x: rect.midX - (PromoDesk.cell.width - 2) / 2, y: rect.maxY + 5)
                }
            }
        }
        return render(view, scale: scale)
    }

    /// A file's icon on the desk: a content thumbnail in a thin white frame with a soft shadow (as Finder draws
    /// pictures and documents), or the Finder icon as is.
    @ViewBuilder
    static func deskIcon(_ thumbnail: ShelfThumbnail?, box: CGFloat) -> some View {
        if let thumbnail {
            if thumbnail.isIcon {
                Image(nsImage: thumbnail.image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: box, height: box)
            } else {
                let size = thumbnail.image.size
                let aspect = size.height > 0 ? size.width / size.height : 1
                let inner = box - 6
                let w = aspect >= 1 ? inner : inner * aspect, h = aspect >= 1 ? inner / aspect : inner
                Image(nsImage: thumbnail.image).resizable().interpolation(.high)
                    .frame(width: w, height: h)
                    .padding(1.5)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.28), radius: 1.6, y: 0.6)
            }
        }
    }

    /// A Mail message being written: the window's controls, To and Subject, a greeting, and room under it for the
    /// photo (`PromoDesk.attachment`).
    static func mailWindow(lang: PromoLanguage, scale: CGFloat) -> CGImage? {
        let en = lang == .en
        let size = PromoDesk.mail.size
        let subject = en ? "Last night’s sunset" : "Вчерашний закат"
        func row(_ label: String, @ViewBuilder _ value: () -> some View) -> some View {
            HStack(spacing: 6) {
                Text(verbatim: label).font(.system(size: 10.5, weight: .regular)).foregroundStyle(Color.black.opacity(0.42))
                value()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: size.width, height: PromoDesk.mailFieldHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 12)
            }
        }
        let view = window(size) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    trafficLights()
                    Image(systemName: "paperplane").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.5))
                        .padding(.leading, 18)
                    Spacer(minLength: 0)
                    Text(verbatim: subject).font(.system(size: 12.5, weight: .bold)).foregroundStyle(ink)
                    Spacer(minLength: 0)
                    Image(systemName: "paperclip").font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .frame(width: size.width, height: PromoDesk.toolbar)
                row(en ? "To:" : "Кому:") {
                    Text(verbatim: en ? "Anna" : "Анна").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ink.opacity(0.85))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(Color.black.opacity(0.07)))
                }
                row(en ? "Subject:" : "Тема:") {
                    Text(verbatim: subject).font(.system(size: 10.5, weight: .medium)).foregroundStyle(ink.opacity(0.88))
                }
                Text(verbatim: en ? "Hi Anna! Here it is:" : "Привет! Вот он:")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(ink.opacity(0.88))
                    .padding(.leading, PromoDesk.attachment.minX)
                    .padding(.top, 14)
            }
        }
        return render(view, scale: scale)
    }

    /// The dragged photo (it ends in the message as its attachment): rounded, a thin white edge. `size` in points.
    static func carriedPhoto(_ image: NSImage, size: CGSize, scale: CGFloat) -> CGImage? {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let view = Image(nsImage: image).resizable().interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
        return render(view, scale: scale)
    }

    // MARK: Cursor

    /// The system arrow at `scale`, and its hot spot in points.
    static func cursor(scale: CGFloat) -> (image: CGImage?, size: CGSize, hotSpot: CGPoint) {
        let cursor = NSCursor.arrow
        let size = cursor.image.size
        var rect = NSRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        let image = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        return (image, size, cursor.hotSpot)
    }

    // MARK: -

    private static func render<V: View>(_ view: V, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = scale
        return renderer.cgImage.flatMap(IslandPreviewRenderer.sRGB)
    }
}
