import Foundation
import os

/// Generates a Metal fragment shader from a natural-language prompt, via whichever provider is
/// selected in `AIConfig` (Anthropic, or any OpenAI-compatible endpoint incl. local Ollama).
///
/// The model is asked for **only** the `f_main` fragment function (plus helpers) — the fixed prelude
/// (`Uniforms` struct + vertex stage) is prepended by the caller from `BuiltInShaders.prelude`, so
/// the model can't drift from the contract `MetalRenderer` compiles. The combined source still goes
/// through `ShaderValidator` + a real compile before install.
enum ShaderGenerator {

    private static let log = Logger(subsystem: "com.livewallpaper.app", category: "ShaderGenerator")

    enum GenError: LocalizedError {
        case invalidResult
        var errorDescription: String? {
            switch self {
            case .invalidResult: return "The generated shader didn't compile — try rephrasing."
            }
        }
    }

    /// The MSL contract the model must target. The prelude is prepended by the caller.
    private static let system = """
    You write Metal Shading Language (MSL) fragment shaders for a live-wallpaper engine.

    Output ONLY the fragment function and any helper functions it needs — no prose, no markdown \
    fences, no #include, no `using namespace`, and do NOT redeclare the Uniforms struct or the \
    vertex function (those are provided). Emit exactly this fragment signature:

        fragment float4 f_main(float4 fragCoord [[position]], constant Uniforms& u [[buffer(0)]])

    Available uniforms (already declared):
        struct Uniforms { float2 resolution; float time; float speed; float4 tint; };
    Use `u.time` for animation, `u.speed` as a multiplier, `u.resolution` for aspect, and multiply \
    the final rgb by `u.tint.rgb`. Return `float4(color, 1.0)`.

    Hard rules: fragment shaders ONLY — no `kernel`, no compute, no `device` writable buffers, no \
    atomics, no texture sampling, no external includes. Keep it cheap enough to run at 60fps \
    full-screen. The result must compile with `device.makeLibrary(source:)`.
    """

    /// Generate MSL for `prompt`. `feedback` (optional) steers a repair attempt.
    static func generate(prompt: String, feedback: String? = nil) async throws -> String {
        var userText = "Create a fragment shader: \(prompt)"
        if let feedback { userText += "\n\nThe previous attempt failed: \(feedback)\nReturn a corrected shader." }

        let text = try await AIProviderFactory.current().complete(system: system, user: userText)
        log.notice("Generated shader (\(AIConfig.provider.label, privacy: .public)) for prompt (\(prompt.prefix(40), privacy: .public)…)")
        return extractMetal(from: text)
    }

    // MARK: - Parsing (pure — unit-testable without a network)

    /// Pull the shader source out of the model's reply: the contents of the first fenced code block
    /// if present (```metal / ```cpp / ```), otherwise the trimmed text.
    static func extractMetal(from text: String) -> String {
        if let fenced = firstFencedBlock(in: text) { return fenced }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstFencedBlock(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        // Skip an optional language tag on the opening fence's line.
        var contentStart = open.upperBound
        if let nl = text[contentStart...].firstIndex(of: "\n") { contentStart = text.index(after: nl) }
        guard let close = text.range(of: "```", range: contentStart..<text.endIndex) else { return nil }
        return String(text[contentStart..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
