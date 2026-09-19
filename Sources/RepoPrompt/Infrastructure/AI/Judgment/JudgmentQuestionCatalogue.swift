import Foundation

/// Every question the app may ask a System One model, declared once.
///
/// Rubric wording is the real interface to this model: accuracy depends more on these
/// level descriptions than on any code around them. Keeping them here means a revision
/// is one reviewable diff, and it is the event that resets a calibration sample.
enum JudgmentQuestionCatalogue {
    /// How costly it is to take the recommended option without asking anyone.
    static let askUserRecommendedOptionRisk = JudgmentQuestion(
        id: "ask_user.recommended_option_risk",
        instructions: """
        An AI coding agent asked its user this question and nobody answered before the window closed. \
        Rate how costly it would be to act on the recommended option without a person confirming it.
        """,
        kind: .score(levels: [
            "Choosing wrong costs nothing. The run can change course later at no cost.",
            "Choosing wrong wastes work that is easy to redo.",
            "Choosing wrong writes files or changes local state that a person must undo by hand.",
            "Choosing wrong acts outside this machine, or does something no one can undo."
        ])
    )

    /// Whether the question is one the user reserved for themselves.
    static let askUserNeedsHumanAuthority = JudgmentQuestion(
        id: "ask_user.needs_human_authority",
        instructions: """
        An AI coding agent asked its user this question. Decide whether answering it requires the \
        user's own authority rather than the agent's judgment.
        """,
        kind: .noul(
            trueCriteria: "The question asks for permission, approval, or a decision the user reserved for themselves.",
            falseCriteria: """
            The question asks for a preference, a name, or a technical detail the agent could have \
            worked out itself.
            """
        )
    )

    /// Every declared entry, used to assert ids stay unique.
    static let allQuestions: [JudgmentQuestion] = [
        askUserRecommendedOptionRisk,
        askUserNeedsHumanAuthority
    ]

    /// The questions one request asks.
    ///
    /// They travel together because the API answers the questions in a request
    /// independently and in parallel, so two questions cost one round trip.
    static func questions(for request: JudgmentRequest) -> [JudgmentQuestion] {
        switch request {
        case .askUserExpiry:
            [askUserRecommendedOptionRisk, askUserNeedsHumanAuthority]
        }
    }
}
