import Foundation

/// A text-completion backend for shader generation. Keeping this provider-agnostic is deliberate:
/// no single vendor lock-in, and a local OpenAI-compatible runtime (Ollama/LM Studio) works offline
/// and can't be region-blocked. Production will add a `BackendProvider` that proxies through our own
/// server, keeping keys server-side and letting the server pick/fallback across providers.
protocol ShaderProvider {
    /// `maxTokens` bounds the reply length. A shader is one function (small); a full HTML document is
    /// far larger, so the Web generator asks for much more — too low a cap silently truncates the reply.
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

enum AIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case refused(String?)      // model declined (safety, unsupported request)
    case truncated(String)     // hit max_tokens before producing a usable reply
    case noText                // shape we genuinely didn't expect
    case unusable(String)      // generated content failed validation (compile / offline gate)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set up an AI provider in Settings → AI Generation first."
        case let .http(code, msg): return "Generation failed (\(code)): \(msg)"
        case .refused: return "The model refused this request (it may violate the provider's usage policy)."
        case let .truncated(why): return "The model's reply was cut off: \(why). Try a shorter or simpler prompt."
        case .noText: return "The model returned an empty reply."
        case let .unusable(why): return why
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
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        guard let key = AIConfig.apiKey(for: .anthropic), !key.isEmpty else { throw AIError.notConfigured }
        let url = URL(string: AIConfig.baseURL(for: .anthropic).trimmedSlash + "/v1/messages")!

        let body: [String: Any] = [
            "model": AIConfig.model(for: .anthropic),
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300   // a full Web doc from a large model can take minutes; 60s default is too tight
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(AIConfig.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIError.http(code, AIParse.errorMessage(data)) }

        // Some 200s still carry an `error` envelope (overloaded, region-block, etc.). Surface it.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["type"] as? String) == "error" {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
            throw AIError.http(200, msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { throw AIError.noText }

        let stopReason = json["stop_reason"] as? String
        let text = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                         .joined(separator: "\n")

        if stopReason == "refusal" {
            throw AIError.refused(text.isEmpty ? nil : text)
        }
        if stopReason == "max_tokens" {
            // We have *some* text — keep it so the caller can try to salvage a partial reply.
            // If the caller can't use it, `.unusable` will fire downstream with a better message.
            if text.isEmpty { throw AIError.truncated("reached max_tokens with no text") }
            return text
        }
        if text.isEmpty {
            // tool_use-only response, or an unexpected content shape with no text blocks.
            throw AIError.noText
        }
        return text
    }
}

// MARK: - OpenAI-compatible (/chat/completions) — OpenAI, OpenRouter, Groq, Ollama, LM Studio…

struct OpenAICompatibleProvider: ShaderProvider {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let url = URL(string: AIConfig.baseURL(for: .openai).trimmedSlash + "/chat/completions")!

        let body: [String: Any] = [
            "model": AIConfig.model(for: .openai),
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300   // a full Web doc from a large model can take minutes; 60s default is too tight
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
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else { throw AIError.noText }

        // `content` is null on tool_calls-only responses, and may be empty on length stops.
        let text = (message["content"] as? String) ?? ""
        let finishReason = choice["finish_reason"] as? String

        if finishReason == "length" && text.isEmpty {
            throw AIError.truncated("reached max_tokens with no text")
        }
        if text.isEmpty {
            throw AIError.noText
        }
        return text
    }
}

// MARK: - Shared parsing

enum AIParse {
    /// Extract source out of a model reply: the contents of the first fenced code block if present
    /// (```lang … ```), otherwise the trimmed text. Shared by the shader and web generators.
    static func codeBlock(from text: String) -> String {
        guard let open = text.range(of: "```") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var contentStart = open.upperBound   // skip an optional language tag on the fence line
        if let nl = text[contentStart...].firstIndex(of: "\n") { contentStart = text.index(after: nl) }
        guard let close = text.range(of: "```", range: contentStart..<text.endIndex) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[contentStart..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
