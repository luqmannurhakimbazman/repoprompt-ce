import Foundation

// MARK: - Questions

/// One question the app asks a System One model about program state.
///
/// A question is declared once in `JudgmentQuestionCatalogue` and never composed at a
/// call site, so shadow measurements stay comparable across builds.
// swiftformat:disable redundantSendable
struct JudgmentQuestion: Sendable, Equatable {
    let id: String
    let instructions: String
    let kind: JudgmentQuestionKind
}

/// The three question primitives the System One API answers.
// swiftformat:disable redundantSendable
enum JudgmentQuestionKind: Sendable, Equatable {
    /// Probability that the answer is yes. Carries no confidence of its own.
    case noul(trueCriteria: String?, falseCriteria: String?)
    /// One option from a closed set, with a distribution and a confidence.
    case choice(rubricByOption: [String: String])
    /// A probability-weighted value over an ordered rubric, with a confidence.
    case score(levels: [String])
}

extension JudgmentQuestion {
    /// The JSON body this question occupies inside the request's `questions` map.
    var wireBody: [String: Any] {
        var body: [String: Any] = ["instructions": instructions]
        switch kind {
        case let .noul(trueCriteria, falseCriteria):
            body["type"] = "noul"
            var criteria: [String: String] = [:]
            if let trueCriteria { criteria["true"] = trueCriteria }
            if let falseCriteria { criteria["false"] = falseCriteria }
            if !criteria.isEmpty { body["criteria"] = criteria }
        case let .choice(rubricByOption):
            body["type"] = "choice"
            body["criteria"] = rubricByOption
        case let .score(levels):
            body["type"] = "score"
            body["criteria"] = levels
        }
        return body
    }
}

// MARK: - State

/// One field of a redacted state payload.
///
/// The closed set exists so `JudgmentStateRedactor` cannot accidentally serialize a
/// domain object whose contents nobody reviewed.
// swiftformat:disable redundantSendable
enum JudgmentStateValue: Sendable, Equatable {
    case text(String)
    case list([String])
    case flag(Bool)

    var jsonValue: Any {
        // Explicit returns for clarity: these branches produce three different types and
        // reading them side by side is clearer than an inferred Any.
        // swiftformat:disable redundantReturn
        switch self {
        case let .text(value):
            return value
        case let .list(values):
            return values
        case let .flag(value):
            return value
        }
    }
}

// MARK: - Answers

/// One typed answer, shaped by the question that produced it.
// swiftformat:disable redundantSendable
enum JudgmentAnswer: Sendable, Equatable {
    case noul(probability: Double)
    case choice(option: String, probabilities: [String: Double], confidence: Double)
    case score(value: Double, legend: [String: String], probabilities: [String: Double], confidence: Double)

    /// The model's own confidence, where it reports one.
    ///
    /// `noul` answers have none. Read those with a two-sided probability band rather
    /// than a threshold, because a `noul` of 0.5 is uncertainty and 0.5 is also a
    /// perfectly ordinary answer to a genuinely balanced question.
    var confidence: Double? {
        switch self {
        case .noul: nil
        case let .choice(_, _, confidence): confidence
        case let .score(_, _, _, confidence): confidence
        }
    }

    /// A stable label for diagnostics records.
    var kindLabel: String {
        switch self {
        case .noul: "noul"
        case .choice: "choice"
        case .score: "score"
        }
    }
}

// swiftformat:disable redundantSendable
struct JudgmentUsage: Sendable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
}

/// One answered request, including which model version answered it.
///
/// The version matters: the model is early access and versioned, and a version change
/// must invalidate collected calibration data rather than silently extend it.
// swiftformat:disable redundantSendable
struct JudgmentResult: Sendable, Equatable {
    let modelVersion: String
    let answersByQuestionID: [String: JudgmentAnswer]
    let usage: JudgmentUsage
    let latencySeconds: Double
}

// MARK: - Errors

/// Every way a judgment can fail. `JudgmentPolicy` maps all of them to `nil`.
enum JudgmentError: Error, Equatable {
    case unauthorized
    case invalidRequest(String)
    case rateLimited
    case overloaded
    case unexpectedStatus(Int)
    case transport(String)
    case malformedResponse(String)
    case timedOut
    case missingAnswer(questionID: String)
}
