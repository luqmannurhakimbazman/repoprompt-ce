import Foundation

/// Resolves what an expired `ask_user` interaction should do.
///
/// In slice 1 it always returns the configured behavior and only records a shadow
/// judgment. It exists as a seam so slice 2 can downgrade a judged-unsafe interaction to
/// `.returnNoAnswer` without making `AskUserTimeoutBehavior.expiredResponse` async: that
/// method is pure and synchronous, and should stay both.
@MainActor
enum AskUserExpiryBehaviorResolver {
    static func effectiveBehavior(
        configured: AskUserTimeoutBehavior,
        interaction: AgentAskUserInteraction,
        recorder: JudgmentShadowRecorder = .shared
    ) async -> AskUserTimeoutBehavior {
        for question in interaction.questions {
            await recorder.record(
                interactionID: interaction.id,
                question: question,
                outcome: .expired(behavior: configured.rawValue)
            )
        }
        return configured
    }
}
