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
        // `nil` means the app-wide recorder. Defaulting to `.shared` directly would read a
        // main-actor property from the nonisolated context a default argument is evaluated
        // in, which is an error in the Swift 6 language mode.
        recorder: JudgmentShadowRecorder? = nil
    ) async -> AskUserTimeoutBehavior {
        let recorder = recorder ?? .shared

        // Recording is the only reason this function awaits anything. With it off — which
        // is always, in a release build — the resolver returns immediately and expiry keeps
        // the shape it had before this seam existed.
        guard recorder.isRecordingEnabled else { return configured }

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
        //
        // Every question starts before any of them is awaited. Each judgment carries its own
        // 2-second whole-operation deadline, and the API answers the questions of a request
        // independently, so awaiting them one at a time would let a 10-question interaction
        // delay `continuation.resume` by up to 20 seconds for no gain. Awaiting all the
        // handles afterwards still keeps every record finished before this function returns.
        let records = interaction.questions.map { question in
            Task { @MainActor in
                await recorder.record(
                    interactionID: interaction.id,
                    question: question,
                    outcome: .expired(behavior: configured.rawValue)
                )
            }
        }
        for record in records {
            await record.value
        }
        return configured
    }
}
