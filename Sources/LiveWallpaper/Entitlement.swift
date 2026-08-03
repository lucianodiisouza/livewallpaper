import Foundation

/// The single source of truth for "is this user Premium?". Every paywalled feature checks
/// `isPremium`; nothing else stores entitlement state.
///
/// **Real activation is not built yet.** It will be a StoreKit one-time purchase plus server-side,
/// device-bound licensing (see docs/LICENSING.md), and it lands with the private backend. Until
/// then `unlockForNow()` is a **pre-release placeholder** that flips the entitlement locally so the
/// gated UI can be built and tested. It is NOT a purchase and NOT device-bound DRM — do not ship a
/// build that treats it as one. When StoreKit + backend activation arrive, they replace
/// `unlockForNow()`/`lock()`; the rest of the app keeps calling `isPremium` unchanged.
@MainActor
final class Entitlement: ObservableObject {
    static let shared = Entitlement()

    @Published private(set) var isPremium: Bool
    private let key = "entitlementPremium"

    private init() { isPremium = UserDefaults.standard.bool(forKey: key) }

    /// Pre-release placeholder unlock (see type note). Replace with real StoreKit + backend activation.
    func unlockForNow() { set(true) }
    /// Relock — useful for testing the free experience.
    func lock() { set(false) }

    private func set(_ value: Bool) {
        guard value != isPremium else { return }
        isPremium = value
        UserDefaults.standard.set(value, forKey: key)
    }
}
