import AppKit
import CoreGraphics
import IOKit

/// Headless App-Sandbox spike (`LiveWallpaper --sandbox-probe`). M0 already proved the *desktop
/// window* survives the sandbox; this proves the **rest of the current feature set** does too — the
/// APIs a Mac App Store review would scrutinize. Run it from the **sandboxed** `.app` binary
/// (`dist/Primo Engine.app/Contents/MacOS/LiveWallpaper --sandbox-probe`) so the kernel has applied
/// the container; running the bare SwiftPM binary is unsandboxed and only a control.
///
/// Exit 0 iff every **required** capability works inside the container. Feature-specific capabilities
/// (foreign-window metadata for the Governor's full-screen signal, desktop-picture read for the solid
/// backdrop) are reported but don't fail the probe — they degrade gracefully if a future OS refuses.
@MainActor
enum SandboxProbe {

    static func run() -> Int32 {
        var requiredFailures = 0
        func line(_ status: String, _ name: String, _ detail: String = "") {
            print("  \(status) \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        func require(_ name: String, _ ok: Bool, _ detail: String = "") {
            line(ok ? "✅" : "❌", name, detail); if !ok { requiredFailures += 1 }
        }
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            line(ok ? "✅" : "⚠️ ", name, detail)
        }

        // 0) Are we actually sandboxed? HOME is redirected into the app container under the sandbox.
        let home = NSHomeDirectory()
        let containerized = home.contains("/Containers/com.livewallpaper.app")
            || ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        line(containerized ? "✅" : "⚠️ ", "sandbox container active",
             containerized ? home : "NOT containerized — run the .app binary, not the SwiftPM build")

        // 1) Device id via IOKit (IOPlatformUUID) — required for premium gating + licensing.
        let deviceID = Device.id
        require("IOKit IOPlatformUUID (Device.id)", !deviceID.isEmpty,
                deviceID.isEmpty ? "empty" : "len \(deviceID.count)")

        // 2) Keychain round-trip — required for the device fallback id, license cache, AI keys.
        require("Keychain read/write/delete", keychainRoundTrips())

        // 3) App Support container is writable — required for the installed library + solid image.
        require("Application Support container writable", appSupportWritable())

        // 4) Foreign-window metadata (CGWindowList) — the B5 full-screen-cover Governor signal.
        //    Window BOUNDS/layer/owner are readable without the screen-recording permission; only
        //    pixel *contents* would need it, which we never read.
        let (winCount, foreignBounds) = windowListMetadata()
        report("CGWindowList foreign-window bounds (B5 signal)", foreignBounds > 0,
               "\(winCount) on-screen windows, \(foreignBounds) foreign w/ bounds")

        // 5) Read the current desktop picture (the solid-backdrop feature captures & restores it).
        let deskURL = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        report("NSWorkspace.desktopImageURL read (solid backdrop)", deskURL != nil,
               deskURL?.lastPathComponent ?? "nil")

        print("\n\(requiredFailures == 0 ? "PASS" : "FAIL"): required capabilities " +
              "\(requiredFailures == 0 ? "all work in the sandbox" : "\(requiredFailures) FAILED")")
        return requiredFailures == 0 ? 0 : 1
    }

    // MARK: - Probes

    private static func keychainRoundTrips() -> Bool {
        let service = "com.livewallpaper.app.sandboxprobe"
        let account = "probe"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data("ok".utf8)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let got = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
            && (item as? Data) == Data("ok".utf8)
        SecItemDelete(base as CFDictionary)
        return got
    }

    private static func appSupportWritable() -> Bool {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return false }
        let probe = base.appendingPathComponent("LiveWallpaper/.sandbox-probe", isDirectory: false)
        try? fm.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Data("ok".utf8).write(to: probe)
            let ok = (try? Data(contentsOf: probe)) == Data("ok".utf8)
            try? fm.removeItem(at: probe)
            return ok
        } catch { return false }
    }

    private static func windowListMetadata() -> (total: Int, foreignWithBounds: Int) {
        let mine = ProcessInfo.processInfo.processIdentifier
        let infos = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var foreign = 0
        for w in infos {
            if (w[kCGWindowOwnerPID as String] as? Int32) == mine { continue }
            if let b = w[kCGWindowBounds as String] as? [String: Any],
               CGRect(dictionaryRepresentation: b as CFDictionary) != nil { foreign += 1 }
        }
        return (infos.count, foreign)
    }
}
