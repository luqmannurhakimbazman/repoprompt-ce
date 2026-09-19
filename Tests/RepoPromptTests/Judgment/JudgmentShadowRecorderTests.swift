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

    private func recorder(
        enabled: Bool,
        result: JudgmentResult?,
        lines: LineSink
    ) -> JudgmentShadowRecorder {
        JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: {
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
        let recorder = recorder(enabled: false, result: judgedResult, lines: lines)

        await recorder.record(interactionID: UUID(), question: question, outcome: .skipped)

        XCTAssertTrue(lines.appended.isEmpty)
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
}
