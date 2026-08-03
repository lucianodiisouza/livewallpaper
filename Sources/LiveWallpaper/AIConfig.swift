import Foundation
import Security

/// Configuration for AI wallpaper generation — **bring your own key**.
///
/// Generation always runs against the provider *you* choose with *your own* key: **Anthropic**
/// (Claude) directly, or any **OpenAI-compatible** endpoint — OpenAI, OpenRouter, Groq, or a **local**
/// runtime (Ollama / LM Studio) that works fully offline and can't be region-blocked. Primo never
/// proxies generation and never pays for it. Keys live in the Keychain, never hardcoded.
///
/// (The Primo *backend URL* — licensing, catalog, trial — is separate; see `backendURL` below.)
enum AIConfig {

    enum Provider: String, CaseIterable, Identifiable {
        case anthropic
        case openai    // any OpenAI-compatible /chat/completions endpoint (incl. local Ollama/LM Studio)

        var id: String { rawValue }
        var label: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI-compatible"
            }
        }
        var defaultBaseURL: String {
            switch self {
            case .anthropic: return "https://api.anthropic.com"
            case .openai: return "https://api.openai.com/v1"
            }
        }
        var defaultModel: String {
            switch self {
            case .anthropic: return "claude-opus-5"
            case .openai: return "gpt-4o"
            }
        }
        /// Whether the client needs an API key (local OpenAI-compatible runtimes don't).
        var requiresKey: Bool { self == .anthropic }
        var hint: String {
            switch self {
            case .anthropic:
                return "Uses the Anthropic Messages API directly with your own Claude key."
            case .openai:
                return "Any OpenAI-compatible endpoint with your own key — OpenAI, OpenRouter, Groq. For a local, offline, unblockable setup use Ollama (http://localhost:11434/v1) or LM Studio (http://localhost:1234/v1) — no key needed."
            }
        }
    }

    static let anthropicVersion = "2023-06-01"

    // MARK: - Primo backend URL (licensing / catalog / trial — NOT AI)

    /// The Primo backend Worker base URL, used by `Licensing` and the premium catalog. Distinct from
    /// AI generation (which is BYO-key, above). Defaults to production; overridable for dev.
    static let defaultBackendURL = "https://primo-ai.primo-ai.workers.dev"
    static var backendURL: String {
        get {
            let v = UserDefaults.standard.string(forKey: "primoBackendURL") ?? ""
            return v.isEmpty ? defaultBackendURL : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "primoBackendURL") }
    }

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
