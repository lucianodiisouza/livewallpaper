import Foundation

/// A text-completion backend for shader generation. Keeping this provider-agnostic is deliberate:
/// no single vendor lock-in, and a local OpenAI-compatible runtime (Ollama/LM Studio) works offline
/// and can't be region-blocked. Production will add a `BackendProvider` that proxies through our own
/// server, keeping keys server-side and letting the server pick/fallback across providers.
protocol ShaderProvider {
    func complete(system: String, user: String) async throws -> String
}

enum AIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case noText
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set up an AI provider in Settings → AI Generation first."
        case let .http(code, msg): return "Generation failed (\(code)): \(msg)"
        case .noText: return "The model returned no text."
        }
    }
}

/// Builds the right provider for the current `AIConfig` selection.
enum AIProviderFactory {
    static func current() -> ShaderProvider {
        switch AIConfig.provider {
        case .anthropic: return AnthropicProvider()
        case .openai:    return OpenAICompatibleProvider()
        }
    }
}

// MARK: - Anthropic (Messages API)

struct AnthropicProvider: ShaderProvider {
    func complete(system: String, user: String) async throws -> String {
        guard let key = AIConfig.apiKey(for: .anthropic), !key.isEmpty else { throw AIError.notConfigured }
        let url = URL(string: AIConfig.baseURL(for: .anthropic).trimmedSlash + "/v1/messages")!

        let body: [String: Any] = [
            "model": AIConfig.model(for: .anthropic),
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(AIConfig.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIError.http(code, AIParse.errorMessage(data)) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { throw AIError.noText }
        for block in content where (block["type"] as? String) == "text" {
            if let t = block["text"] as? String { return t }
        }
        throw AIError.noText
    }
}

// MARK: - OpenAI-compatible (/chat/completions) — OpenAI, OpenRouter, Groq, Ollama, LM Studio…

struct OpenAICompatibleProvider: ShaderProvider {
    func complete(system: String, user: String) async throws -> String {
        let url = URL(string: AIConfig.baseURL(for: .openai).trimmedSlash + "/chat/completions")!

        let body: [String: Any] = [
            "model": AIConfig.model(for: .openai),
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Local runtimes (Ollama/LM Studio) need no key; send it only when present.
        if let key = AIConfig.apiKey(for: .openai), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIError.http(code, AIParse.errorMessage(data)) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { throw AIError.noText }
        return text
    }
}

// MARK: - Shared parsing

enum AIParse {
    /// Pull a human-readable error from either provider's error envelope, else a truncated body.
    static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = json["error"] as? String { return msg }
        }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? "unknown error"
    }
}

private extension String {
    /// Drop a single trailing slash so base-URL joins don't double up.
    var trimmedSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
