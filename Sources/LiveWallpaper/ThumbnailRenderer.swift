import AppKit
import AVFoundation
import Metal
import WebKit
import simd

/// Renders a single frame of a Metal fragment shader, a video file, or a web wallpaper to an
/// `NSImage` for use as a preview tile. Cached by source so each wallpaper is rendered once.
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

    /// A single static frame from a video file, for a preview tile. Cached by URL+size.
    static func image(forVideoAt url: URL,
                      size: CGSize = CGSize(width: 360, height: 220),
                      at seconds: Double = 1) async -> NSImage? {
        let key = "vid:\(url.path)@\(Int(size.width))x\(Int(size.height))"
        if let cached = cache[key] { return cached }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        do {
            let cg = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let img = NSImage(cgImage: cg, size: size)
            cache[key] = img
            return img
        } catch {
            return nil
        }
    }

    /// A single frame of a web wallpaper, captured by loading it off-screen in a `WKWebView`,
    /// waiting a beat for first paint + a few frames of animation, then snapshotting the view.
    /// Used for both the built-in web wallpapers (which have no `thumbnail.png`) and installed
    /// web packages whose authors didn't ship one.
    static func image(forWebRoot root: URL,
                      entry: String,
                      allowlist: [String],
                      size: CGSize = CGSize(width: 360, height: 220)) async -> NSImage? {
        let key = "web:\(root.path)/\(entry)@\(Int(size.width))x\(Int(size.height))"
        if let cached = cache[key] { return cached }
        let frame = NSRect(origin: .zero, size: NSSize(width: size.width * 2, height: size.height * 2))
        let view = WKWebView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        // Use a tiny per-render config so the WebRenderer's hard-locked scheme/nav policy doesn't
        // interfere with the off-screen load. Same allowlist semantics, just local files.
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(WebSchemeHandler(diskRoot: root), forURLScheme: "lwp")
        let lo = WKWebpagePreferences()
        lo.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = lo
        let capture = WKWebView(frame: frame, configuration: cfg)
        capture.wantsLayer = true
        capture.layer?.backgroundColor = NSColor.black.cgColor
        // The lwp:// scheme resolves to diskRoot/entry. Pin to entry file directly.
        let url = URL(string: "lwp://localhost/\(entry)") ?? root.appendingPathComponent(entry)
        let _ = capture.loadFileURL(url, allowingReadAccessTo: root)
        // Let the page render a few frames of animation before we grab one.
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds)
        guard let bitmap else { return nil }
        capture.cacheDisplay(in: capture.bounds, to: bitmap)
        let image = NSImage(cgImage: bitmap.cgImage!, size: size)
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
