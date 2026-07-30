import AppKit
import AVFoundation
import os

/// Plays a looping video into the desktop window via `AVPlayerLooper` for gapless playback.
/// Decoding runs on the GPU (VideoToolbox), and pausing the player is what drops us to ~0% GPU
/// when the Governor says nothing is visible.
///
/// If no bundled `loop` video is found (e.g. running via bare `swift run`), it falls back to a
/// cheap animated gradient so there is always something to see and to occlusion-test against.
@MainActor
final class VideoRenderer: WallpaperRenderer {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "VideoRenderer")

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var gradientLayer: CAGradientLayer?
    private weak var hostLayer: CALayer?

    /// An explicit video URL (e.g. a package's entry file); falls back to the bundled demo loop.
    private let explicitURL: URL?
    init(url: URL? = nil) { self.explicitURL = url }

    // Video has no tweakable parameters in M1/M2.
    let configSchema: [ConfigParameter] = []
    func apply(config: [String: ConfigValue]) { /* no-op */ }

    func start(in layer: CALayer) {
        hostLayer = layer

        guard let url = explicitURL ?? Self.loopVideoURL() else {
            log.notice("No bundled loop video found — using animated gradient fallback.")
            startGradientFallback(in: layer)
            return
        }

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        let looper = AVPlayerLooper(player: queue, templateItem: item)

        let pLayer = AVPlayerLayer(player: queue)
        pLayer.frame = layer.bounds
        pLayer.videoGravity = .resizeAspectFill
        pLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.addSublayer(pLayer)

        self.player = queue
        self.looper = looper
        self.playerLayer = pLayer
        queue.play()
        log.notice("Playing loop video: \(url.lastPathComponent, privacy: .public)")
    }

    func pause() {
        player?.pause()
        gradientLayer?.speed = 0
    }

    func resume() {
        player?.play()
        gradientLayer?.speed = 1
    }

    /// Video plays at its own native rate; frame-rate throttling is a no-op here (it becomes
    /// meaningful for the Metal/web renderers). Pausing is the real lever for video.
    func setFrameRate(_ fps: Int) { /* intentional no-op for video */ }

    func stop() {
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        gradientLayer?.removeFromSuperlayer()
        looper = nil
        player = nil
        playerLayer = nil
        gradientLayer = nil
    }

    // MARK: - Fallback

    private func startGradientFallback(in layer: CALayer) {
        let g = CAGradientLayer()
        g.frame = layer.bounds
        g.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        g.colors = [NSColor.systemIndigo.cgColor, NSColor.systemTeal.cgColor, NSColor.systemPink.cgColor]
        g.startPoint = CGPoint(x: 0, y: 0)
        g.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(g)

        let anim = CABasicAnimation(keyPath: "colors")
        anim.toValue = [NSColor.systemPink.cgColor, NSColor.systemIndigo.cgColor, NSColor.systemTeal.cgColor]
        anim.duration = 6
        anim.autoreverses = true
        anim.repeatCount = .infinity
        g.add(anim, forKey: "colorShift")
        gradientLayer = g
    }

    // MARK: - Asset lookup

    private static func loopVideoURL() -> URL? {
        // Bundled with the assembled .app (Contents/Resources/loop.mp4).
        if let url = Bundle.main.url(forResource: "loop", withExtension: "mp4") { return url }
        if let url = Bundle.main.url(forResource: "loop", withExtension: "mov") { return url }
        return nil
    }
}
