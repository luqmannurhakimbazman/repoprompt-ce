@testable import RepoPromptApp
import XCTest

/// Covers the rule the whole design rests on: a judgment that fails for any reason
/// must return `nil`, so the caller keeps doing exactly what it does today.
final class JudgmentPolicyTests: XCTestCase {
    private var request: JudgmentRequest {
        .askUserExpiry(
            AskUserExpiryJudgmentInput(
                questionText: "Which database should we use?",
                context: nil,
                optionLabels: ["SQLite", "Postgres"],
                optionDescriptions: [],
                recommendedOptionLabel: "Postgres"
            )
        )
    }

    func testAnAvailableJudgeReturnsItsResult() async {
        let policy = JudgmentPolicy(judgeFactory: { StubSystemOneJudge(result: .success(.stub())) })

        let result = await policy.judgment(for: request)

        XCTAssertEqual(result?.modelVersion, "jev-1.12")
    }

    func testNoJudgeMeansNoJudgmentAndNoCall() async {
        // A counter box rather than a captured local: `judgeFactory` is
        // `@escaping @Sendable`, which cannot capture a mutable `var`.
        let counter = CallCounter()
        let policy = JudgmentPolicy(judgeFactory: {
            counter.increment()
            return nil
        })

        let result = await policy.judgment(for: request)

        XCTAssertNil(result)
        XCTAssertEqual(counter.count, 1)
    }

    func testEveryJudgmentErrorBecomesNil() async {
        let errors: [JudgmentError] = [
            .unauthorized,
            .invalidRequest("bad"),
            .rateLimited,
            .overloaded,
            .unexpectedStatus(503),
            .transport("offline"),
            .malformedResponse("nope"),
            .timedOut,
            .missingAnswer(questionID: "ask_user.recommended_option_risk")
        ]

        for error in errors {
            let policy = JudgmentPolicy(judgeFactory: { StubSystemOneJudge(result: .failure(error)) })

            let result = await policy.judgment(for: request)

            XCTAssertNil(result, "\(error) must degrade to nil, not propagate.")
        }
    }

    func testThePolicySendsTheRedactedPlanRatherThanRawInput() async {
        let recorder = RecordingJudge()
        let policy = JudgmentPolicy(judgeFactory: { recorder })

        _ = await policy.judgment(for: request)

        XCTAssertEqual(
            Set(recorder.recordedState?.fields.keys.map(\.self) ?? []),
            ["question", "context", "option_labels", "option_descriptions", "recommended_option"]
        )
        XCTAssertEqual(
            recorder.recordedQuestions?.map(\.id).sorted(),
            [
                "ask_user.needs_human_authority",
                "ask_user.picks_recommended_option",
                "ask_user.recommended_option_risk"
            ],
            "All three travel in one request; the API answers them independently."
        )
    }

    // MARK: - Doubles

    private final class CallCounter: @unchecked Sendable {
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

    private final class RecordingJudge: SystemOneJudging, @unchecked Sendable {
        private(set) var recordedState: JudgmentState?
        private(set) var recordedQuestions: [JudgmentQuestion]?

        func judge(state: JudgmentState, questions: [JudgmentQuestion]) async throws -> JudgmentResult {
            recordedState = state
            recordedQuestions = questions
            return .stub()
        }
    }
}
