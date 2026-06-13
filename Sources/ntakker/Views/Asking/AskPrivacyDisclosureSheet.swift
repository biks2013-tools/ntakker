// ntakker/Views/Asking/AskPrivacyDisclosureSheet.swift — plan-015
// Phase 4 (FR-IRQ-18). Privacy disclosure specific to the in-recording
// Q&A surface.
//
// Distinct from `PrivacyDisclosureSheet` (transcription-only copy
// talks about *audio* leaving the machine). The Q&A flow sends the
// question text + a transcript window — not raw audio — to the
// configured LLM provider, so the copy is materially different. The
// per-provider acknowledgement keys live under a separate namespace
// (`com.local.ntakker.ask.privacy.<provider>.acknowledged`) so
// users opt in once per provider per data-residency posture.

import NtakkerCore
import SwiftUI

/// Lightweight view-model — same pattern as
/// `PrivacyDisclosureViewModel` but with its own keyspace so a
/// transcription acknowledgement does NOT silently grant the Q&A
/// surface for the same provider.
public final class AskPrivacyDisclosureViewModel {
    public static func acknowledgedKey(for provider: AskProvider) -> String {
        "com.local.ntakker.ask.privacy.\(provider.rawValue).acknowledged"
    }

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func hasAcknowledged(_ provider: AskProvider) -> Bool {
        defaults.bool(forKey: Self.acknowledgedKey(for: provider))
    }

    public func acknowledge(_ provider: AskProvider) {
        defaults.set(true, forKey: Self.acknowledgedKey(for: provider))
    }
}

struct AskPrivacyDisclosureSheet: View {
    let provider: AskProvider
    let onAcknowledge: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Questions will be sent to \(provider.displayName)")
                .font(.headline)

            Text(bodyCopy)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("I understand", action: onAcknowledge)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var bodyCopy: String {
        switch provider {
        case .openai:
            return """
                Each question you submit AND the last few minutes of your live transcript \
                will be sent to OpenAI's API (api.openai.com). Per OpenAI's API data-usage \
                policy, business-account API content is not used to train models by default.
                """
        case .anthropic:
            return """
                Each question you submit AND the last few minutes of your live transcript \
                will be sent to Anthropic's API (api.anthropic.com). Per Anthropic's \
                Commercial Terms, API inputs and outputs are not used to train Anthropic's \
                models by default.
                """
        case .google:
            return """
                Each question you submit AND the last few minutes of your live transcript \
                will be sent to Google's Generative Language API. Per Google's terms, paid \
                Gemini API content is not used to improve Google's models without your \
                explicit consent; the free tier may be used for product improvement.
                """
        case .azureOpenAI:
            return """
                Each question you submit AND the last few minutes of your live transcript \
                will be sent to your Microsoft Azure OpenAI deployment. Microsoft \
                contractually commits that your prompts and completions are never used \
                to train AI models and are never shared with OpenAI or other parties.
                """
        case .azureAIInference:
            return """
                Each question you submit AND the last few minutes of your live transcript \
                will be sent to your Microsoft Azure AI Foundry deployment. Microsoft \
                contractually commits that your prompts and completions are never used to \
                train AI models and are never shared with third parties.
                """
        case .litellm:
            return """
                Each question you submit AND the last few minutes of your live transcript \
                will be routed through your configured LiteLLM proxy. Depending on the \
                proxy's backend, the data may be forwarded to a third-party LLM provider. \
                Review your LiteLLM proxy configuration before continuing.
                """
        case .ollama, .mlx:
            // Local providers do not reach this sheet (`isCloud == false`).
            return ""
        }
    }
}
