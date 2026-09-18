import MCP
@testable import RepoPromptApp
import XCTest

/// Covers the inactivity auto-answer path: which option the app picks for an
/// unanswered `ask_user` question when the Question Timeout window expires.
final class AskUserAutoAnswerTests: XCTestCase {
    func testRecommendedOptionPrefersTheFlaggedOption() {
        let question = AgentAskUserQuestion(
            id: "database",
            question: "Which database should we use?",
            options: [
                AgentAskUserOption(label: "SQLite"),
                AgentAskUserOption(label: "Postgres", isRecommended: true)
            ]
        )

        XCTAssertEqual(question.recommendedOption?.label, "Postgres")
    }

    func testRecommendedOptionFallsBackToFirstOptionWhenNoneAreFlagged() {
        let question = AgentAskUserQuestion(
            id: "database",
            question: "Which database should we use?",
            options: [
                AgentAskUserOption(label: "SQLite"),
                AgentAskUserOption(label: "Postgres")
            ]
        )

        XCTAssertEqual(question.recommendedOption?.label, "SQLite")
    }

    func testRecommendedOptionIsNilWhenQuestionHasNoOptions() {
        let question = AgentAskUserQuestion(
            id: "notes",
            question: "Any extra constraints?",
            allowsCustom: true
        )

        XCTAssertNil(question.recommendedOption)
    }

    // MARK: - Auto-answered response

    private func interaction(questions: [AgentAskUserQuestion]) -> AgentAskUserInteraction {
        AgentAskUserInteraction(title: "Question", timeoutSeconds: 30, questions: questions)
    }

    private var databaseQuestion: AgentAskUserQuestion {
        AgentAskUserQuestion(
            id: "database",
            question: "Which database should we use?",
            options: [
                AgentAskUserOption(label: "SQLite"),
                AgentAskUserOption(label: "Postgres", isRecommended: true)
            ],
            allowsCustom: false
        )
    }

    func testAutoAnsweredResponseSelectsTheRecommendedOption() throws {
        let interaction = interaction(questions: [databaseQuestion])

        let response = interaction.buildAutoAnsweredResponse(drafts: [:], elapsedSeconds: 30)

        let answer = try XCTUnwrap(response.answersByQuestionID["database"])
        XCTAssertEqual(answer.selectedOptions, ["Postgres"])
        XCTAssertEqual(answer.answers, ["Postgres"])
        XCTAssertFalse(answer.skipped)
    }

    func testAutoAnsweredResponseKeepsAnAnswerTheUserAlreadyStarted() throws {
        let interaction = interaction(questions: [databaseQuestion])
        let drafts = ["database": AgentAskUserDraft(selectedOptionLabels: ["SQLite"])]

        let response = interaction.buildAutoAnsweredResponse(drafts: drafts, elapsedSeconds: 30)

        let answer = try XCTUnwrap(response.answersByQuestionID["database"])
        XCTAssertEqual(answer.selectedOptions, ["SQLite"])
    }

    func testAutoAnsweredResponseSkipsAQuestionThatHasNoOptions() throws {
        let interaction = interaction(questions: [
            AgentAskUserQuestion(id: "notes", question: "Any extra constraints?", allowsCustom: true)
        ])

        let response = interaction.buildAutoAnsweredResponse(drafts: [:], elapsedSeconds: 30)

        let answer = try XCTUnwrap(response.answersByQuestionID["notes"])
        XCTAssertTrue(answer.skipped)
        XCTAssertTrue(answer.answers.isEmpty)
    }

    func testAutoAnsweredResponseSelectsASingleOptionForAMultiSelectQuestion() throws {
        let interaction = interaction(questions: [
            AgentAskUserQuestion(
                id: "targets",
                question: "Which targets should we build?",
                options: [
                    AgentAskUserOption(label: "App"),
                    AgentAskUserOption(label: "MCP", isRecommended: true)
                ],
                allowsMultiple: true,
                allowsCustom: false
            )
        ])

        let response = interaction.buildAutoAnsweredResponse(drafts: [:], elapsedSeconds: 30)

        let answer = try XCTUnwrap(response.answersByQuestionID["targets"])
        XCTAssertEqual(answer.selectedOptions, ["MCP"])
    }

