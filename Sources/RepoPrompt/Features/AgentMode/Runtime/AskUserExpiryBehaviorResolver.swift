import Foundation

/// Resolves what an expired `ask_user` interaction should do.
///
/// In slice 1 it always returns the configured behavior and only records a shadow
/// judgment. It exists as a seam so slice 2 can return a different behavior than the one
/// configured, without making `AskUserTimeoutBehavior.expiredResponse` async: that method
/// is pure and synchronous, and should stay both.
///
/// Slice 2's direction was decided on 2026-09-20 as **substitution**: a judgment inside the
/// safe band answers the expired question with its recommended option, in cases that would
/// otherwise return no answer. An earlier draft of this comment described the opposite —
/// downgrading a judged-unsafe interaction to `.returnNoAnswer` — and the calibration gates
/// were written against that reading. The distinction is not cosmetic: substitution acts
/// where nobody was present, so a wrong "safe" takes an action no one authorised, and the
/// gate has to measure the band it would act inside rather than the band it would refuse.
/// See `docs/architecture/system-one-judgment-calibration-report.md`.
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
