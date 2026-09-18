@testable import RepoPromptApp
import XCTest

/// Covers the exact JSON the System One endpoint receives. The endpoint rejects a
/// malformed body with 422, so the shape is part of the contract, not a detail.
final class JudgmentWireFormatTests: XCTestCase {
    func testNoulQuestionCarriesItsTrueAndFalseCriteria() {
        let question = JudgmentQuestion(
            id: "ask_user.needs_human_authority",
            instructions: "Does this question ask for something only the user may decide?",
            kind: .noul(
                trueCriteria: "The question asks for permission or approval.",
                falseCriteria: "The question asks for a preference or a technical detail."
            )
        )

        let body = question.wireBody

        XCTAssertEqual(body["type"] as? String, "noul")
        XCTAssertEqual(body["instructions"] as? String, "Does this question ask for something only the user may decide?")
        let criteria = body["criteria"] as? [String: String]
        XCTAssertEqual(criteria?["true"], "The question asks for permission or approval.")
        XCTAssertEqual(criteria?["false"], "The question asks for a preference or a technical detail.")
    }

    func testNoulQuestionOmitsCriteriaWhenNeitherSideIsDescribed() {
        let question = JudgmentQuestion(
            id: "bare",
            instructions: "Is this urgent?",
            kind: .noul(trueCriteria: nil, falseCriteria: nil)
        )

        XCTAssertNil(question.wireBody["criteria"])
    }

    func testScoreQuestionSendsItsLevelsAsAnOrderedArray() {
        let question = JudgmentQuestion(
            id: "ask_user.recommended_option_risk",
            instructions: "How costly is choosing wrong?",
            kind: .score(levels: ["Free", "Wasteful", "Manual undo", "Irreversible"])
        )

        let body = question.wireBody

        XCTAssertEqual(body["type"] as? String, "score")
        XCTAssertEqual(body["criteria"] as? [String], ["Free", "Wasteful", "Manual undo", "Irreversible"])
    }

    func testChoiceQuestionSendsItsRubricAsAnObject() {
        let question = JudgmentQuestion(
            id: "triage",
            instructions: "What kind of failure is this?",
            kind: .choice(rubricByOption: ["compile": "The compiler rejected a file.", "flake": "It passes on a retry."])
        )

        let body = question.wireBody

        XCTAssertEqual(body["type"] as? String, "choice")
        XCTAssertEqual((body["criteria"] as? [String: String])?["flake"], "It passes on a retry.")
    }

    func testStatePayloadSerializesEachValueKind() {
        let state = JudgmentState(
            questionIDs: ["a"],
            fields: [
                "question": .text("Which database?"),
                "option_labels": .list(["SQLite", "Postgres"]),
                "allows_custom": .flag(true)
            ]
        )

        let object = state.jsonObject
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object))
        XCTAssertEqual(object["question"] as? String, "Which database?")
        XCTAssertEqual(object["option_labels"] as? [String], ["SQLite", "Postgres"])
        XCTAssertEqual(object["allows_custom"] as? Bool, true)
    }

    func testConfidenceIsAbsentForANoulAnswerAndPresentForTheOthers() {
        XCTAssertNil(JudgmentAnswer.noul(probability: 0.9).confidence)
        XCTAssertEqual(
            JudgmentAnswer.choice(option: "technical", probabilities: ["technical": 0.85], confidence: 0.82).confidence,
            0.82
        )
        XCTAssertEqual(
            JudgmentAnswer.score(value: 1.4, legend: ["0": "Free"], probabilities: ["0": 0.6], confidence: 0.71).confidence,
            0.71
        )
    }
}
