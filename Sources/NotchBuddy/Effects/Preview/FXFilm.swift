import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Renders a live Core Animation layer tree offline, frame by frame, at chosen moments: `CARenderer`
/// composites the tree (emitters, masks, shadows and all running animations) into a Metal texture at
/// `t0 + t`, so a filmstrip shows exactly what the render server would put on screen.
@MainActor
final class FXFilm {
    let size: CGSize
    let scale: CGFloat
    /// Put the scene here (top-left origin, points).
    let root = CALayer()
    /// Time 0 of the film in the layers' time: start effects at `t0 + delay`.
    let t0: CFTimeInterval

    private let top = CALayer()
    private let texture: MTLTexture
    private let queue: MTLCommandQueue
    private let renderer: CARenderer
    private let pixelWidth: Int
    private let pixelHeight: Int

    init?(size: CGSize, scale: CGFloat = 2, background: CGColor = CGColor(gray: 0.035, alpha: 1)) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.size = size
        self.scale = scale
        self.queue = queue
        pixelWidth = Int((size.width * scale).rounded())
        pixelHeight = Int((size.height * scale).rounded())
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixelWidth,
                                                            height: pixelHeight, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = texture
        renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererMetalCommandQueue: queue,
            kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
        t0 = CACurrentMediaTime() + 1
        FX.quietly {
            top.frame = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
            top.backgroundColor = background
            top.isGeometryFlipped = true
            root.anchorPoint = .zero
            root.bounds = CGRect(origin: .zero, size: size)
            root.position = .zero
            root.transform = CATransform3DMakeScale(scale, scale, 1)
            top.addSublayer(root)
        }
        CATransaction.flush()
        renderer.layer = top
        renderer.bounds = top.bounds
        CATransaction.flush()
    }

    /// The color behind the scene (clear: a frame with alpha, to composite over another).
    var background: CGColor? {
        get { top.backgroundColor }
        set { FX.quietly { top.backgroundColor = newValue } }
    }

    /// Renders the tree as it is at `t0 + t`. Call with increasing `t` (emitters simulate forward).
    func frame(at t: Double, prepare: ((Double) -> Void)? = nil) -> CGImage? {
        // Step at 60 fps up to `t`, like the screen would: emitters integrate their birth rate frame by
        // frame (one jump would emit with the rate of its last moment for the whole gap).
        var step = lastTime + 1.0 / 60
        while step < t - 1e-6 {
            render(at: step, prepare: prepare)
            step += 1.0 / 60
        }
        render(at: t, prepare: prepare)
        lastTime = t
        guard let buffer = queue.makeCommandBuffer() else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()
        let rowBytes = pixelWidth * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * pixelHeight)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0)
        // The texture's first row is the bottom of the scene.
        var flipped = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<pixelHeight {
            let src = (pixelHeight - 1 - y) * rowBytes
            flipped.replaceSubrange(y * rowBytes..<(y + 1) * rowBytes, with: bytes[src..<src + rowBytes])
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return flipped.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: space, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }

    private var lastTime: Double = -0.05

    private func render(at t: Double, prepare: ((Double) -> Void)?) {
        if let prepare {
            FX.quietly { prepare(t) }
        }
        Self.setContentsScale(top, scale)
        CATransaction.flush()
        renderer.beginFrame(atTime: t0 + t, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
    }

    private static func setContentsScale(_ layer: CALayer, _ scale: CGFloat) {
        if layer.contentsScale != scale { layer.contentsScale = scale }
        if let emitter = layer as? CAEmitterLayer, emitter.contentsScale != scale { emitter.contentsScale = scale }
        layer.mask.map { setContentsScale($0, scale) }
        for sub in layer.sublayers ?? [] { setContentsScale(sub, scale) }
    }

    /// `image` cropped to `rect` (points).
    func crop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return image.cropping(to: r)
    }
}

/// A stand-in for the island in filmstrips: the black silhouette with its drop shadow (`surface`) and a
/// picture of real content clipped to the silhouette (`content`), placed on the canvas like the live island.
@MainActor
final class FXIslandMock {
    let surface = CALayer()
    let content = CALayer()
    private let shadowLayer = CALayer()
    private let body = CAShapeLayer()
    private let contentMask = CAShapeLayer()
    private(set) var outline: FXOutline

    init(outline: FXOutline, image: CGImage?, contentFrame: CGRect) {
        self.outline = outline
        for l in [surface, content, shadowLayer, body, contentMask] as [CALayer] { l.actions = FXLayer.noActions }
        shadowLayer.shadowColor = FX.black
        shadowLayer.shadowRadius = 22
        shadowLayer.shadowOffset = CGSize(width: 0, height: 10)
        body.fillColor = FX.black
        surface.addSublayer(shadowLayer)
        surface.addSublayer(body)
        content.contents = image
        content.contentsGravity = .resize
        content.frame = contentFrame
        content.mask = contentMask
    }

    func layout(canvas: CGRect) {
        surface.frame = canvas
        shadowLayer.frame = canvas
        body.frame = canvas
        set(outline)
    }

    func set(_ o: FXOutline, contentAlpha: Float = 1, contentOffset: CGFloat = 0) {
        outline = o
        let path = o.isEmpty ? CGMutablePath() : o.closed
        shadowLayer.shadowPath = path
        shadowLayer.shadowOpacity = Float(o.g.shadow)
        body.path = path
        var frame = content.frame
        frame.origin.y = contentBaseY + contentOffset
        content.frame = frame
        contentMask.frame = CGRect(x: -frame.minX, y: -frame.minY, width: max(surface.bounds.width, 1),
                                   height: max(surface.bounds.height, 1))
        contentMask.path = path
        content.opacity = contentAlpha
    }

    private lazy var contentBaseY: CGFloat = content.frame.minY
}
