import AppKit
import Foundation
import os

/// A snapshot of what the user is listening to, assembled from the scriptable music apps
/// (Music.app + Spotify.app) via Apple Events.
///
/// Why AppleScript and not the system now-playing API? Apple gated the private `MediaRemote`
/// framework in macOS 15.4 (the `mediaremoted` daemon now checks for an entitlement only Apple's
/// own apps carry), so `MRMediaRemoteGetNowPlayingInfo` returns nil for third parties on macOS 26.
/// The only path that (a) yields artwork, (b) works on macOS 26, and (c) is App-Store-shippable is
/// scripting the individual music apps — which is exactly why competitors support "Spotify + Apple
/// Music" specifically rather than "any audio". Music hands back the artwork as raw bytes; Spotify
/// hands back a URL that we fetch on the native side (the WKWebView wallpaper is offline and can't).
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var position: Double        // seconds
    var duration: Double        // seconds
    var source: String          // "music" | "spotify"

    /// Stable identity of the track — lets us skip re-encoding/fetching artwork (which is large and,
    /// for Spotify, a network hit) when only the playback position advanced.
    var trackKey: String { "\(source)|\(title)|\(artist)|\(album)" }
}

/// Polls the scriptable music apps on a timer and pushes a JSON now-playing payload to a sink
/// (a now-playing-aware web wallpaper). Artwork is only (re)resolved when the track changes.
///
/// Everything here is `@MainActor`: `NSAppleScript` must run on the main thread, and the metadata
/// scripts are cheap (sub-millisecond). The one thing that can be slow — fetching Spotify artwork
/// over the network — is done off the main actor and folded back in on the next tick.
@MainActor
final class NowPlayingMonitor {

    private let log = Logger(subsystem: "com.livewallpaper.app", category: "NowPlaying")

    /// Called on every poll with a ready-to-eval JSON object literal. Artwork (`artwork` key) is
    /// present only on the first tick of a new track; position-only ticks omit it so we're not
    /// shipping ~30 KB every second.
    var onUpdate: ((String) -> Void)?

    private var timer: Timer?
    private var lastInfo: NowPlayingInfo?
    /// The track whose artwork we've already sent, and the cached data URI for it.
    private var artworkKey: String?
    private var artworkDataURI: String?
    /// Spotify artwork is fetched async; guard against firing the same fetch repeatedly.
    private var pendingArtworkFetch: String?

    /// Where Music writes artwork bytes for us to read back. Inside the app container's tmp, which
    /// is writable under the sandbox.
    private let artworkScratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lw-nowplaying-artwork")

