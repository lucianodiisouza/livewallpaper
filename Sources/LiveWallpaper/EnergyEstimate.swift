import Foundation

/// A coarse, **relative** energy estimate for the energy panel. This is NOT a live measurement — the
/// app can't read per-process GPU energy cheaply on Apple Silicon. It's a model from what we *do*
/// know (medium, target fps, rendered pixels), ordered to match the measured profile in
/// docs/PERFORMANCE.md (video hardware-decode is cheapest, a full-res fragment shader is priciest,
/// paused ≈ 0). For real CPU/GPU/power numbers, point people at docs/PERFORMANCE_REPRODUCE.md.
struct EnergyEstimate: Equatable {
    enum Level: String { case paused = "Paused", low = "Low", moderate = "Moderate", high = "Higher" }
    let level: Level
    /// 0–100 relative to a full-res fragment shader at the display's refresh rate (the priciest case).
    let score: Int
    let note: String
}

enum EnergyModel {
    /// Reference: the 3440×1440 ultrawide the perf profile was captured on. Score is relative to a
    /// Metal shader filling this many pixels at 60fps.
    static let referencePixels = 3_440 * 1_440

    /// Relative render weight per medium, ordered by the measured profile (video < web ≲ metal).
    private static func weight(forKind kind: String) -> Double {
        switch kind {
        case "video": return 0.35   // HEVC decoded by a dedicated hardware block — light
        case "web":   return 0.70   // a WKWebView; cost depends on the animation
        default:      return 1.0    // metal fragment shader — GPU work scales with pixels & fps
        }
    }

    private static func note(forKind kind: String) -> String {
        switch kind {
        case "video": return "Hardware-decoded video — easy on the CPU."
        case "web":   return "Runs a WKWebView — cost depends on the animation."
        default:      return "GPU fragment shader — scales with resolution and frame rate."
        }
    }

    /// Estimate the live cost of a wallpaper. `paused` ⇒ ~0 regardless of medium (the Governor stops
    /// the render). Otherwise scale the medium weight by the frame rate and the rendered pixel area.
    static func estimate(kind: String, fps: Int, paused: Bool, pixels: Int) -> EnergyEstimate {
        if paused {
            return EnergyEstimate(level: .paused, score: 0, note: "Not rendering right now — about zero cost.")
        }
        let fpsFactor = max(0, Double(fps)) / 60.0
        let pixelFactor = min(max(Double(pixels) / Double(referencePixels), 0), 1.25)
        let raw = weight(forKind: kind) * fpsFactor * pixelFactor
        let score = Int((min(max(raw, 0), 1) * 100).rounded())
        let level: EnergyEstimate.Level = score <= 25 ? .low : (score <= 60 ? .moderate : .high)
        return EnergyEstimate(level: level, score: score, note: note(forKind: kind))
    }
}
