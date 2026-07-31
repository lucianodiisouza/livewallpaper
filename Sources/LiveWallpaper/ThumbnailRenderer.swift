import AppKit
import Metal
import simd

/// Renders a single frame of a Metal fragment shader to an `NSImage` for use as a preview tile.
/// Cached by source so each wallpaper is rendered once. Metal only; video/web fall back to a
/// styled placeholder in the UI.
@MainActor
enum ThumbnailRenderer {

    private struct U {
        var resolution = SIMD2<Float>(0, 0)
        var time: Float = 0
        var speed: Float = 1
        var tint = SIMD4<Float>(1, 1, 1, 1)
    }

    private static var cache: [String: NSImage] = [:]
    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()

    static func image(forShader source: String,
                      size: CGSize = CGSize(width: 360, height: 220),
                      time: Float = 6) -> NSImage? {
        let key = "\(source.hashValue)@\(Int(size.width))x\(Int(size.height))"
        if let cached = cache[key] { return cached }
        guard let image = render(source: source, size: size, time: time) else { return nil }
        cache[key] = image
        return image
    }

    private static func render(source: String, size: CGSize, time: Float) -> NSImage? {
        guard let device, let queue,
              let lib = try? device.makeLibrary(source: source, options: nil),
              let vfn = lib.makeFunction(name: "v_main"),
              let ffn = lib.makeFunction(name: "f_main") else { return nil }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }

        let w = Int(size.width), h = Int(size.height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }

        var u = U(resolution: SIMD2(Float(w), Float(h)), time: time, speed: 1, tint: SIMD4(1, 1, 1, 1))
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<U>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        tex.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: rowBytes, space: cs, bitmapInfo: bmp),
              let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}
