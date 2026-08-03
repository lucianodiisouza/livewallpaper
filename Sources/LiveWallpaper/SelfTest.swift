import AppKit

/// Headless exercise of the M2 package pipeline (export → import → verify → load) plus the security
/// gates. Run with `LiveWallpaper --selftest`; exits 0 on success, 1 on failure. Not part of the
/// normal app path — this is a fast, GUI-free confidence check for the format code.
@MainActor
enum SelfTest {

    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool) {
            print((cond ? "  ✅ " : "  ❌ ") + name); cond ? (passed += 1) : (failed += 1)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let library = Library()

        // 1) Export a sample package.
        let exported = tmp.appendingPathComponent("Plasma.livewallpaper")
        let config: [Manifest.ConfigEntry] = [
            .init(key: "speed", type: "float", label: "Speed", min: 0.1, max: 3, options: nil, defaultValue: .double(1)),
            .init(key: "tint", type: "color", label: "Tint", min: nil, max: nil, options: nil, defaultValue: .string("#FFAA33")),
        ]
        do {
            try library.exportShader(id: "selftest.plasma", title: "Plasma (selftest)",
                                     source: BuiltInShaders.plasma, config: config, to: exported)
            check("export writes a .livewallpaper", FileManager.default.fileExists(atPath: exported.path))
        } catch { check("export writes a .livewallpaper — \(error)", false) }

        // 2) The exported bytes are a readable ZIP with the expected entries.
        if let data = try? Data(contentsOf: exported), let files = try? ZipArchive.extract(data) {
            check("archive contains manifest.json", files["manifest.json"] != nil)
            check("archive contains content/shader.metal", files["content/shader.metal"] != nil)
        } else { check("exported archive is readable", false) }

        // 3) Install it and verify (checksum + shader gate run inside).
        do {
            let pkg = try library.install(fromZipAt: exported)
            check("install returns the package", pkg.manifest.id == "selftest.plasma")
            check("manifest type is metal", pkg.manifest.type == .metal)
            check("config schema decoded (speed+tint)", pkg.manifest.configSchema().count == 2)
            check("appears in installedPackages()", library.installedPackages().contains { $0.manifest.id == "selftest.plasma" })
            _ = try pkg.makeRenderer()
            check("makeRenderer() builds a renderer", true)
        } catch { check("install + load — \(error)", false) }

        // 3b) Export an installed package back out (the peer-to-peer share path) → re-zips into a
        // readable .livewallpaper carrying the manifest + content.
        do {
            let shared = tmp.appendingPathComponent("Plasma-shared.livewallpaper")
            try library.exportPackage(id: "selftest.plasma", to: shared)
            let files = (try? Data(contentsOf: shared)).flatMap { try? ZipArchive.extract($0) } ?? [:]
            check("exportPackage re-zips manifest.json", files["manifest.json"] != nil)
            check("exportPackage keeps content/", files.keys.contains { $0.hasPrefix("content/") })
        } catch { check("exportPackage round-trip — \(error)", false) }

        // 4) Tamper detection: wrong checksum must be rejected.
        let badManifest = """
        {"schemaVersion":1,"id":"tampered","version":"1.0.0","title":"Bad","type":"metal",
         "entry":"content/shader.metal","checksum":"sha256-deadbeef"}
        """
        let badZip = ZipArchive.archive([
            "manifest.json": Data(badManifest.utf8),
            "content/shader.metal": Data(BuiltInShaders.plasma.utf8),
        ])
        let badURL = tmp.appendingPathComponent("bad.livewallpaper")
        try? badZip.write(to: badURL)
        do { _ = try library.install(fromZipAt: badURL); check("checksum mismatch rejected", false) }
        catch { check("checksum mismatch rejected (\(errShort(error)))", true) }

        // 5) Shader safety gate: compute kernels are rejected.
        do { try ShaderValidator.validate("kernel void evil(device float* p){ p[0]=1; }")
             check("shader validator rejects compute kernel", false) }
        catch { check("shader validator rejects compute kernel", true) }

        // 6) Shader safety gate: a normal fragment shader passes.
        do { try ShaderValidator.validate(BuiltInShaders.plasma)
             check("shader validator accepts a fragment shader", true) }
        catch { check("shader validator accepts a fragment shader — \(error)", false) }

        // 7) Web package: install + load + makeRenderer, and network flags surface.
        let html = "<!doctype html><html><body><script>fetch('https://evil.example/x')</script></body></html>"
        let webContent = ["web/index.html": Data(html.utf8)]
        let webManifest = """
        {"schemaVersion":1,"id":"selftest.web","version":"1.0.0","title":"Web (selftest)",
         "type":"web","entry":"content/web/index.html","minMacOS":"26.0",
         "checksum":"\(WallpaperPackage.checksum(ofContentFiles: webContent))",
         "capabilities":{"network":[],"audio":false}}
        """
        let webZip = ZipArchive.archive([
            "manifest.json": Data(webManifest.utf8),
            "content/web/index.html": Data(html.utf8),
        ])
        let webURL = tmp.appendingPathComponent("web.livewallpaper")
        try? webZip.write(to: webURL)
        do {
            let pkg = try library.install(fromZipAt: webURL)
            check("web package installs & verifies", pkg.manifest.type == .web)
            _ = try pkg.makeRenderer()
            check("web makeRenderer() builds a WebRenderer", true)
        } catch { check("web install/load — \(error)", false) }
        check("web validator flags fetch()", !WebValidator.warnings(source: html, filename: "index.html").isEmpty)

        // 8) Network rule JSON: empty allowlist blocks all; an allowlist adds an exception.
        check("empty allowlist → block rule only", WebRenderer.ruleJSON(allowlist: []).contains("\"block\"")
              && !WebRenderer.ruleJSON(allowlist: []).contains("if-domain"))
        check("allowlist adds a host exception", WebRenderer.ruleJSON(allowlist: ["cdn.example"]).contains("*cdn.example"))

        // 9) Config value persistence round-trips through Codable.
        let sample: [String: ConfigValue] = ["speed": .float(1.5), "on": .bool(true), "tint": .color("#112233")]
        if let data = try? JSONEncoder().encode(sample),
           let back = try? JSONDecoder().decode([String: ConfigValue].self, from: data) {
            check("config values persist (Codable round-trip)", back == sample)
        } else { check("config values persist (Codable round-trip)", false) }

        // 10) Battery behavior parses from its raw value.
        check("battery behavior enum round-trips", BatteryBehavior(rawValue: "pause") == .pause)

        // 11) Update version comparison (pure, no network).
        check("update: newer minor is newer", UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        check("update: v-prefix + equal is not newer", !UpdateChecker.isNewer("v0.1.0", than: "0.1.0"))
        check("update: numeric (not lexical) compare", UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
        check("update: older is not newer", !UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        check("update: tag normalizes (v + pre-release)", UpdateChecker.normalized("v1.2.3-beta.1") == "1.2.3")

        // 12) Premium gating: a premium wallpaper is blocked (paywall opens) when locked, applied
        // when unlocked. Snapshot + restore the entitlement so the check leaves no side effect.
        let wasPremium = Entitlement.shared.isPremium
        let em = AppModel()
        let premiumEntry = AppModel.Entry(id: "selftest.premium", title: "Premium", kind: "metal",
                                          isBuiltIn: true, isPremium: true)
        Entitlement.shared.lock()
        check("premium wallpaper is gated when locked", em.attemptApply(premiumEntry) == false && em.paywall != nil)
        em.paywall = nil
        Entitlement.shared.unlockForNow()
        check("premium wallpaper applies when unlocked", em.attemptApply(premiumEntry) == true && em.paywall == nil)
        if wasPremium { Entitlement.shared.unlockForNow() } else { Entitlement.shared.lock() }

        // 13) AI generation: the model reply parser strips code fences and passes raw text through.
        let fenced = ShaderGenerator.extractMetal(from: "Here you go:\n```metal\nfragment float4 f_main() {}\n```\ndone")
        check("AI: extracts fenced shader", fenced == "fragment float4 f_main() {}")
        check("AI: raw text passthrough", ShaderGenerator.extractMetal(from: "  fragment X  ") == "fragment X")

        // 14) AI web packaging: exportWeb → readable web bundle that installs as a `web` package.
        do {
            let webShare = tmp.appendingPathComponent("ai-web.livewallpaper")
            try library.exportWeb(id: "selftest.aiweb", title: "AI Web",
                                  html: "<!doctype html><html><body><canvas></canvas></body></html>", to: webShare)
            let files = (try? Data(contentsOf: webShare)).flatMap { try? ZipArchive.extract($0) } ?? [:]
            check("exportWeb has content/web/index.html", files["content/web/index.html"] != nil)
            let pkg = try library.install(fromZipAt: webShare)
            check("exportWeb installs as a web package", pkg.manifest.type == .web)
        } catch { check("exportWeb round-trip — \(error)", false) }

        // 15) Device-bound license: Ed25519 verify, tamper rejection, device-binding. Fixed vector
        // signed by the scaffold key (see Licensing.publicKeyB64).
        let licPayload = "eyJkZXZpY2VfaWQiOiJzZWxmdGVzdC1kZXZpY2UiLCJleHAiOjQxMDI0NDQ4MDAsImlhdCI6MTczNTY4OTYwMCwicHJlbWl1bSI6dHJ1ZSwidiI6MX0"
        let licSig = "ZiBfK5kMJfklTOORqeDRsk7DsQj_DeT9CocxZTtR9Vt_seFiYugWw-2Ct8iQjgzYY-NVrbacqKUk45PGbjspAg"
        let licToken = licPayload + "." + licSig
        if let c = Licensing.verify(licToken) {
            check("license: valid signature + premium claim", c.premium && c.deviceId == "selftest-device")
        } else { check("license: valid signature + premium claim", false) }
        check("license: tampered token rejected", Licensing.verify(licPayload + "AA." + licSig) == nil)
        check("license: not bound to this device", Licensing.claimsForThisDevice(licToken) == nil)

        // 16) Onboarding first-pick offer: free built-ins only (no premium, no imported packages).
        let obEntries = [
            AppModel.Entry(id: "b.free", title: "Free", kind: "metal", isBuiltIn: true),
            AppModel.Entry(id: "b.prem", title: "Prem", kind: "metal", isBuiltIn: true, isPremium: true),
            AppModel.Entry(id: "u.imported", title: "Imported", kind: "web", isBuiltIn: false),
        ]
        check("onboarding first-picks are free built-ins only",
              Onboarding.firstPicks(from: obEntries).map(\.id) == ["b.free"])

        // 17) Premium catalog delivery: tier decodes (default free), and the device-bound bundle
        // request targets the backend `/catalog/bundle` with the expected key. Free items build no
        // premium request (they download from their public URL instead).
        func decodeItem(_ json: String) -> WorkshopItem? {
            try? JSONDecoder().decode(WorkshopItem.self, from: Data(json.utf8))
        }
        let freeItem = decodeItem(#"{"id":"a","title":"Free","type":"metal","checksum":"sha256-x","bundle_url":"https://r2/pub/a.livewallpaper"}"#)
        let premItem = decodeItem(#"{"id":"b","title":"Prem","type":"metal","checksum":"sha256-y","tier":"premium","bundle_key":"premium/b.livewallpaper"}"#)
        check("catalog: missing tier decodes as free", freeItem?.isPremium == false)
        check("catalog: tier=premium decodes as premium", premItem?.isPremium == true)
        check("catalog: free item builds no premium request",
              freeItem.flatMap { WorkshopClient.premiumBundleRequest(backendBase: "https://api", deviceID: "dev", item: $0) } == nil)
        if let p = premItem,
           let req = WorkshopClient.premiumBundleRequest(backendBase: "https://api/", deviceID: "dev", item: p),
           let body = req.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) {
            check("catalog: premium request hits /catalog/bundle",
                  req.url?.absoluteString == "https://api/catalog/bundle" && req.httpMethod == "POST")
            check("catalog: premium request carries device + bundle_key",
                  body["device_id"] == "dev" && body["bundle_key"] == "premium/b.livewallpaper" && body["item_id"] == "b")
        } else { check("catalog: premium request builds", false) }
        // A premium item with no bundle_key can't be fetched → no request (surfaces as
        // .premiumBackendUnavailable, which the install path routes to the paywall).
        let premNoKey = decodeItem(#"{"id":"c","title":"NoKey","type":"metal","checksum":"sha256-z","tier":"premium"}"#)
        check("catalog: premium item without bundle_key builds no request",
              premNoKey.flatMap { WorkshopClient.premiumBundleRequest(backendBase: "https://api", deviceID: "dev", item: $0) } == nil)

        // 17b) Premium-install failure routing: a backend refusal (402 → .premiumLocked) or a missing
        // backend must re-open the paywall and carry a non-empty reason — this is the guard against the
        // "click Install, nothing happens" regression where the UI thinks it's Premium but the device
        // isn't entitled. Generic transport errors must NOT hijack the paywall.
        check("premium: 402/locked routes to the paywall", WorkshopClient.WorkshopError.premiumLocked.requiresPaywall)
        check("premium: missing backend routes to the paywall", WorkshopClient.WorkshopError.premiumBackendUnavailable.requiresPaywall)
        check("premium: generic HTTP error does not open the paywall", !WorkshopClient.WorkshopError.http(500).requiresPaywall)
        check("premium: bad URL does not open the paywall", !WorkshopClient.WorkshopError.badURL.requiresPaywall)
        check("premium: locked failure has a non-empty reason",
              !(WorkshopClient.WorkshopError.premiumLocked.errorDescription ?? "").isEmpty)

        // 18) Licensing auto-renew decision (pure): renew when missing or within the window; not when
        // comfortably valid.
        check("license: renew when no token", Licensing.shouldRenew(exp: nil, now: 1000, within: 100))
        check("license: renew when near expiry", Licensing.shouldRenew(exp: 1050, now: 1000, within: 100))
        check("license: no renew when far from expiry", !Licensing.shouldRenew(exp: 5000, now: 1000, within: 100))

        // 19) Activate / deactivate requests target the right routes with the device + order.
        if let a = Licensing.activateRequest(base: "https://api", deviceID: "dev", orderCode: "ORDER-1"),
           let ab = a.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) {
            check("license: activate hits /activate with device+order",
                  a.url?.absoluteString == "https://api/activate" && ab["device_id"] == "dev" && ab["order_id"] == "ORDER-1")
        } else { check("license: activate request builds", false) }
        if let d = Licensing.deactivateRequest(base: "https://api", deviceID: "dev"),
           let db = d.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) {
            check("license: deactivate hits /deactivate with device",
                  d.url?.absoluteString == "https://api/deactivate" && db["device_id"] == "dev")
        } else { check("license: deactivate request builds", false) }

        // 20) Schedule resolution (pure daily program): empty → nil; before first → wraps to last;
        // between entries → the earlier one; after last → last.
        let sched = [
            ScheduleEntry(hour: 8, minute: 0, wallpaperID: "morning"),
            ScheduleEntry(hour: 20, minute: 0, wallpaperID: "night"),
        ]
        check("schedule: empty → nil", WallpaperScheduleLogic.activeWallpaperID(entries: [], minutesNow: 600) == nil)
        check("schedule: before first wraps to last (night)",
              WallpaperScheduleLogic.activeWallpaperID(entries: sched, minutesNow: 7 * 60) == "night")
        check("schedule: midday picks morning",
              WallpaperScheduleLogic.activeWallpaperID(entries: sched, minutesNow: 12 * 60) == "morning")
        check("schedule: evening picks night",
              WallpaperScheduleLogic.activeWallpaperID(entries: sched, minutesNow: 22 * 60) == "night")
        check("schedule: unsorted input still resolves",
              WallpaperScheduleLogic.activeWallpaperID(entries: sched.reversed(), minutesNow: 12 * 60) == "morning")

        // 21) Energy estimate: paused ≈ 0; ordering matches the measured profile (video < web < metal
        // at the same fps/resolution); throttling and lower resolution reduce the score.
        let refPx = EnergyModel.referencePixels
        check("energy: paused is zero",
              EnergyModel.estimate(kind: "metal", fps: 60, paused: true, pixels: refPx).level == .paused)
        let metalFull = EnergyModel.estimate(kind: "metal", fps: 60, paused: false, pixels: refPx)
        let webFull = EnergyModel.estimate(kind: "web", fps: 60, paused: false, pixels: refPx)
        let videoFull = EnergyModel.estimate(kind: "video", fps: 60, paused: false, pixels: refPx)
        check("energy: video < web < metal", videoFull.score < webFull.score && webFull.score < metalFull.score)
        check("energy: full-res shader is the priciest tier", metalFull.level == .high)
        check("energy: throttling lowers the score",
              EnergyModel.estimate(kind: "metal", fps: 30, paused: false, pixels: refPx).score < metalFull.score)
        check("energy: lower resolution lowers the score",
              EnergyModel.estimate(kind: "metal", fps: 60, paused: false, pixels: refPx / 4).score < metalFull.score)

        // 22) Full-screen cover signal (pure geometry): all screens covered → true; a gap → false;
        // no screens → false; tolerance absorbs sub-point rounding.
        let scr = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1920, height: 1080)]
        let coverBoth = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1920, height: 1080)]
        check("fullscreen: both screens covered → true", FullscreenCoverage.allScreensCovered(screens: scr, windows: coverBoth))
        check("fullscreen: one screen uncovered → false",
              !FullscreenCoverage.allScreensCovered(screens: scr, windows: [coverBoth[0]]))
        check("fullscreen: no screens → false", !FullscreenCoverage.allScreensCovered(screens: [], windows: coverBoth))
        check("fullscreen: sub-point rounding still counts as covered",
              FullscreenCoverage.allScreensCovered(
                screens: [CGRect(x: 0, y: 0, width: 1920, height: 1080)],
                windows: [CGRect(x: 0.5, y: 0.5, width: 1919, height: 1079)]))

        // Clean up installed selftest packages.
        for pkg in library.installedPackages() where pkg.manifest.id.hasPrefix("selftest.") {
            try? FileManager.default.removeItem(at: pkg.directory)
        }

        print("\n\(failed == 0 ? "PASS" : "FAIL"): \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    private static func errShort(_ e: Error) -> String {
        (e as? LocalizedError)?.errorDescription ?? "\(e)"
    }
}
