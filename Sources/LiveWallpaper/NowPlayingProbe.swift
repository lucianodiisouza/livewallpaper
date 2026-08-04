import AppKit
import Foundation

/// `LiveWallpaper --nowplaying-probe` — run the real `NowPlayingMonitor` against the live music apps
/// for a few seconds and print each payload it would push to a now-playing wallpaper. Artwork is
/// truncated to its byte length so the output stays readable. Mirrors `--sandbox-probe`: a headless,
/// no-GUI way to confirm the Music/Spotify → JSON path works on this Mac (macOS 26 gated MediaRemote,
/// so this AppleScript path is the one that has to hold up).
///
/// First run will trigger the system "control Music/Spotify" (Automation) consent prompt — approve it
/// once and the probe (and the app) can read now-playing thereafter.
@MainActor
enum NowPlayingProbe {
    static func run(seconds: Double = 5) -> Int32 {
        print("▶ now-playing probe: listening for \(Int(seconds))s (start/skip a track to see updates)…")
        let monitor = NowPlayingMonitor()
        var ticks = 0
        monitor.onUpdate = { json in
            ticks += 1
            print("  [\(ticks)] \(summarize(json))")
        }
        monitor.start()

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        monitor.stop()

        if ticks == 0 {
            print("✗ no updates — is Music or Spotify actually playing? (probe saw nothing)")
            return 1
        }
        print("✅ \(ticks) update(s) received.")
        return 0
    }

    /// Collapse the artwork data URI (tens of KB of base64) into `artwork=<n>B` so a tick prints on
    /// one line, leaving the metadata legible.
    private static func summarize(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return json }
        if let art = obj["artwork"] as? String {
            let bytes = art.split(separator: ",").last.map { $0.count * 3 / 4 } ?? art.count
            obj["artwork"] = "<\(bytes)B>"
        }
        let parts = ["source", "title", "artist", "album", "isPlaying", "position", "duration", "artwork"]
            .compactMap { k -> String? in obj[k].map { "\(k)=\($0)" } }
        return parts.joined(separator: "  ")
    }
}
