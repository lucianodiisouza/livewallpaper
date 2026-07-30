import Foundation

/// Static safety checks for community Metal shaders. Fragment shaders are sandboxed by construction
/// (they can't reach the filesystem, network, or memory outside the pipeline), so containment is
/// mostly about **rejecting the constructs that aren't fragment shaders** — compute kernels and
/// buffer writes (see DESIGN.md §7 / SECURITY.md). This is a coarse textual gate at import time; it
/// is deliberately conservative (better to reject a weird-but-safe shader than admit an unsafe one).
enum ShaderValidator {

    enum Rejection: LocalizedError {
        case disallowed(String)
        case missingEntry

        var errorDescription: String? {
            switch self {
            case let .disallowed(what): return "Shader rejected: \(what)."
            case .missingEntry: return "Shader is missing the required 'f_main' fragment function."
            }
        }
    }

    /// Disallowed tokens. Compute stages and device/threadgroup writable buffers are out of scope.
    private static let banned: [(token: String, reason: String)] = [
        ("kernel ", "compute kernels are not allowed (fragment shaders only)"),
        ("[[kernel", "compute kernels are not allowed"),
        ("device ", "writable `device` buffers are not allowed"),
        ("threadgroup ", "threadgroup memory is not allowed"),
        ("atomic_", "atomic operations are not allowed"),
        ("#include \"", "local #include is not allowed"),   // only <metal_stdlib> etc.
    ]

    static func validate(_ source: String) throws {
        // Strip line/block comments so tokens inside comments don't trip the gate.
        let stripped = stripComments(source)
        for rule in banned where stripped.contains(rule.token) {
            throw Rejection.disallowed(rule.reason)
        }
        guard stripped.contains("f_main") else { throw Rejection.missingEntry }
    }

    private static func stripComments(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let rest = s[i...]
            if rest.hasPrefix("//") {
                while i < s.endIndex, s[i] != "\n" { i = s.index(after: i) }
            } else if rest.hasPrefix("/*") {
                i = s.index(i, offsetBy: 2)
                while i < s.endIndex, !s[i...].hasPrefix("*/") { i = s.index(after: i) }
                if i < s.endIndex { i = s.index(i, offsetBy: min(2, s.distance(from: i, to: s.endIndex))) }
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out
    }
}
