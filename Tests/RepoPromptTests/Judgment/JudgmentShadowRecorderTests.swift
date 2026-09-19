@testable import RepoPromptApp
import XCTest

/// Covers what a shadow record contains and that a disabled recorder does nothing at all.
@MainActor
final class JudgmentShadowRecorderTests: XCTestCase {
    private var question: AgentAskUserQuestion {
        AgentAskUserQuestion(
            id: "database",
            question: "Which database should we use?",
            options: [
                AgentAskUserOption(label: "SQLite"),
                AgentAskUserOption(label: "Postgres", description: "Server", isRecommended: true)
            ]
        )
    }

    private var secondQuestion: AgentAskUserQuestion {
        AgentAskUserQuestion(
            id: "cache",
            question: "Which cache should we use?",
            options: [AgentAskUserOption(label: "Redis")]
        )
    }

    private func recorder(
        enabled: Bool,
        result: JudgmentResult?,
        lines: LineSink,
        judgeRequests: Counter = Counter()
    ) -> JudgmentShadowRecorder {
        JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: {
                judgeRequests.increment()
                guard let result else { return nil }
                return StubSystemOneJudge(result: .success(result))
            }),
            isEnabled: { enabled },
            appendLine: { lines.append($0) }
        )
    }

    private var judgedResult: JudgmentResult {
        JudgmentResult(
            modelVersion: "jev-1.12",
            answersByQuestionID: [
                "ask_user.recommended_option_risk": .score(
                    value: 0.6,
                    legend: ["0": "Free"],
                    probabilities: ["0": 0.8, "1": 0.2],
                    confidence: 0.74
                ),
                "ask_user.needs_human_authority": .noul(probability: 0.08)
            ],
            usage: JudgmentUsage(inputTokens: 260, outputTokens: 0),
            latencySeconds: 0.11
        )
    }

    func testARecordCarriesTheOutcomeJudgmentAndModelVersion() async throws {
        let lines = LineSink()
        let recorder = recorder(enabled: true, result: judgedResult, lines: lines)

        await recorder.record(
            interactionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
            question: question,
            outcome: .answered(pickedRecommended: true)
        )

        let record = try XCTUnwrap(lines.decodedRecords.first)
        XCTAssertEqual(record["outcome"] as? String, "answered")
        XCTAssertEqual(record["picked_recommended"] as? Bool, true)
        XCTAssertEqual(record["model_version"] as? String, "jev-1.12")
        XCTAssertEqual(record["question_id"] as? String, "database")
        XCTAssertEqual(record["input_tokens"] as? Int, 260)
        let answers = try XCTUnwrap(record["answers"] as? [String: Any])
        let risk = try XCTUnwrap(answers["ask_user.recommended_option_risk"] as? [String: Any])
        XCTAssertEqual(risk["kind"] as? String, "score")
        XCTAssertEqual(risk["value"] as? Double, 0.6)
        XCTAssertEqual(risk["confidence"] as? Double, 0.74)
        let authority = try XCTUnwrap(answers["ask_user.needs_human_authority"] as? [String: Any])
        XCTAssertEqual(authority["probability"] as? Double, 0.08)
        XCTAssertNil(authority["confidence"], "A noul answer reports no confidence.")
    }

    func testAnExpiredOutcomeNamesTheBehaviorThatResolvedIt() async throws {
        let lines = LineSink()
        let recorder = recorder(enabled: true, result: judgedResult, lines: lines)

        await recorder.record(
            interactionID: UUID(),
            question: question,
            outcome: .expired(behavior: AskUserTimeoutBehavior.returnNoAnswer.rawValue)
        )

        let record = try XCTUnwrap(lines.decodedRecords.first)
        XCTAssertEqual(record["outcome"] as? String, "expired")
        XCTAssertEqual(record["expiry_behavior"] as? String, "return_no_answer")
    }

    func testADisabledRecorderWritesNothing() async {
        let lines = LineSink()
        let judgeRequests = Counter()
        let recorder = recorder(enabled: false, result: judgedResult, lines: lines, judgeRequests: judgeRequests)

        await recorder.record(interactionID: UUID(), question: question, outcome: .skipped)

        XCTAssertTrue(lines.appended.isEmpty)
        XCTAssertEqual(judgeRequests.count, 0, "A disabled recorder must not even build a judge.")
    }

    func testAnUnavailableJudgmentStillRecordsTheOutcome() async throws {
        let lines = LineSink()
        let recorder = recorder(enabled: true, result: nil, lines: lines)

        await recorder.record(interactionID: UUID(), question: question, outcome: .skipped)

        let record = try XCTUnwrap(lines.decodedRecords.first)
        XCTAssertEqual(record["outcome"] as? String, "skipped")
        XCTAssertEqual(record["judgment_available"] as? Bool, false)
        XCTAssertNil(record["answers"])
    }

    func testTheJudgedInputCarriesTheQuestionAndItsOptions() {
        let input = JudgmentShadowRecorder.input(for: question)

        XCTAssertEqual(input.questionText, "Which database should we use?")
        XCTAssertEqual(input.optionLabels, ["SQLite", "Postgres"])
        XCTAssertEqual(input.optionDescriptions, ["Server"])
        XCTAssertEqual(input.recommendedOptionLabel, "Postgres")
    }

    func testTheFanOutOverloadRecordsEveryQuestion() async {
        let lines = LineSink()
        let result = judgedResult
        let recorded = expectation(description: "records every question")
        recorded.expectedFulfillmentCount = 2
        let recorder = JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: { StubSystemOneJudge(result: .success(result)) }),
            isEnabled: { true },
            appendLine: { line in
                lines.append(line)
                recorded.fulfill()
            }
        )

        recorder.record(interactionID: UUID(), questions: [question, secondQuestion], outcome: .skipped)
        await fulfillment(of: [recorded], timeout: 5)

        XCTAssertEqual(
            Set(lines.decodedRecords.compactMap { $0["question_id"] as? String }),
            ["database", "cache"]
        )
        withExtendedLifetime(recorder) {}
    }

    func testADisabledFanOutRecordsNothing() async {
        let lines = LineSink()
        let result = judgedResult
        let judgeRequests = Counter()
        let recorder = JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: {
                judgeRequests.increment()
                return StubSystemOneJudge(result: .success(result))
            }),
            isEnabled: { false },
            appendLine: { lines.append($0) }
        )

        recorder.record(interactionID: UUID(), questions: [question, secondQuestion], outcome: .skipped)
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(lines.appended.isEmpty)
        XCTAssertEqual(judgeRequests.count, 0, "A disabled fan-out must not even build a judge.")
        withExtendedLifetime(recorder) {}
    }

    // MARK: - AskUserShadowOutcome.pickedRecommended

    func testPickedRecommendedIsTrueWhenEveryRecommendationBearingQuestionMatchesIt() {
        let picked = AskUserShadowOutcome.pickedRecommended(
            for: [question, secondQuestion],
            draftsByQuestionID: [
                "database": AgentAskUserDraft(selectedOptionLabels: ["Postgres"]),
                "cache": AgentAskUserDraft(selectedOptionLabels: ["Redis"])
            ]
        )

        XCTAssertEqual(picked, true)
    }

    func testPickedRecommendedIsNilWhenNoQuestionHasARecommendation() {
        let noOptions = AgentAskUserQuestion(id: "notes", question: "Any extra constraints?", allowsCustom: true)

        let picked = AskUserShadowOutcome.pickedRecommended(for: [noOptions], draftsByQuestionID: [:])

        XCTAssertNil(picked, "There is no recommendation to compare against, so the record should say nothing.")
    }

    func testPickedRecommendedIgnoresAQuestionWithNoOptionsRatherThanFailingTheWholeInteraction() {
        let noOptions = AgentAskUserQuestion(id: "notes", question: "Any extra constraints?", allowsCustom: true)

        let picked = AskUserShadowOutcome.pickedRecommended(
            for: [question, noOptions],
            draftsByQuestionID: ["database": AgentAskUserDraft(selectedOptionLabels: ["Postgres"])]
        )

        XCTAssertEqual(
            picked,
            true,
            "A question with no options has no recommendation and must not drag a matching interaction to false."
        )
    }

    func testPickedRecommendedReadsTheTransmittedAnswerNotTheStaleSelectionOnACustomOverride() {
        // Single-select: choosing an option and then typing custom text means the custom
        // text is what gets transmitted (see `AgentAskUserQuestion.answer(from:)`), not the
        // leftover selection.
        let draft = AgentAskUserDraft(selectedOptionLabels: ["Postgres"], customResponse: "MySQL")

        let picked = AskUserShadowOutcome.pickedRecommended(for: [question], draftsByQuestionID: ["database": draft])

        XCTAssertEqual(
            picked,
            false,
            "The transmitted answer was the custom text, not the recommended option, however the draft looks."
        )
    }

    func testPickedRecommendedReadsTheTransmittedAnswerNotTheStaleSelectionOnASkip() {
        let draft = AgentAskUserDraft(selectedOptionLabels: ["Postgres"], skipped: true)

        let picked = AskUserShadowOutcome.pickedRecommended(for: [question], draftsByQuestionID: ["database": draft])

        XCTAssertEqual(
            picked,
            false,
            "A skipped question transmits no answer, whatever selection is still sitting in the draft."
        )
    }

    // MARK: - Doubles

    final class LineSink {
        private(set) var appended: [String] = []

        func append(_ line: String) {
            appended.append(line)
        }

        var decodedRecords: [[String: Any]] {
            appended.compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        }
    }

    /// A lock-backed counter: `judgeFactory` is `@escaping @Sendable` and cannot capture
    /// a mutable local. Mirrors `CallCounter` in `JudgmentPolicyTests`.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
