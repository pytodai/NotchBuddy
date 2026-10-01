import Foundation

/// Palette roles of mascot pixel maps. Art strings spell each cell with one letter:
/// `.` clear, `k` ink, `d` shade, `o` body, `h` light, `w` white, `a` accent — the character's own six colours —
/// and the shared neutrals: `c` light grey, `n` mid grey, `m` dark grey, `b` water blue.
enum PixelRole: UInt8, CaseIterable {
    case clear = 0, ink, shade, body, light, white, accent, propLight, propMid, propDark, water

    init?(symbol: Character) {
        switch symbol {
        case ".": self = .clear
        case "k": self = .ink
        case "d": self = .shade
        case "o": self = .body
        case "h": self = .light
        case "w": self = .white
        case "a": self = .accent
        case "c": self = .propLight
        case "n": self = .propMid
        case "m": self = .propDark
        case "b": self = .water
        default: return nil
        }
    }
}

/// A character's six colours (0xRRGGBB), one per character `PixelRole`, plus shared neutrals that are the same for
/// everyone: the greys a character fades to when it fails, and the blue of rain and tears.
struct MascotPalette {
    /// Indexed by `PixelRole.rawValue`; index 0 (clear) is unused.
    let rgb: [UInt32]

    /// Light, mid and dark grey (error tints), water blue (rain and tears).
    static let props: [UInt32] = [0xD9DCE6, 0x8D93A6, 0x4A4F60, 0x62C3FF]

    init(ink: UInt32, shade: UInt32, body: UInt32, light: UInt32, white: UInt32, accent: UInt32) {
        rgb = [0, ink, shade, body, light, white, accent] + MascotPalette.props
    }
}

/// A small bitmap of palette roles. Mascot frames are 20×20 canvases composed from layers
/// (body, arms, legs, face patch, effects), so every transform here is exact and pixel-aligned.
struct PixelArt: Hashable {
    static let canvasSize = 20

    let width: Int
    let height: Int
    /// Row-major `PixelRole` raw values; 0 is transparent.
    private(set) var cells: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        cells = Array(repeating: 0, count: width * height)
    }

    /// Parses rows of role letters. Blank lines and surrounding whitespace are ignored; short rows
    /// are padded with clear cells.
    init(_ text: String) {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        width = rows.map(\.count).max() ?? 0
        height = rows.count
        cells = Array(repeating: 0, count: width * height)
        for (y, row) in rows.enumerated() {
            for (x, symbol) in row.enumerated() {
                guard let role = PixelRole(symbol: symbol) else {
                    preconditionFailure("PixelArt: unknown pixel '\(symbol)' in row \"\(row)\"")
                }
                cells[y * width + x] = role.rawValue
            }
        }
    }

    /// An empty 20×20 canvas.
    static var canvas: PixelArt { PixelArt(width: canvasSize, height: canvasSize) }

    /// A 20×20 canvas holding `text` (rows exactly 20 cells wide) with its first row at canvas row `top`.
    static func layer(top: Int, _ text: String) -> PixelArt {
        let rows = PixelArt(text)
        precondition(rows.width == canvasSize && top >= 0 && top + rows.height <= canvasSize,
                     "PixelArt.layer: rows must be \(canvasSize) wide and fit the canvas")
        return canvas.overlaying(rows, x: 0, y: top)
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { x >= 0 && x < width && y >= 0 && y < height ? cells[y * width + x] : 0 }
        set { if x >= 0 && x < width && y >= 0 && y < height { cells[y * width + x] = newValue } }
    }

    /// `art` drawn on top at (`x`, `y`): its opaque cells replace these ones.
    func overlaying(_ art: PixelArt, x: Int = 0, y: Int = 0) -> PixelArt {
        var out = self
        for row in 0..<art.height {
            for column in 0..<art.width {
                let value = art.cells[row * art.width + column]
                if value != 0 { out[x + column, y + row] = value }
            }
        }
        return out
    }

    /// `art` drawn underneath: it shows only through clear cells.
    func underlaying(_ art: PixelArt, x: Int = 0, y: Int = 0) -> PixelArt {
        var out = self
        for row in 0..<art.height {
            for column in 0..<art.width {
                let value = art.cells[row * art.width + column]
                if value != 0 && out[x + column, y + row] == 0 { out[x + column, y + row] = value }
            }
        }
        return out
    }

    /// Moved by whole cells; whatever leaves the bitmap is dropped.
    func shifted(dx: Int, dy: Int) -> PixelArt {
        guard dx != 0 || dy != 0 else { return self }
        return PixelArt(width: width, height: height).overlaying(self, x: dx, y: dy)
    }

    /// `count` rows removed at `row`; everything above slides down (a squash that keeps the feet planted).
    func squashed(atRow row: Int, by count: Int = 1) -> PixelArt {
        var rows = self.rows
        for _ in 0..<max(0, count) {
            rows.remove(at: row)
            rows.insert(Array(repeating: 0, count: width), at: 0)
        }
        return PixelArt(width: width, rows: rows)
    }

    /// Cells recoloured role by role; roles missing from `map` keep their colour (error states grey out).
    func recolored(_ map: [PixelRole: PixelRole]) -> PixelArt {
        guard !map.isEmpty else { return self }
        var table = Array(0...UInt8(PixelRole.allCases.count - 1))
        for (from, to) in map { table[Int(from.rawValue)] = to.rawValue }
        var out = self
        out.cells = cells.map { table[Int($0)] }
        return out
    }

    private var rows: [[UInt8]] {
        (0..<height).map { Array(cells[($0 * width)..<(($0 + 1) * width)]) }
    }

    private init(width: Int, rows: [[UInt8]]) {
        self.width = width
        height = rows.count
        cells = rows.flatMap { $0 }
    }
}