    func testAutoAnsweredResponseReportsWhoAnsweredIt() {
        let interaction = interaction(questions: [databaseQuestion])

        let response = interaction.buildAutoAnsweredResponse(drafts: [:], elapsedSeconds: 30)

        XCTAssertTrue(response.autoAnswered)
        XCTAssertFalse(response.timedOut)
        XCTAssertFalse(response.skipped)
        XCTAssertEqual(response.elapsedSeconds, 30)
    }

    func testAutoAnsweredIsFalseForAnOrdinaryTimedOutResponse() {
        let interaction = interaction(questions: [databaseQuestion])

        let response = interaction.buildTimedOutResponse(drafts: [:], elapsedSeconds: 30)

        XCTAssertFalse(response.autoAnswered)
        XCTAssertTrue(response.timedOut)
    }

    // MARK: - Tool schema

    func testQuestionParsingReadsTheRecommendedFlag() throws {
        let value = Value.object([
            "id": .string("database"),
            "question": .string("Which database should we use?"),
            "options": .array([
                .object(["label": .string("SQLite")]),
                .object(["label": .string("Postgres"), "recommended": .bool(true)])
            ])
        ])

        let question = try MCPAskUserToolProvider.parseAskUserQuestion(value, index: 0)

        XCTAssertEqual(question.options.map(\.isRecommended), [false, true])
        XCTAssertEqual(question.recommendedOption?.label, "Postgres")
    }

    func testQuestionParsingTreatsABareStringOptionAsNotRecommended() throws {
        let value = Value.object([
            "id": .string("database"),
            "question": .string("Which database should we use?"),
            "options": .array([.string("SQLite"), .string("Postgres")])
        ])

        let question = try MCPAskUserToolProvider.parseAskUserQuestion(value, index: 0)

        XCTAssertEqual(question.options.map(\.isRecommended), [false, false])
        XCTAssertEqual(question.recommendedOption?.label, "SQLite")
    }

    // MARK: - Timeout behavior setting

    func testTimeoutBehaviorDefaultsToReturningNoAnswer() {
        XCTAssertEqual(ContextBuilderDefaults.questionTimeoutBehavior, .returnNoAnswer)
        XCTAssertEqual(ContextBuilderDefaults.behaviorSettings.questionTimeoutBehavior, .returnNoAnswer)
    }

    func testTimeoutBehaviorDecodesItsStoredValue() {
        XCTAssertEqual(AskUserTimeoutBehavior(storedValue: "choose_recommended"), .chooseRecommended)
        XCTAssertEqual(AskUserTimeoutBehavior(storedValue: "return_no_answer"), .returnNoAnswer)
    }

    func testTimeoutBehaviorFallsBackToTheDefaultForAnUnknownOrMissingStoredValue() {
        XCTAssertEqual(AskUserTimeoutBehavior(storedValue: nil), ContextBuilderDefaults.questionTimeoutBehavior)
        XCTAssertEqual(AskUserTimeoutBehavior(storedValue: "nonsense"), ContextBuilderDefaults.questionTimeoutBehavior)
    }

    func testReturnNoAnswerLeavesTheExpiredInteractionUnanswered() throws {
        let interaction = interaction(questions: [databaseQuestion])

        let response = AskUserTimeoutBehavior.returnNoAnswer.expiredResponse(
            for: interaction,
            drafts: [:],
            elapsedSeconds: 30
        )

        XCTAssertTrue(response.timedOut)
        XCTAssertFalse(response.autoAnswered)
        let answer = try XCTUnwrap(response.answersByQuestionID["database"])
        XCTAssertTrue(answer.answers.isEmpty)
    }

    func testChooseRecommendedAnswersTheExpiredInteraction() throws {
        let interaction = interaction(questions: [databaseQuestion])

        let response = AskUserTimeoutBehavior.chooseRecommended.expiredResponse(
            for: interaction,
            drafts: [:],
            elapsedSeconds: 30
        )

        XCTAssertFalse(response.timedOut)
        XCTAssertTrue(response.autoAnswered)
        let answer = try XCTUnwrap(response.answersByQuestionID["database"])
        XCTAssertEqual(answer.answers, ["Postgres"])
    }
}
