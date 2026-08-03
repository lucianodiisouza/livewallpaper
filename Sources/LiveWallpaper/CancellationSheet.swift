import SwiftUI

/// A deliberate 3-step cancellation flow for a subscription: (1) show what they'd lose and when,
/// (2) ask why, (3) collect free-text feedback and confirm. No save-offer — just a clear path out.
/// Calls `Entitlement.cancel`, which records the reason/feedback and cancels the Stripe sub at period
/// end (the user keeps Premium until then). See docs/BILLING.md in the backend repo.
struct CancellationSheet: View {
    /// Called when the sheet closes. `true` = cancellation completed; `false` = the user backed out.
    let onDone: (Bool) -> Void

    @ObservedObject private var entitlement = Entitlement.shared

    private enum Step: Int { case intro = 1, reason, confirm }
    @State private var step: Step = .intro
    @State private var reason: Reason?
    @State private var feedback = ""
    @State private var busy = false
    @State private var error: String?

    /// Structured cancellation reasons. `rawValue` is the slug sent to the backend.
    private enum Reason: String, CaseIterable, Identifiable {
        case tooExpensive = "too_expensive"
        case notUsing = "not_using"
        case missingFeature = "missing_feature"
        case technical = "technical"
        case other = "other"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tooExpensive: return "Too expensive"
            case .notUsing: return "Not using it enough"
            case .missingFeature: return "Missing a feature I need"
            case .technical: return "Technical problems"
            case .other: return "Something else"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            footer
        }
        .padding(20)
        .frame(width: 420)
    }

    /// The plan's end date, formatted — the retention anchor ("you keep access until…").
    private var endsText: String? {
        entitlement.planEndsDate.map { $0.formatted(date: .abbreviated, time: .omitted) }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .intro:
            stepHeader("Manage your subscription", step: 1)
            let planName = entitlement.claims?.plan == "annual" ? "Annual" : "Monthly"
            Text("You're on the \(planName) plan.")
            if let ends = endsText {
                Text("If you cancel, you'll keep Premium until \(ends), then this Mac returns to Free.")
                    .foregroundStyle(.secondary).font(.callout)
            }

        case .reason:
            stepHeader("Why are you canceling?", step: 2)
            Text("This helps us improve Primo Engine.").foregroundStyle(.secondary).font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Reason.allCases) { r in
                    Button { reason = r } label: {
                        HStack {
                            Image(systemName: reason == r ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(reason == r ? Color.accentColor : Color.secondary)
                            Text(r.label)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

        case .confirm:
            stepHeader("Anything you'd like us to know?", step: 3)
            TextEditor(text: $feedback)
                .font(.body)
                .frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text("Optional — your feedback goes straight to the team.")
                .font(.caption).foregroundStyle(.secondary)
            if let ends = endsText {
                Label("You'll keep Premium until \(ends).", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func stepHeader(_ title: String, step n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step \(n) of 3").font(.caption2).foregroundStyle(.secondary)
            Text(title).font(.title3).bold()
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            switch step {
            case .intro:
                Button("Keep subscription") { onDone(false) }.keyboardShortcut(.defaultAction)
                Spacer()
                Button("Continue to cancel") { step = .reason }
            case .reason:
                Button("Back") { step = .intro }
                Spacer()
                Button("Next") { step = .confirm }.disabled(reason == nil)
            case .confirm:
                Button("Back") { step = .reason }
                Spacer()
                if busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                Button("Confirm cancellation", role: .destructive, action: confirm).disabled(busy)
            }
        }
    }

    private func confirm() {
        busy = true; error = nil
        Task {
            do {
                try await entitlement.cancel(reason: reason?.rawValue ?? "other", feedback: feedback)
                busy = false
                onDone(true)
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}
