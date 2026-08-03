import Foundation

/// The single source of truth for "is this user Premium?". Every paywalled feature checks
/// `isPremium`; nothing else stores entitlement state.
///
/// Premium now derives from a **device-bound license** (`Licensing`): a backend-signed token,
/// verified offline against the embedded public key and bound to this machine. The device's premium
/// flag is flipped server-side (today via the admin route; StoreKit purchase later). `refresh()`
/// fetches a fresh license; the result is cached so gating works offline afterwards.
///
/// Dev/staging premium is granted **server-side** via the backend admin token (see
/// docs/BILLING.md in the backend repo) — there is deliberately no client-side "unlock" override,
/// since this app is open-source and any such override would ship to users. The only in-app override
/// is `setPremiumForTesting`, an in-memory, non-persisted hook used solely by `--selftest`.
@MainActor
final class Entitlement: ObservableObject {
    static let shared = Entitlement()

    @Published private(set) var isPremium: Bool = false

    /// In-memory only, never persisted, no UI surface. `nil` = use the real license; `true`/`false`
    /// = force premium on/off for headless test runs (`--selftest`), without touching the cache.
    private var testPremiumOverride: Bool?

    private init() { recompute() }

    /// Recompute premium from a valid device-bound license (or the in-memory test override).
    func recompute() {
        let licensed = Licensing.cachedClaims()?.premium == true
        let value = testPremiumOverride ?? licensed
        if value != isPremium { isPremium = value }
    }

    // MARK: - Plan info (drives the per-machine UI copy)

    /// Claims from the current valid, this-machine license, if any.
    var claims: Licensing.Claims? { Licensing.cachedClaims() }
    /// A lifetime buyer may self-serve extra machines; everyone else is bound to this Mac.
    var isLifetime: Bool { claims?.isLifetime == true }
    var isTrial: Bool { claims?.isTrial == true }
    var isSubscription: Bool { claims?.isSubscription == true }
    /// When the current plan's paid window ends (trial/sub), or nil for perpetual/none.
    var planEndsDate: Date? { claims?.planEnds.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// Fetch a fresh device-bound license from the backend, then recompute. Safe to call on launch.
    func refresh() async {
        _ = await Licensing.fetch()
        recompute()
    }

    /// Refresh only when the cached license is missing or near expiry — the launch-time path.
    func refreshIfNeeded() async {
        await Licensing.refreshIfNeeded()
        recompute()
    }

    /// Activate this device with a license code (ties it to an order under the device cap), then
    /// recompute. Throws a friendly `Licensing.ActivationError` on failure.
    func activate(code: String) async throws {
        _ = try await Licensing.activate(orderCode: code.trimmingCharacters(in: .whitespacesAndNewlines))
        recompute()
    }

    /// Start the one-time free trial on this machine, then recompute. Throws `.trialUsed` if this
    /// Mac already used it.
    func startTrial() async throws {
        _ = try await Licensing.startTrial()
        recompute()
    }

    /// Cancel the current plan and send exit feedback (reason + free text). See `Licensing.cancel`.
    func cancel(reason: String, feedback: String) async throws {
        try await Licensing.cancel(reason: reason, feedback: feedback)
    }

    /// Release this device on the backend and return to Free (lifetime buyers moving machines).
    func deactivate() async {
        _ = await Licensing.deactivate()
        recompute()
    }

    /// Headless-test hook ONLY (`--selftest`): forces premium in memory (`nil` restores real license
    /// state). Never persisted, no UI, doesn't touch the cache.
    func setPremiumForTesting(_ on: Bool?) { testPremiumOverride = on; recompute() }
}
