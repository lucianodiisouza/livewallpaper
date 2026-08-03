import Foundation
import CryptoKit
import Security

/// Device-bound licensing. The backend issues an **Ed25519-signed** token binding this device's id to
/// its premium entitlement; the client verifies it **offline** with the embedded public key and checks
/// the device id matches this machine — so a license copied to another Mac won't verify. The private
/// signing key lives only on the backend (see the worker). Real purchase (StoreKit) will flip the
/// server-side premium flag later; the signature + device-binding here are the enforcement.
enum Licensing {

    /// Embedded Ed25519 public key (raw 32 bytes, base64). The matching private key is a backend secret.
    private static let publicKeyB64 = "WRdb+9fB4Ge4pdeIus+07RppuXBTP0lzzgx8gDhg750="

    struct Claims { let deviceId: String; let premium: Bool; let exp: Int }

    private static var publicKey: Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: publicKeyB64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// Verify signature + expiry (not device binding). Returns claims iff the token is authentic.
    static func verify(_ token: String) -> Claims? {
        let parts = token.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let key = publicKey,
              let sig = Data(base64URL: String(parts[1])) else { return nil }
        let payloadB64 = String(parts[0])
        guard key.isValidSignature(sig, for: Data(payloadB64.utf8)),
              let payload = Data(base64URL: payloadB64),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let deviceId = obj["device_id"] as? String,
              let exp = obj["exp"] as? Int, exp > Int(Date().timeIntervalSince1970) else { return nil }
        return Claims(deviceId: deviceId, premium: (obj["premium"] as? Bool) ?? false, exp: exp)
    }

    /// Verify + require the token to be bound to THIS machine.
    static func claimsForThisDevice(_ token: String) -> Claims? {
        guard let c = verify(token), c.deviceId == Device.id else { return nil }
        return c
    }

    /// The premium entitlement from the cached license (valid + this device), if any.
    static func cachedClaims() -> Claims? { cachedToken().flatMap(claimsForThisDevice) }

    /// Fetch a fresh license from the backend and cache it if valid for this device.
    @discardableResult
    static func fetch() async -> Claims? {
        let raw = AIConfig.baseURL(for: .backend)
        let base = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard !base.isEmpty, let url = URL(string: base + "/license") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": Device.id])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["license"] as? String,
              let claims = claimsForThisDevice(token) else { return nil }
        cache(token)
        return claims
    }

    // MARK: - Cache (Keychain)

    private static let service = "com.livewallpaper.app.license"
    private static let account = "license-token"

    static func clearCache() { keychainSet(nil) }
    private static func cache(_ token: String) { keychainSet(token) }

    private static func cachedToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainSet(_ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

extension Data {
    /// Decode a base64url (unpadded) string.
    init?(base64URL s: String) {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        self.init(base64Encoded: str)
    }
}
