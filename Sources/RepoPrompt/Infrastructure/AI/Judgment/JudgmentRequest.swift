import Foundation

// Explicit `Sendable` conformances are intentional actor-boundary contracts.
// swiftformat:disable redundantSendable

/// The closed set of judgments the app may ask for.
///
/// Consumers pass one of these rather than a `JudgmentState`, so the fields that can
/// leave this machine are fixed by the type system instead of by review. Adding a field
/// means editing this file and `JudgmentStateRedactor` together.
enum JudgmentRequest: Sendable, Equatable {
    case askUserExpiry(AskUserExpiryJudgmentInput)
}

/// Everything a judgment may know about an `ask_user` question.
///
/// Deliberately not the domain type: `AgentAskUserQuestion` and `AgentAskUserInteraction`
/// carry identifiers, timestamps, and drafts that must not be sent anywhere.
struct AskUserExpiryJudgmentInput: Sendable, Equatable {
    let questionText: String
    let context: String?
    let optionLabels: [String]
    let optionDescriptions: [String]
    let recommendedOptionLabel: String?
}
