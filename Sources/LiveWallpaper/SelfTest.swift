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
