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

    struct Claims {
        let deviceId: String
        let premium: Bool
        let exp: Int
        /// Plan of the backing order: `trial` | `monthly` | `annual` | `lifetime` | nil.
        let plan: String?
        /// Which rail minted the order: `trial` | `stripe` | `infinitepay` | `apple` | `admin` | nil.
        let source: String?
        /// When the plan's paid window ends (unix seconds), or nil for perpetual (lifetime).
        let planEnds: Int?

        /// A lifetime buyer may self-serve multiple machines; everyone else is bound to this Mac.
        var isLifetime: Bool { plan == "lifetime" }
        var isTrial: Bool { source == "trial" || plan == "trial" }
        /// Monthly/annual — the only plans that can be canceled (Stripe) or will simply not renew.
        var isSubscription: Bool { plan == "monthly" || plan == "annual" }
    }

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
        return Claims(deviceId: deviceId, premium: (obj["premium"] as? Bool) ?? false, exp: exp,
                      plan: obj["plan"] as? String, source: obj["source"] as? String,
                      planEnds: obj["plan_ends"] as? Int)
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
        let raw = AIConfig.backendURL
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

    // MARK: - Activation / deactivation / auto-renew

    /// The backend base URL (trimmed), or nil if unconfigured.
    static func backendBase() -> String? {
        let raw = AIConfig.backendURL
        let base = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        return base.isEmpty ? nil : base
    }

    enum ActivationError: LocalizedError {
        case backendUnavailable, orderNotFound, capReached(Int), http(Int), unusable, trialUsed, noOrder
        var errorDescription: String? {
            switch self {
            case .backendUnavailable: return "Can't reach the Primo backend. Check your connection and try again."
            case .orderNotFound: return "That license code wasn't found. Check it and try again."
            case let .capReached(cap): return "This license is already active on \(cap) machine(s). To use another Mac, contact support."
            case let .http(code): return "Request failed (HTTP \(code))."
            case .unusable: return "Succeeded but no license came back — try again."
            case .trialUsed: return "This Mac has already used its free trial. Choose a plan to continue."
            case .noOrder: return "No active plan found on this Mac to cancel."
            }
        }
    }

    /// Build the `/activate` POST (pure; testable). Ties this device to an order (license code).
    static func activateRequest(base: String, deviceID: String, orderCode: String) -> URLRequest? {
        guard let url = URL(string: base + "/activate") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": deviceID, "order_id": orderCode])
        return req
    }

    /// Build the `/deactivate` POST (pure; testable). Frees this device's slot on its order.
    static func deactivateRequest(base: String, deviceID: String) -> URLRequest? {
        guard let url = URL(string: base + "/deactivate") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": deviceID])
        return req
    }

    /// Activate this device against a license code, then fetch + cache the signed license. Throws a
    /// friendly `ActivationError` on cap/unknown-order/etc.
    @discardableResult
    static func activate(orderCode: String) async throws -> Claims {
        guard let base = backendBase(),
              let req = activateRequest(base: base, deviceID: Device.id, orderCode: orderCode)
        else { throw ActivationError.backendUnavailable }

        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 404: throw ActivationError.orderNotFound
        case 409: throw ActivationError.capReached(DEFAULT_DEVICE_CAP)
        default: throw ActivationError.http(code)
        }
        cacheOrderCode(orderCode) // remember it so /cancel can reference this machine's order
        guard let claims = await fetch() else { throw ActivationError.unusable }
        return claims
    }

    /// Start the one-time, no-card free trial for THIS machine, then fetch the signed license. The
    /// backend enforces one trial per machine, ever — a repeat returns `trialUsed`.
    @discardableResult
    static func startTrial() async throws -> Claims {
        guard let base = backendBase(), let url = URL(string: base + "/trial") else {
            throw ActivationError.backendUnavailable
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": Device.id])

        let (_, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 409: throw ActivationError.trialUsed
        case let code: throw ActivationError.http(code)
        }
        guard let claims = await fetch() else { throw ActivationError.unusable }
        return claims
    }

    /// Cancel the current plan and send exit feedback. For a Stripe subscription the backend cancels
    /// at period end (access continues until then); for other plans it records feedback and the plan
    /// simply won't renew. Needs the order code cached from activation.
    static func cancel(reason: String, feedback: String) async throws {
        guard let base = backendBase() else { throw ActivationError.backendUnavailable }
        guard let orderCode = cachedOrderCode(), !orderCode.isEmpty else { throw ActivationError.noOrder }
        guard let url = URL(string: base + "/cancel") else { throw ActivationError.backendUnavailable }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "order_id": orderCode, "reason": reason, "feedback": feedback,
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ActivationError.http(code) }
    }

    /// Client-side mirror of the server's default device cap (for the cap-reached message).
    static let DEFAULT_DEVICE_CAP = 3

    /// Release this device from its order on the backend and drop the local license. Best-effort:
    /// the cache is cleared regardless so the app returns to Free immediately.
    @discardableResult
    static func deactivate() async -> Bool {
        defer { clearCache() }
        guard let base = backendBase(),
              let req = deactivateRequest(base: base, deviceID: Device.id) else { return false }
        let ok = (try? await URLSession.shared.data(for: req)).map {
            (($0.1 as? HTTPURLResponse)?.statusCode ?? 0) == 200
        } ?? false
        return ok
    }

    /// Whether a cached license should be renewed: no token, or it expires within `within` seconds.
    /// Pure so it's unit-testable.
    static func shouldRenew(exp: Int?, now: Int, within: Int) -> Bool {
        guard let exp else { return true }
        return exp - now <= within
    }

    /// Refresh the license only when it's missing or near expiry — cheap to call on every launch.
    /// Keeps a valid device premium alive across the short server TTL without hammering the backend.
    static func refreshIfNeeded(renewWithinDays days: Int = 5) async {
        let now = Int(Date().timeIntervalSince1970)
        guard shouldRenew(exp: cachedClaims()?.exp, now: now, within: days * 24 * 3600) else { return }
        await fetch()
    }

    // MARK: - Cache (Keychain)

    private static let service = "com.livewallpaper.app.license"
    private static let account = "license-token"
    private static let orderAccount = "order-code"

    /// Clear the cached license AND the remembered order code — returns the app to Free.
    static func clearCache() { keychainSet(nil, account: account); keychainSet(nil, account: orderAccount) }
    private static func cache(_ token: String) { keychainSet(token, account: account) }

    /// The order code this machine activated with (needed by `/cancel`). Nil for trials/unactivated.
    static func cachedOrderCode() -> String? { keychainGet(account: orderAccount) }
    private static func cacheOrderCode(_ code: String) { keychainSet(code, account: orderAccount) }

    private static func cachedToken() -> String? { keychainGet(account: account) }

    private static func keychainGet(account: String) -> String? {
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

    private static func keychainSet(_ value: String?, account: String) {
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
