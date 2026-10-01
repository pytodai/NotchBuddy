import Foundation

/// An sRGB color, components 0…1.
public struct PaletteColor: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Hue 0…1, saturation 0…1, value 0…1.
    public var hsv: (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC == 0 ? 0 : delta / maxC, maxC)
    }

    public init(h: Double, s: Double, v: Double) {
        let h6 = (h - h.rounded(.down)) * 6
        let i = Int(h6.rounded(.down)) % 6
        let f = h6 - h6.rounded(.down)
        let s = min(max(s, 0), 1), v = min(max(v, 0), 1)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: self.init(v, t, p)
        case 1: self.init(q, v, p)
        case 2: self.init(p, v, t)
        case 3: self.init(p, q, v)
        case 4: self.init(t, p, v)
        default: self.init(v, p, q)
        }
    }

    /// Relative luminance (WCAG).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

/// The colors of an album cover, for the widget's glow and accents.
public struct ArtworkPalette: Equatable, Sendable {
    /// The cover's most characteristic color: large and vivid areas win over dark or grey ones.
    public var primary: PaletteColor
    /// A second color of the cover (another hue), or a deeper shade of `primary`.
    public var secondary: PaletteColor
    public var average: PaletteColor
    /// Almost no color in the cover (a black-and-white photo): the glow is a soft white.
    public var isMonochrome: Bool

    public init(primary: PaletteColor, secondary: PaletteColor, average: PaletteColor, isMonochrome: Bool) {
        self.primary = primary
        self.secondary = secondary
        self.average = average
        self.isMonochrome = isMonochrome
    }

    /// The glow around the artwork: `primary`, bright enough to show on black.
    public var glow: PaletteColor {
        if isMonochrome { return PaletteColor(0.86, 0.86, 0.9) }
        let (h, s, v) = primary.hsv
        return PaletteColor(h: h, s: min(1, s * 1.1 + 0.05), v: max(v, 0.88))
    }

    /// Progress fill, equalizer bars: vivid but not oversaturated, readable on black (luminance ≥ ~0.3).
    public var accent: PaletteColor {
        if isMonochrome { return PaletteColor(0.92, 0.92, 0.95) }
        let (h, s, v) = primary.hsv
        var color = PaletteColor(h: h, s: min(max(s, 0.38), 0.78), v: max(v, 0.94))
        // Deep blues and purples stay dark at full value: lift them toward white.
        var lift = 0.0
        while color.luminance < 0.3, lift < 0.6 {
            lift += 0.08
            color = PaletteColor(color.r + (1 - color.r) * 0.08, color.g + (1 - color.g) * 0.08, color.b + (1 - color.b) * 0.08)
        }
        return color
    }

    /// Colors for a cover the widget could not load: a stable pair of hues from `seed` (album and artist),
    /// so one album keeps its colors.
    public static func placeholder(seed: String) -> ArtworkPalette {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let h1 = Double(hash % 360) / 360
        let h2 = (h1 + 0.08 + Double((hash >> 16) % 20) / 100).truncatingRemainder(dividingBy: 1)
        let primary = PaletteColor(h: h1, s: 0.62, v: 0.92)
        let secondary = PaletteColor(h: h2, s: 0.7, v: 0.55)
        return ArtworkPalette(primary: primary, secondary: secondary,
                              average: PaletteColor((primary.r + secondary.r) / 2, (primary.g + secondary.g) / 2,
                                                (primary.b + secondary.b) / 2),
                              isMonochrome: false)
    }

    /// The palette of an RGBA image (8 bits per component, premultiplied or not; any small size, 24–64 px
    /// is plenty). Pixels are grouped by hue (12 sectors × 3 brightness bands) so a gradient counts as one
    /// color; greys go into 4 bands of their own.
    public static func extract(rgba: [UInt8], width: Int, height: Int) -> ArtworkPalette {
        struct Bin { var count = 0.0, r = 0.0, g = 0.0, b = 0.0, s = 0.0 }
        var chromatic = [Bin](repeating: Bin(), count: 36)
        var grey = [Bin](repeating: Bin(), count: 4)
        var total = Bin()
        let pixels = min(width * height, rgba.count / 4)
        for i in 0..<pixels {
            let a = Double(rgba[4 * i + 3]) / 255
            guard a > 0.5 else { continue }
            // Un-premultiply (a no-op for opaque pixels).
            let c = PaletteColor(min(1, Double(rgba[4 * i]) / 255 / a), min(1, Double(rgba[4 * i + 1]) / 255 / a),
                             min(1, Double(rgba[4 * i + 2]) / 255 / a))
            let (h, s, v) = c.hsv
            total.count += 1
            total.r += c.r; total.g += c.g; total.b += c.b
            if s >= 0.2, v >= 0.16 {
                let index = min(11, Int(h * 12)) * 3 + min(2, Int(v * 3))
                chromatic[index].count += 1
                chromatic[index].r += c.r; chromatic[index].g += c.g; chromatic[index].b += c.b
                chromatic[index].s += s
            } else {
                let index = min(3, Int(v * 4))
                grey[index].count += 1
                grey[index].r += c.r; grey[index].g += c.g; grey[index].b += c.b
            }
        }
        func mean(_ bin: Bin) -> PaletteColor {
            bin.count > 0 ? PaletteColor(bin.r / bin.count, bin.g / bin.count, bin.b / bin.count) : PaletteColor(0.5, 0.5, 0.55)
        }
        let average = mean(total)
        let colorful = chromatic.reduce(0) { $0 + $1.count }
        guard total.count > 0, colorful / total.count >= 0.06 else {
            // Black and white: the brightest sizeable grey leads.
            let lead = grey.indices.filter { grey[$0].count >= total.count * 0.08 }.max() ?? 3
            let primary = mean(grey[lead])
            return ArtworkPalette(primary: primary, secondary: PaletteColor(primary.r * 0.5, primary.g * 0.5, primary.b * 0.5),
                                  average: average, isMonochrome: true)
        }
        // Score: area × vividness, dark bands discounted.
        func score(_ i: Int) -> Double {
            let bin = chromatic[i]
            guard bin.count > 0 else { return 0 }
            let band = [0.45, 0.85, 1.0][i % 3]
            return bin.count * (0.35 + bin.s / bin.count) * band
        }
        let ranked = chromatic.indices.sorted { score($0) > score($1) }
        let best = ranked[0]
        let primary = mean(chromatic[best])
        let hueOf = { (i: Int) in i / 3 }
        let second = ranked.dropFirst().first { i in
            let d = abs(hueOf(i) - hueOf(best))
            return min(d, 12 - d) >= 2 && score(i) >= score(best) * 0.12
        }
        let secondary: PaletteColor
        if let second {
            secondary = mean(chromatic[second])
        } else {
            let (h, s, v) = primary.hsv
            secondary = PaletteColor(h: h, s: min(1, s + 0.1), v: v * 0.55)
        }
        return ArtworkPalette(primary: primary, secondary: secondary, average: average, isMonochrome: false)
    }
}
