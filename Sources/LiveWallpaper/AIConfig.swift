import Foundation
import Security

/// Configuration for AI wallpaper generation — provider-agnostic.
///
/// **Production routes through our own backend** so the model key stays server-side, we control
/// cost, and reachability/blocking/fallback is a server-side routing decision (see docs/FREEMIUM.md).
/// This pre-release build has no backend yet, so the client talks to a provider directly. It is
/// **not Anthropic-only**: pick Anthropic, or any **OpenAI-compatible** endpoint via a configurable
/// base URL — OpenAI, OpenRouter, Groq, or a **local** runtime (Ollama / LM Studio), which works
/// fully offline and can't be region-blocked. Keys live in the Keychain, never hardcoded.
enum AIConfig {

    enum Provider: String, CaseIterable, Identifiable {
        case anthropic
        case openai   // any OpenAI-compatible /chat/completions endpoint (incl. local Ollama/LM Studio)

        var id: String { rawValue }
        var label: String { self == .anthropic ? "Anthropic" : "OpenAI-compatible" }
        var defaultBaseURL: String {
            self == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
        }
        var defaultModel: String { self == .anthropic ? "claude-opus-5" : "gpt-4o" }
        /// Whether an API key is strictly required (local OpenAI-compatible runtimes need none).
        var requiresKey: Bool { self == .anthropic }
        var hint: String {
            self == .anthropic
                ? "Uses the Anthropic Messages API."
                : "Any OpenAI-compatible endpoint. For a local, offline, unblockable setup use Ollama (http://localhost:11434/v1) or LM Studio (http://localhost:1234/v1) — no key needed."
        }
    }

    static let anthropicVersion = "2023-06-01"

    // MARK: - Selection + per-provider settings (UserDefaults; keys in Keychain)

    static var provider: Provider {
        get { Provider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "aiProvider") }
    }

    static func baseURL(for p: Provider) -> String {
        let v = UserDefaults.standard.string(forKey: "aiBase.\(p.rawValue)") ?? ""
        return v.isEmpty ? p.defaultBaseURL : v
    }
    static func setBaseURL(_ value: String, for p: Provider) {
        UserDefaults.standard.set(value, forKey: "aiBase.\(p.rawValue)")
    }

    static func model(for p: Provider) -> String {
        let v = UserDefaults.standard.string(forKey: "aiModel.\(p.rawValue)") ?? ""
        return v.isEmpty ? p.defaultModel : v
    }
    static func setModel(_ value: String, for p: Provider) {
        UserDefaults.standard.set(value, forKey: "aiModel.\(p.rawValue)")
    }

    static func apiKey(for p: Provider) -> String? { keychainGet("aiKey.\(p.rawValue)") }
    static func setAPIKey(_ value: String?, for p: Provider) { keychainSet(value, account: "aiKey.\(p.rawValue)") }

    /// Enough to attempt a request: a base URL, plus a key if the provider requires one.
    static var isConfigured: Bool {
        let p = provider
        guard !baseURL(for: p).isEmpty else { return false }
        return !p.requiresKey || (apiKey(for: p)?.isEmpty == false)
    }

    // MARK: - Keychain

    private static let service = "com.livewallpaper.app.ai"

    private static func keychainGet(_ account: String) -> String? {
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

    private static func keychainSet(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
