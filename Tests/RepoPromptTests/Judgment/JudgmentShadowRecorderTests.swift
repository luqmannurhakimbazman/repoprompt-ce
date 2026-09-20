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
        XCTAssertEqual(record["recommended_option_is_flagged"] as? Bool, true)
        XCTAssertEqual(
            record["catalogue_version"] as? String,
            JudgmentQuestionCatalogue.version,
            "Every row must name the rubric that produced it, or a revision is invisible in the data."
        )
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
        XCTAssertEqual(
            input.optionDescriptions,
            ["", "Server"],
            "Descriptions are positional. Compacting them would hand Postgres's description to SQLite."
        )
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

    func testPickedRecommendedIsTrueWhenTheQuestionsOwnAnswerMatchesItsRecommendation() {
        let picked = AskUserShadowOutcome.pickedRecommended(
            for: question,
            draft: AgentAskUserDraft(selectedOptionLabels: ["Postgres"])
        )

        XCTAssertEqual(picked, true)
    }

    func testPickedRecommendedIsNilWhenTheQuestionHasNoRecommendation() {
        let noOptions = AgentAskUserQuestion(id: "notes", question: "Any extra constraints?", allowsCustom: true)

        let picked = AskUserShadowOutcome.pickedRecommended(for: noOptions, draft: nil)

        XCTAssertNil(picked, "There is no recommendation to compare against, so the record should say nothing.")
    }

    func testPickedRecommendedReadsTheTransmittedAnswerNotTheStaleSelectionOnACustomOverride() {
        // Single-select: choosing an option and then typing custom text means the custom
        // text is what gets transmitted (see `AgentAskUserQuestion.answer(from:)`), not the
        // leftover selection.
        let draft = AgentAskUserDraft(selectedOptionLabels: ["Postgres"], customResponse: "MySQL")

        let picked = AskUserShadowOutcome.pickedRecommended(for: question, draft: draft)

        XCTAssertEqual(
            picked,
            false,
            "The transmitted answer was the custom text, not the recommended option, however the draft looks."
        )
    }

    func testPickedRecommendedReadsTheTransmittedAnswerNotTheStaleSelectionOnASkip() {
        let draft = AgentAskUserDraft(selectedOptionLabels: ["Postgres"], skipped: true)

        let picked = AskUserShadowOutcome.pickedRecommended(for: question, draft: draft)

        XCTAssertEqual(
            picked,
            false,
            "A skipped question transmits no answer, whatever selection is still sitting in the draft."
        )
    }

    // MARK: - The answered funnel

    /// `ask_user` accepts up to 10 questions and every row carries a judgment about one of
    /// them. An interaction-level label stamped on every row would let one custom answer
    /// drag every sibling row to `false` and depress gate 1 for reasons unrelated to
    /// calibration, so each row must be labelled from its own question's draft.
    func testTheAnsweredFunnelLabelsEachRowFromItsOwnQuestion() async {
        let lines = LineSink()
        let recorded = expectation(description: "records every question")
        recorded.expectedFulfillmentCount = 2
        let result = judgedResult
        let recorder = JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: { StubSystemOneJudge(result: .success(result)) }),
            isEnabled: { true },
            appendLine: { line in
                lines.append(line)
                recorded.fulfill()
            }
        )
        let interaction = AgentAskUserInteraction(
            title: "Question",
            timeoutSeconds: 30,
            questions: [question, secondQuestion]
        )

        recorder.recordResolved(
            interaction: interaction,
            draftsByQuestionID: [
                // The user took the recommendation on one question and typed their own
                // answer on the other.
                "database": AgentAskUserDraft(selectedOptionLabels: ["Postgres"]),
                "cache": AgentAskUserDraft(customResponse: "Memcached")
            ],
            skipAll: false
        )
        await fulfillment(of: [recorded], timeout: 5)

        let byQuestion = Dictionary(
            uniqueKeysWithValues: lines.decodedRecords.compactMap { record -> (String, [String: Any])? in
                guard let id = record["question_id"] as? String else { return nil }
                return (id, record)
            }
        )
        XCTAssertEqual(Set(byQuestion.keys), ["database", "cache"], "One row per question.")
        XCTAssertEqual(byQuestion["database"]?["outcome"] as? String, "answered")
        XCTAssertEqual(
            byQuestion["database"]?["picked_recommended"] as? Bool,
            true,
            "The answered question kept its own true label despite its sibling disagreeing."
        )
        XCTAssertEqual(byQuestion["cache"]?["picked_recommended"] as? Bool, false)
        withExtendedLifetime(recorder) {}
    }

    func testTheAnsweredFunnelOmitsTheLabelOnAQuestionWithNoRecommendation() async throws {
        let lines = LineSink()
        let recorded = expectation(description: "records the question")
        let result = judgedResult
        let recorder = JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: { StubSystemOneJudge(result: .success(result)) }),
            isEnabled: { true },
            appendLine: { line in
                lines.append(line)
                recorded.fulfill()
            }
        )
        let noOptions = AgentAskUserQuestion(id: "notes", question: "Any extra constraints?", allowsCustom: true)
        let interaction = AgentAskUserInteraction(title: "Question", timeoutSeconds: 30, questions: [noOptions])

        recorder.recordResolved(
            interaction: interaction,
            draftsByQuestionID: ["notes": AgentAskUserDraft(customResponse: "None")],
            skipAll: false
        )
        await fulfillment(of: [recorded], timeout: 5)

        let record = try XCTUnwrap(lines.decodedRecords.first)
        XCTAssertEqual(record["outcome"] as? String, "answered")
        XCTAssertNil(record["picked_recommended"], "No recommendation means no comparison to report.")
        XCTAssertEqual(record["recommended_option_is_flagged"] as? Bool, false)
        withExtendedLifetime(recorder) {}
    }

    func testTheAnsweredFunnelRecordsASkipAllAsSkipped() async {
        let lines = LineSink()
        let recorded = expectation(description: "records every question")
        recorded.expectedFulfillmentCount = 2
        let result = judgedResult
        let recorder = JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: { StubSystemOneJudge(result: .success(result)) }),
            isEnabled: { true },
            appendLine: { line in
                lines.append(line)
                recorded.fulfill()
            }
        )
        let interaction = AgentAskUserInteraction(
            title: "Question",
            timeoutSeconds: 30,
            questions: [question, secondQuestion]
        )

        recorder.recordResolved(
            interaction: interaction,
            draftsByQuestionID: ["database": AgentAskUserDraft(selectedOptionLabels: ["Postgres"])],
            skipAll: true
        )
        await fulfillment(of: [recorded], timeout: 5)

        XCTAssertEqual(lines.decodedRecords.count, 2)
        XCTAssertTrue(lines.decodedRecords.allSatisfy { $0["outcome"] as? String == "skipped" })
        XCTAssertTrue(
            lines.decodedRecords.allSatisfy { $0["picked_recommended"] == nil },
            "A skip-all transmits no answer, so no row may claim the person picked anything."
        )
        withExtendedLifetime(recorder) {}
    }

    // MARK: - Serialization

    func testAnUnserializableJudgmentStillLeavesTheOutcomeRowBehind() async throws {
        let lines = LineSink()
        // `Double.nan` is not representable in JSON, so the first serialization attempt
        // fails. The human label is the one field nobody can reconstruct later, so the row
        // must survive without the judgment rather than disappearing with it.
        let unserializable = JudgmentResult(
            modelVersion: "jev-1.12",
            answersByQuestionID: ["ask_user.needs_human_authority": .noul(probability: .nan)],
            usage: JudgmentUsage(inputTokens: 1, outputTokens: 0),
            latencySeconds: 0.1
        )
        let recorder = recorder(enabled: true, result: unserializable, lines: lines)

        await recorder.record(
            interactionID: UUID(),
            question: question,
            outcome: .answered(pickedRecommended: false)
        )

        let record = try XCTUnwrap(lines.decodedRecords.first)
        XCTAssertEqual(record["picked_recommended"] as? Bool, false)
        XCTAssertEqual(record["judgment_available"] as? Bool, true)
        XCTAssertEqual(record["answers_dropped"] as? Bool, true)
        XCTAssertNil(record["answers"])
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
