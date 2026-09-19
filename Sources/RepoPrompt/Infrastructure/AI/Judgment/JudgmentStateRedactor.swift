import Foundation

/// A request turned into the exact questions and payload to send.
struct JudgmentPlan: Equatable {
    let questions: [JudgmentQuestion]
    let state: JudgmentState
}

/// The only place a `JudgmentState` is built.
///
/// Every field it emits is listed in the `switch` below. File contents, transcripts,
/// environment values, absolute paths, and workspace names have no path into a payload,
/// because no request case carries them.
enum JudgmentStateRedactor {
    static func plan(for request: JudgmentRequest) -> JudgmentPlan {
        let questions = JudgmentQuestionCatalogue.questions(for: request)
        let fields: [String: JudgmentStateValue] = switch request {
        case let .askUserExpiry(input):
            [
                "question": .text(input.questionText),
                "context": .text(input.context ?? ""),
                "option_labels": .list(input.optionLabels),
                "option_descriptions": .list(input.optionDescriptions),
                "recommended_option": .text(input.recommendedOptionLabel ?? "")
            ]
        }
        // `AgentAskUserQuestion.header` is deliberately absent. It is a short UI label
        // that adds nothing a rubric can use, and every field here is one more thing
        // leaving the machine.

        return JudgmentPlan(
            questions: questions,
            state: JudgmentState(questionIDs: questions.map(\.id), fields: fields)
        )
    }
}
