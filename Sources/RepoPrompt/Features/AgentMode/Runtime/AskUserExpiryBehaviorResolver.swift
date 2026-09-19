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
            // Both expiry call sites reach this from inside `schedulePendingAskUserTimeout`'s
            // `Task { @MainActor ... }`, and both call `invalidatePendingAskUserTimeout(for:)` —
            // which cancels `session.askUserTimeoutTask`, the very task this code is running
            // inside — a few lines before reaching this resolver. A plain
            // `await recorder.record(...)` here would therefore run inside an already-cancelled
            // task, so every cancellation-aware await beneath it (`Task.sleep`,
            // `URLSession.data(for:)` inside `JevJudgmentClient`) would throw immediately, and
            // `JudgmentPolicy` swallows that into `nil` — collecting no judgment at all for
            // exactly the funnel this resolver exists to measure.
            //
            // Hopping into a fresh, unstructured `Task` avoids that: `Task.init` builds it with
            // `isChildTask: false` (see `_Concurrency`'s `Task.init(name:priority:operation:)`),
            // so it is not a structured child of the caller and does not inherit the caller's
            // cancellation — only its actor context (via `@_inheritActorContext`) and priority.
            // Awaiting `.value` still keeps the record finished before this function returns.
            await Task { @MainActor in
                await recorder.record(
                    interactionID: interaction.id,
                    question: question,
                    outcome: .expired(behavior: configured.rawValue)
                )
            }.value
        }
        return configured
    }
}
