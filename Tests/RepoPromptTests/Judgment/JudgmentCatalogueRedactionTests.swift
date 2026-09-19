@testable import RepoPromptApp
import XCTest

/// Covers the two catalogue entries and the payload they are allowed to send.
///
/// The key-set assertions are the privacy contract: a field added to the payload
/// without being declared here fails the suite.
final class JudgmentCatalogueRedactionTests: XCTestCase {
    private var input: AskUserExpiryJudgmentInput {
        AskUserExpiryJudgmentInput(
            questionText: "Which database should we use?",
            context: "The schema is already written for Postgres.",
            optionLabels: ["SQLite", "Postgres"],
            optionDescriptions: ["Single file", "Server"],
            recommendedOptionLabel: "Postgres"
        )
    }

    // MARK: - Catalogue

    func testTheRiskQuestionIsAnOrderedFourLevelScore() {
        let question = JudgmentQuestionCatalogue.askUserRecommendedOptionRisk

        XCTAssertEqual(question.id, "ask_user.recommended_option_risk")
        guard case let .score(levels) = question.kind else {
            return XCTFail("the risk question must be a score")
        }
        XCTAssertEqual(levels.count, 4, "The API requires at least 2 levels and the rubric defines 4.")
        XCTAssertFalse(question.instructions.isEmpty)
        XCTAssertTrue(levels.allSatisfy { !$0.isEmpty })
    }

    func testTheAuthorityQuestionIsANoulWithBothSidesDescribed() {
        let question = JudgmentQuestionCatalogue.askUserNeedsHumanAuthority

        XCTAssertEqual(question.id, "ask_user.needs_human_authority")
        guard case let .noul(trueCriteria, falseCriteria) = question.kind else {
            return XCTFail("the authority question must be a noul")
        }
        XCTAssertNotNil(trueCriteria)
        XCTAssertNotNil(falseCriteria)
    }

    func testAnAskUserRequestAsksBothQuestionsInOneRequest() {
        let questions = JudgmentQuestionCatalogue.questions(for: .askUserExpiry(input))

        XCTAssertEqual(
            questions.map(\.id).sorted(),
            ["ask_user.needs_human_authority", "ask_user.recommended_option_risk"]
        )
    }

    func testEveryCatalogueQuestionHasAUniqueID() {
        let ids = JudgmentQuestionCatalogue.allQuestions.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count, "Two entries sharing an id would collide in the answers map.")
    }

    // MARK: - Redaction

    func testThePayloadCarriesExactlyTheDeclaredFields() {
        let plan = JudgmentStateRedactor.plan(for: .askUserExpiry(input))

        XCTAssertEqual(
            Set(plan.state.fields.keys),
            ["question", "context", "option_labels", "option_descriptions", "recommended_option"]
        )
    }

    func testThePayloadCarriesTheQuestionAndItsOptions() {
        let plan = JudgmentStateRedactor.plan(for: .askUserExpiry(input))

        XCTAssertEqual(plan.state.fields["question"], .text("Which database should we use?"))
        XCTAssertEqual(plan.state.fields["option_labels"], .list(["SQLite", "Postgres"]))
        XCTAssertEqual(plan.state.fields["recommended_option"], .text("Postgres"))
    }

    func testAMissingContextAndRecommendationBecomeEmptyRatherThanAbsent() {
        let bare = AskUserExpiryJudgmentInput(
            questionText: "Any extra constraints?",
            context: nil,
            optionLabels: [],
            optionDescriptions: [],
            recommendedOptionLabel: nil
        )

        let plan = JudgmentStateRedactor.plan(for: .askUserExpiry(bare))

        XCTAssertEqual(plan.state.fields["context"], .text(""))
        XCTAssertEqual(plan.state.fields["recommended_option"], .text(""))
        XCTAssertEqual(
            Set(plan.state.fields.keys),
            ["question", "context", "option_labels", "option_descriptions", "recommended_option"],
            "The key set must not vary with the input, or records stop being comparable."
        )
    }

    func testThePlanTagsTheStateWithTheQuestionsItWasBuiltFor() {
        let plan = JudgmentStateRedactor.plan(for: .askUserExpiry(input))

        XCTAssertEqual(Set(plan.state.questionIDs), Set(plan.questions.map(\.id)))
    }

    func testThePayloadIsJSONSerializable() {
        let plan = JudgmentStateRedactor.plan(for: .askUserExpiry(input))

        XCTAssertTrue(JSONSerialization.isValidJSONObject(plan.state.jsonObject))
    }
}
