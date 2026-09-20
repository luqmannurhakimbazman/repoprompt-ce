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

    func testAnAskUserRequestAsksEveryQuestionInOneRequest() {
        let questions = JudgmentQuestionCatalogue.questions(for: .askUserExpiry(input))

        XCTAssertEqual(
            questions.map(\.id).sorted(),
            [
                "ask_user.needs_human_authority",
                "ask_user.picks_recommended_option",
                "ask_user.recommended_option_risk"
            ]
        )
    }

    /// The other two questions gate the agent's recommendation without predicting anything.
    /// This one predicts the label the row already records, so `picked_recommended` scores
    /// it directly and the sample can show whether the model beats the base rate — the rate
    /// at which people take the recommended option anyway. Without it a band can clear its
    /// agreement threshold purely because recommendations are usually good.
    ///
    /// Fixed wording, like every catalogue entry. The options themselves travel in the
    /// state payload, so the model reads them without the question varying per interaction.
    func testThePredictionQuestionIsANoulAboutTheRecommendedOption() throws {
        let question = try XCTUnwrap(
            JudgmentQuestionCatalogue.allQuestions.first { $0.id == "ask_user.picks_recommended_option" }
        )

        guard case let .noul(trueCriteria, falseCriteria) = question.kind else {
            return XCTFail("the prediction question must be a noul")
        }
        XCTAssertNotNil(trueCriteria)
        XCTAssertNotNil(falseCriteria)
        XCTAssertTrue(
            question.instructions.contains("recommended"),
            "The question must be about the recommended option, which is what slice 2 would fill in."
        )
    }

    func testEveryCatalogueQuestionHasAUniqueID() {
        let ids = JudgmentQuestionCatalogue.allQuestions.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count, "Two entries sharing an id would collide in the answers map.")
    }

    /// Mirrors `JudgmentRequest`'s cases. Adding a case there stops `tag(for:)` below from
    /// compiling until this list grows too, and the coverage assertion then fails until
    /// `everyRequest` grows as well. That chain is what makes the drift guard real.
    private enum RequestCase: CaseIterable {
        case askUserExpiry
    }

    private func tag(for request: JudgmentRequest) -> RequestCase {
        switch request {
        case .askUserExpiry: .askUserExpiry
        }
    }

    func testAllQuestionsContainsEveryQuestionAnyRequestCanAsk() {
        let everyRequest: [JudgmentRequest] = [.askUserExpiry(input)]

        XCTAssertEqual(
            Set(everyRequest.map(tag(for:))),
            Set(RequestCase.allCases),
            "Add the new JudgmentRequest case to everyRequest before this assertion means anything."
        )

        let asked = Set(everyRequest.flatMap { JudgmentQuestionCatalogue.questions(for: $0) }.map(\.id))
        let declared = Set(JudgmentQuestionCatalogue.allQuestions.map(\.id))

        XCTAssertTrue(
            asked.isSubset(of: declared),
            "allQuestions is hand-maintained beside questions(for:). Missing from allQuestions: \(asked.subtracting(declared).sorted())."
        )
    }

    // MARK: - Catalogue version

    func testTheCatalogueVersionIsAStableFingerprintOfTheRubrics() {
        let version = JudgmentQuestionCatalogue.version

        XCTAssertEqual(version.count, 16)
        XCTAssertNotEqual(version, "unhashable")
        XCTAssertTrue(version.allSatisfy(\.isHexDigit))
        // Recomputed from the same questions rather than read twice. Comparing the stored
        // property with itself cannot fail, so it said nothing about what the fingerprint
        // is derived from — which is the property the calibration sample depends on.
        XCTAssertEqual(
            version,
            JudgmentQuestionCatalogue.fingerprint(of: JudgmentQuestionCatalogue.allQuestions),
            "The published version must be the fingerprint of the declared questions."
        )
    }

    func testTheCatalogueVersionTracksRubricWordingRatherThanIdentity() {
        let original = JudgmentQuestionCatalogue.askUserNeedsHumanAuthority
        let reworded = JudgmentQuestion(
            id: original.id,
            instructions: original.instructions + " Answer carefully.",
            kind: original.kind
        )

        XCTAssertNotEqual(
            JudgmentQuestionCatalogue.fingerprint(of: [original]),
            JudgmentQuestionCatalogue.fingerprint(of: [reworded]),
            "A revision must be visible in the data, because it resets the calibration sample."
        )
        XCTAssertEqual(
            JudgmentQuestionCatalogue.fingerprint(of: [original]),
            JudgmentQuestionCatalogue.fingerprint(of: [original]),
            "The same wording must always fingerprint the same way."
        )
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
