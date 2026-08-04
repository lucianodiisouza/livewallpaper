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
            case .tooExpensive: return String(localized: "cancel.reason.tooExpensive", bundle: .main)
            case .notUsing: return String(localized: "cancel.reason.notUsing", bundle: .main)
            case .missingFeature: return String(localized: "cancel.reason.missingFeature", bundle: .main)
            case .technical: return String(localized: "cancel.reason.technical", bundle: .main)
            case .other: return String(localized: "cancel.reason.other", bundle: .main)
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
            stepHeader(String(localized: "cancel.intro.title", bundle: .main), step: 1)
            let planName = NSLocalizedString(entitlement.claims?.plan == "annual" ? "cancel.plan.annual" : "cancel.plan.monthly",
                                             bundle: .main, comment: "")
            Text(String(format: NSLocalizedString("cancel.intro.body", bundle: .main, comment: ""), planName))
            if let ends = endsText {
                Text(String(format: NSLocalizedString("cancel.intro.note", bundle: .main, comment: ""), ends))
                    .foregroundStyle(.secondary).font(.callout)
            }

        case .reason:
            stepHeader(String(localized: "cancel.reason.title", bundle: .main), step: 2)
            Text(LocalizedStringKey("cancel.reason.body")).foregroundStyle(.secondary).font(.callout)
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
            stepHeader(String(localized: "cancel.confirm.title", bundle: .main), step: 3)
            TextEditor(text: $feedback)
                .font(.body)
                .frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text(LocalizedStringKey("cancel.confirm.placeholder"))
                .font(.caption).foregroundStyle(.secondary)
            if let ends = endsText {
                Label(String(format: String(localized: "cancel.confirm.note", bundle: .main), ends),
                      systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func stepHeader(_ title: String, step n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: String(localized: "cancel.step", bundle: .main), n))
                .font(.caption2).foregroundStyle(.secondary)
            Text(title).font(.title3).bold()
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            switch step {
            case .intro:
                Button(LocalizedStringKey("cancel.button.keep")) { onDone(false) }.keyboardShortcut(.defaultAction)
                Spacer()
                Button(LocalizedStringKey("cancel.button.continue")) { step = .reason }
            case .reason:
                Button(LocalizedStringKey("cancel.button.back")) { step = .intro }
                Spacer()
                Button(LocalizedStringKey("cancel.button.next")) { step = .confirm }.disabled(reason == nil)
            case .confirm:
                Button(LocalizedStringKey("cancel.button.back")) { step = .reason }
                Spacer()
                if busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                Button(LocalizedStringKey("cancel.button.confirm"), role: .destructive, action: confirm).disabled(busy)
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
