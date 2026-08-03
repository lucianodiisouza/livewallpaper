import Foundation
import IOKit
import Security

/// A stable per-machine identifier sent to the backend for Premium gating and (later) device-bound
/// licensing. Prefers the hardware `IOPlatformUUID`; falls back to a Keychain-persisted UUID so the
/// id stays stable across launches even if the hardware id is unavailable.
enum Device {
    static let id: String = hardwareUUID() ?? persistedFallback()

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let cf = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        guard let uuid = cf?.takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return uuid
    }

    // MARK: - Keychain-persisted fallback

    private static let service = "com.livewallpaper.app.device"
    private static let account = "device-id"

    private static func persistedFallback() -> String {
        if let existing = keychainGet() { return existing }
        let fresh = UUID().uuidString
        keychainSet(fresh)
        return fresh
    }

    private static func keychainGet() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainSet(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
