import Foundation

// Explicit `Sendable` conformances are intentional actor-boundary contracts.
// swiftformat:disable redundantSendable

/// The redacted payload sent as the request's `state`.
///
/// This initialiser is `fileprivate`, so `JudgmentStateRedactor.plan(for:)` below is the
/// only production call site that can build one. Consumers pass a `JudgmentRequest`
/// instead, so no call site anywhere else in the app can add a field that the catalogue
/// did not declare. The `forTesting` factory is the single exception, and it exists only
/// in DEBUG builds.
struct JudgmentState: Sendable, Equatable {
    /// The catalogue entries this payload was built for.
    let questionIDs: [String]
    let fields: [String: JudgmentStateValue]

    fileprivate init(questionIDs: [String], fields: [String: JudgmentStateValue]) {
        self.questionIDs = questionIDs
        self.fields = fields
    }

    var jsonObject: [String: Any] {
        fields.mapValues(\.jsonValue)
    }
}

#if DEBUG
    extension JudgmentState {
        /// Builds a payload without going through `JudgmentStateRedactor`.
        ///
        /// Tests only, and DEBUG only. Production code must not have a way to assemble a
        /// payload the catalogue did not declare — that restriction is the privacy
        /// guarantee this whole area exists to provide.
        static func forTesting(questionIDs: [String], fields: [String: JudgmentStateValue]) -> JudgmentState {
            JudgmentState(questionIDs: questionIDs, fields: fields)
        }
    }
#endif

/// A request turned into the exact questions and payload to send.
struct JudgmentPlan: Sendable, Equatable {
    let questions: [JudgmentQuestion]
    let state: JudgmentState
}

/// The only place a `JudgmentState` is built in production code.
///
/// Every field it emits is listed in the `switch` below, and that switch fixes which
/// fields are sent, not what they contain. The five `ask_user` fields carry free text the
/// calling agent wrote, so a path, snippet, or credential an agent puts in its own
/// question text does travel. What the app itself never contributes, because no request
/// case carries it: file contents it read, transcript text, environment values, and
/// workspace names. Those have no path into a payload, because no request case carries
/// them, and `JudgmentState`'s `fileprivate` initialiser means no call site outside this
/// file can construct one that bypasses this list.
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
