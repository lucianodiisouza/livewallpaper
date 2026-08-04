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

        // A fragment shader is a single function — 4096 output tokens is plenty.
        let text = try await AIProviderFactory.current().complete(system: system, user: userText, maxTokens: 4096)
        log.notice("Generated shader (\(AIConfig.provider.label, privacy: .public)) for prompt (\(prompt.prefix(40), privacy: .public)…)")
        return extractMetal(from: text)
    }

    /// Pull the shader source out of the model's reply (fenced block or trimmed text).
    static func extractMetal(from text: String) -> String { AIParse.codeBlock(from: text) }
}
