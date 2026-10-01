// Pixel art: edit the rows directly; every row of a `.layer` is 20 cells wide.
// Letters are palette roles: . clear, k ink, d shade, o body, h light, w white, a accent
// (and the shared prop neutrals: c light grey, n mid grey, m dark grey, b water blue).

extension MascotRig {
    /// Kimi — a black squircle (the app tile) with the bold white `K` standing on its head and the bright-blue
    /// dot perched at the K's arm, as in the logo; white eyes, a grey rim so it reads on the black island.
    /// The dot bounces while it works and falls off when it fails.
    static let kimi = MascotRig(
        palette: MascotPalette(ink: 0x000000, shade: 0x3A3C46, body: 0x141419,
                               light: 0x6A6D7C, white: 0xFFFFFF, accent: 0x1783FF),
        waistRow: 15,
        body: .layer(top: 4, """
            .......ww..ww.......
            .......ww.ww........
            .......wwww.........
            .......ww.ww........
            .......ww..ww.......
            .....hhhhhhhhhh.....
            ....hoooooooooood...
            ...hoooooooooooood..
            ...hoooooooooooood..
            ...hoooooooooooood..
            ...hoooooooooooood..
            ...hoooooooooooood..
            ....hoooooooooood...
            .....hhdddddddd.....
            """),
        legs: [
            .stand: .layer(top: 18, """
                ......dd....dd......
                ......dd....dd......
                """),
            .stepA: .layer(top: 18, """
                ......dd....dd......
                ............dd......
                """),
            .stepB: .layer(top: 18, """
                ......dd....dd......
                ......dd............
                """),
            .tuck: .layer(top: 18, """
                ......dd....dd......
                """),
            .sit: .layer(top: 18, """
                .....dd......dd.....
                ....dd........dd....
                """),
        ],
        faceOrigin: MascotRig.Point(x: 5, y: 11),
        faces: [
            .open: PixelArt("""
                ..........
                .w......w.
                .w......w.
                """),
            .blink: PixelArt("""
                ..........
                ..........
                ww......ww
                """),
            .happy: PixelArt("""
                ..........
                .w......w.
                w.w....w.w
                """),
            .wince: PixelArt("""
                w........w
                .ww....ww.
                w........w
                """),
            .sad: PixelArt("""
                w.w....w.w
                .w......w.
                w.w....w.w
                """),
            .up: PixelArt("""
                .w......w.
                .w......w.
                ..........
                """),
        ],
        dot: MascotRig.Point(x: 13, y: 2),
        errorTint: [.accent: .propMid],
        tearOrigin: MascotRig.Point(x: 6, y: 16),
        bubbleOrigin: MascotRig.Point(x: 0, y: 1),
        thoughtOrigin: MascotRig.Point(x: 1, y: 6),
        sparkleSpots: [.init(x: 1, y: 14), .init(x: 18, y: 13), .init(x: 17, y: 6), .init(x: 3, y: 4)]
    )
}