    func start() {
        guard timer == nil else { return }
        log.notice("NowPlaying monitor started.")
        tick()                                            // fire immediately, don't wait a second
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)             // keep ticking during menu tracking etc.
        timer = t
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate(); timer = nil
        lastInfo = nil; artworkKey = nil; artworkDataURI = nil; pendingArtworkFetch = nil
        log.notice("NowPlaying monitor stopped.")
    }

    // MARK: - Poll

    private func tick() {
        guard let info = readMusic() ?? readSpotify() else {
            // Nothing scriptable is playing — tell the scene to go idle, but only once.
            if lastInfo != nil {
                lastInfo = nil; artworkKey = nil; artworkDataURI = nil
                onUpdate?(#"{"isPlaying":false,"title":"","artist":"","album":"","position":0,"duration":0}"#)
            }
            return
        }
        lastInfo = info

        // Resolve artwork only when the track changes.
        var artwork: String? = nil
        if info.trackKey != artworkKey {
            switch info.source {
            case "music":
                if let uri = readMusicArtwork() { artworkDataURI = uri; artworkKey = info.trackKey }
            case "spotify":
                fetchSpotifyArtwork(for: info)             // async → lands on a later tick
            default: break
            }
        }
        // Emit the freshly-resolved (or already-cached) artwork exactly once per track.
        if info.trackKey == artworkKey, let uri = artworkDataURI {
            artwork = uri
            artworkDataURI = nil                           // sent — subsequent ticks omit it
        }

        onUpdate?(json(for: info, artwork: artwork))
    }

    // MARK: - Metadata (Apple Events)

    private func readMusic() -> NowPlayingInfo? {
        // `application "Music" is running` does NOT launch Music — important, we never want to
        // spring-load a music app just to poll it.
        let src = """
        if application "Music" is running then
          tell application "Music"
            if player state is not stopped then
              set ps to "paused"
              if player state is playing then set ps to "playing"
              set t to current track
              return ps & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position)
            end if
          end tell
        end if
        return "NONE"
        """
        return parse(runScript(src), source: "music")
    }

    private func readSpotify() -> NowPlayingInfo? {
        let src = """
        if application "Spotify" is running then
          tell application "Spotify"
            if player state is not stopped then
              set ps to "paused"
              if player state is playing then set ps to "playing"
              set t to current track
              return ps & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) / 1000) & linefeed & (player position)
            end if
          end tell
        end if
        return "NONE"
        """
        return parse(runScript(src), source: "spotify")
    }

    private func parse(_ raw: String?, source: String) -> NowPlayingInfo? {
        guard let raw, raw != "NONE" else { return nil }
        let f = raw.components(separatedBy: "\n")
        guard f.count >= 6 else { return nil }
        return NowPlayingInfo(
            title: f[1], artist: f[2], album: f[3],
            isPlaying: f[0] == "playing",
            position: Double(f[5]) ?? 0,
            duration: Double(f[4]) ?? 0,
            source: source)
    }

    // MARK: - Artwork

    /// Music exposes the cover as raw bytes. AppleScript can't return binary cleanly, so we have it
    /// write the bytes to a scratch file (proven to work: a real 360×360 JPEG) and read them back.
    private func readMusicArtwork() -> String? {
        let path = artworkScratch.path
        let src = """
        if application "Music" is running then
          tell application "Music"
            if player state is not stopped then
              try
                set d to (get raw data of artwork 1 of current track)
                set f to (POSIX file "\(path)")
                set fh to open for access f with write permission
                set eof fh to 0
                write d to fh starting at eof
                close access fh
                return "OK"
              on error
                try
                  close access (POSIX file "\(path)")
                end try
              end try
            end if
          end tell
        end if
        return "NONE"
        """
        guard runScript(src) == "OK",
              let data = try? Data(contentsOf: artworkScratch), !data.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: artworkScratch)
        return dataURI(from: data)
    }

    /// Spotify only exposes an artwork *URL*. The wallpaper WKWebView is network-caged, so we fetch
    /// here (the app has `network.client`) and hand the scene a self-contained data URI.
    private func fetchSpotifyArtwork(for info: NowPlayingInfo) {
        guard pendingArtworkFetch != info.trackKey else { return }
        let src = """
        if application "Spotify" is running then
          tell application "Spotify" to return artwork url of current track
        end if
        return ""
        """
        guard let urlString = runScript(src), let url = URL(string: urlString),
              url.scheme?.hasPrefix("http") == true else { return }
        pendingArtworkFetch = info.trackKey
        let key = info.trackKey
        Task { [weak self] in
            let uri: String? = await {
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
                return await MainActor.run { self?.dataURI(from: data) }
            }()
            await MainActor.run {
                guard let self else { return }
                self.pendingArtworkFetch = nil
                // Only accept if the user is still on this track.
                guard self.lastInfo?.trackKey == key, let uri else { return }
                self.artworkDataURI = uri
                self.artworkKey = key                      // next tick emits it
            }
        }
    }

    /// Sniff JPEG/PNG magic and wrap the bytes as a `data:` URI.
    private func dataURI(from data: Data) -> String {
        let mime: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { mime = "image/png" }
        else if data.starts(with: [0xFF, 0xD8, 0xFF]) { mime = "image/jpeg" }
        else { mime = "image/jpeg" }                       // Music's raw data is JPEG in practice
        return "data:\(mime);base64," + data.base64EncodedString()
    }

    // MARK: - JSON

    private func json(for info: NowPlayingInfo, artwork: String?) -> String {
        var obj: [String: Any] = [
            "title": info.title, "artist": info.artist, "album": info.album,
            "isPlaying": info.isPlaying, "position": info.position,
            "duration": info.duration, "source": info.source,
        ]
        if let artwork { obj["artwork"] = artwork }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - AppleScript runner

    private func runScript(_ source: String) -> String? {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let out = script.executeAndReturnError(&err)
        if let err {
            // -600 (app not running) and -1728 (no current track) are expected/benign; log the rest.
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            if code != -600 && code != -1728 {
                log.debug("AppleScript error \(code): \(String(describing: err[NSAppleScript.errorMessage]), privacy: .public)")
            }
            return nil
        }
        return out.stringValue
    }
}

/// A renderer that can receive now-playing updates. Only web wallpapers that declare the
/// `nowPlaying` capability opt in — consistent with the "capabilities are enforced, never trusted"
/// rule: we don't hand the user's listening data + album art to arbitrary web content.
@MainActor
protocol NowPlayingSink: AnyObject {
    var acceptsNowPlaying: Bool { get }
    func updateNowPlaying(json: String)
}
