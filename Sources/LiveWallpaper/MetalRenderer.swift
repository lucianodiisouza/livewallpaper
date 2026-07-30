import AppKit
import Metal
import QuartzCore
import simd
import os

/// Mirrors the MSL `Uniforms` struct in BuiltInShaders. Layout must match exactly:
/// float2(0) + float(8) + float(12) + float4(16) = 32 bytes.
private struct MetalUniforms {
    var resolution: SIMD2<Float> = .zero
    var time: Float = 0
    var speed: Float = 1
    var tint: SIMD4<Float> = .init(1, 1, 1, 1)
}

/// Renders a Shadertoy-style MSL **fragment shader** into a `CAMetalLayer`, driven by a
/// `CADisplayLink` synced to the screen (so it rides ProMotion's adaptive refresh). Fragment
/// shaders are sandboxed by construction — they can't reach the filesystem, network, or memory
/// outside the pipeline (see DESIGN.md §7). Compute shaders / buffer writes are intentionally
/// unsupported.
///
/// Pausing the display link is what drops us to ~0% GPU when the Governor says nothing is visible.
@MainActor
final class MetalRenderer: WallpaperRenderer {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "MetalRenderer")

    private let shaderSource: String
    let configSchema: [ConfigParameter]

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?
    private var displayLink: CADisplayLink?

    private var uniforms = MetalUniforms()
    private var startTime = CACurrentMediaTime()

    init(shaderSource: String, configSchema: [ConfigParameter]) {
        self.shaderSource = shaderSource
        self.configSchema = configSchema
        apply(config: .defaults(for: configSchema))
    }

    func start(in layer: CALayer) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("No Metal device available.")
            return
        }
        self.device = device
        self.queue = device.makeCommandQueue()

        // Compile the fragment shader at runtime.
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "v_main")
            desc.fragmentFunction = library.makeFunction(name: "f_main")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            log.error("Shader compile/pipeline failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let scale = (layer.delegate as? NSView)?.window?.backingScaleFactor ?? 2.0
        let ml = CAMetalLayer()
        ml.device = device
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = true
        ml.frame = layer.bounds
        ml.contentsScale = scale
        ml.drawableSize = CGSize(width: layer.bounds.width * scale, height: layer.bounds.height * scale)
        ml.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.addSublayer(ml)
        self.metalLayer = ml

        startTime = CACurrentMediaTime()
        startDisplayLink(from: layer)
        log.notice("Metal wallpaper started (\(Int(ml.drawableSize.width))x\(Int(ml.drawableSize.height)))")
    }

    // MARK: - Display link

    private func startDisplayLink(from layer: CALayer) {
        // A view-backed display link is synced to that view's screen and adapts to ProMotion.
        guard let view = layer.delegate as? NSView else {
            log.error("No host view for display link — Metal wallpaper will not animate.")
            return
        }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        render()
    }

    private func render() {
        guard let metalLayer, let pipeline, let queue,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer()
        else { return }

        uniforms.resolution = SIMD2<Float>(Float(metalLayer.drawableSize.width),
                                           Float(metalLayer.drawableSize.height))
        uniforms.time = Float(CACurrentMediaTime() - startTime)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - WallpaperRenderer

    func pause() { displayLink?.isPaused = true }
    func resume() { displayLink?.isPaused = false }

    /// Ride the requested rate; the display link adapts to the panel (ProMotion) within this range.
    func setFrameRate(_ fps: Int) {
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(max(1, min(fps, 30))), maximum: Float(fps), preferred: Float(fps))
    }

    func apply(config: [String: ConfigValue]) {
        if let speed = config["speed"]?.asDouble { uniforms.speed = Float(speed) }
        if let hex = config["tint"]?.asHex, let rgb = Self.rgb(fromHex: hex) {
            uniforms.tint = SIMD4<Float>(rgb.0, rgb.1, rgb.2, 1)
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        pipeline = nil
        queue = nil
        device = nil
    }

    // MARK: - Helpers

    static func rgb(fromHex hex: String) -> (Float, Float, Float)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Float((v >> 16) & 0xFF) / 255.0,
                Float((v >> 8) & 0xFF) / 255.0,
                Float(v & 0xFF) / 255.0)
    }
}
