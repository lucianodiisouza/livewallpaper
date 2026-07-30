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

        // Clean up the installed selftest package.
        for pkg in library.installedPackages() where pkg.manifest.id == "selftest.plasma" {
            try? FileManager.default.removeItem(at: pkg.directory)
        }

        print("\n\(failed == 0 ? "PASS" : "FAIL"): \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    private static func errShort(_ e: Error) -> String {
        (e as? LocalizedError)?.errorDescription ?? "\(e)"
    }
}
