import Foundation

/// The single source of truth for "is this user Premium?". Every paywalled feature checks
/// `isPremium`; nothing else stores entitlement state.
///
/// Premium now derives from a **device-bound license** (`Licensing`): a backend-signed token,
/// verified offline against the embedded public key and bound to this machine. The device's premium
/// flag is flipped server-side (today via the admin route; StoreKit purchase later). `refresh()`
/// fetches a fresh license; the result is cached so gating works offline afterwards.
///
/// `unlockForNow()`/`lock()` remain a **pre-release local dev override** for exercising the gated UI
/// without a live backend. That override is NOT device-bound DRM — never ship a build relying on it.
@MainActor
final class Entitlement: ObservableObject {
    static let shared = Entitlement()

    @Published private(set) var isPremium: Bool = false
    private let overrideKey = "entitlementDevOverride"

    private var devOverride: Bool {
        get { UserDefaults.standard.bool(forKey: overrideKey) }
        set { UserDefaults.standard.set(newValue, forKey: overrideKey) }
    }

    private init() { recompute() }

    /// Recompute from a valid device-bound license OR the local dev override.
    func recompute() {
        let licensed = Licensing.cachedClaims()?.premium == true
        let value = licensed || devOverride
        if value != isPremium { isPremium = value }
    }

    /// Fetch a fresh device-bound license from the backend, then recompute. Safe to call on launch.
    func refresh() async {
        _ = await Licensing.fetch()
        recompute()
    }

    /// Pre-release local dev override (NOT a purchase, NOT device-bound). For testing the gated UI.
    func unlockForNow() { devOverride = true; recompute() }
    /// Clear the dev override AND the cached license — returns to the free experience.
    func lock() { devOverride = false; Licensing.clearCache(); recompute() }
}
