@testable import RepoPromptApp
import XCTest

/// Pins the slice 1 invariant: the resolver records and returns the configured behavior
/// unchanged, whatever the judgment says. Slice 2 is the change that relaxes this, and it
/// should have to delete these tests deliberately.
@MainActor
final class AskUserExpiryBehaviorResolverTests: XCTestCase {
    private var interaction: AgentAskUserInteraction {
        AgentAskUserInteraction(
            title: "Question",
            timeoutSeconds: 30,
            questions: [
                AgentAskUserQuestion(
                    id: "database",
                    question: "Which database should we use?",
                    options: [
                        AgentAskUserOption(label: "SQLite"),
                        AgentAskUserOption(label: "Postgres", isRecommended: true)
                    ]
                )
            ]
        )
    }

    private func recorder(result: Result<JudgmentResult, JudgmentError>, lines: LineSink) -> JudgmentShadowRecorder {
        JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: { StubSystemOneJudge(result: result) }),
            isEnabled: { true },
            appendLine: { lines.append($0) }
        )
    }

    func testAConfiguredReturnNoAnswerSurvivesAConfidentSafeJudgment() async {
        let confidentlySafe = JudgmentResult(
            modelVersion: "jev-1.12",
            answersByQuestionID: [
                "ask_user.recommended_option_risk": .score(value: 0, legend: [:], probabilities: [:], confidence: 0.99),
                "ask_user.needs_human_authority": .noul(probability: 0.01)
            ],
            usage: JudgmentUsage(inputTokens: 10, outputTokens: 0),
            latencySeconds: 0.1
        )
        let lines = LineSink()

        let behavior = await AskUserExpiryBehaviorResolver.effectiveBehavior(
            configured: .returnNoAnswer,
            interaction: interaction,
            recorder: recorder(result: .success(confidentlySafe), lines: lines)
        )

        XCTAssertEqual(behavior, .returnNoAnswer, "Slice 1 measures. It must not change what expiry does.")
        XCTAssertEqual(lines.decodedRecords.count, 1, "One record per question in the interaction.")
        XCTAssertEqual(lines.decodedRecords.first?["outcome"] as? String, "expired")
    }

    func testAConfiguredChooseRecommendedSurvivesAJudgmentThatSaysStop() async {
        let clearlyUnsafe = JudgmentResult(
            modelVersion: "jev-1.12",
            answersByQuestionID: [
                "ask_user.recommended_option_risk": .score(value: 3, legend: [:], probabilities: [:], confidence: 0.98),
                "ask_user.needs_human_authority": .noul(probability: 0.97)
            ],
            usage: JudgmentUsage(inputTokens: 10, outputTokens: 0),
            latencySeconds: 0.1
        )
        let lines = LineSink()

        let behavior = await AskUserExpiryBehaviorResolver.effectiveBehavior(
            configured: .chooseRecommended,
            interaction: interaction,
            recorder: recorder(result: .success(clearlyUnsafe), lines: lines)
        )

        XCTAssertEqual(behavior, .chooseRecommended)
        XCTAssertEqual(lines.decodedRecords.count, 1, "One record per question in the interaction.")
    }

    func testAFailedJudgmentStillReturnsTheConfiguredBehavior() async {
        for configured in AskUserTimeoutBehavior.allCases {
            let lines = LineSink()
            let behavior = await AskUserExpiryBehaviorResolver.effectiveBehavior(
                configured: configured,
                interaction: interaction,
                recorder: recorder(result: .failure(.timedOut), lines: lines)
            )

            XCTAssertEqual(behavior, configured)
            XCTAssertEqual(lines.decodedRecords.count, 1, "A failed judgment must still leave a record behind.")
        }
    }

    func testTheExpiredResponseIsIdenticalWithAndWithoutTheResolver() async {
        let lines = LineSink()
        let direct = AskUserTimeoutBehavior.chooseRecommended.expiredResponse(
            for: interaction,
            drafts: [:],
            elapsedSeconds: 30
        )

        let resolved = await AskUserExpiryBehaviorResolver.effectiveBehavior(
            configured: .chooseRecommended,
            interaction: interaction,
            recorder: recorder(result: .failure(.unauthorized), lines: lines)
        ).expiredResponse(for: interaction, drafts: [:], elapsedSeconds: 30)

        XCTAssertEqual(direct.answersByQuestionID, resolved.answersByQuestionID)
        XCTAssertEqual(direct.autoAnswered, resolved.autoAnswered)
        XCTAssertEqual(direct.timedOut, resolved.timedOut)
        XCTAssertEqual(direct.skipped, resolved.skipped)
        XCTAssertEqual(lines.decodedRecords.count, 1, "One record per question in the interaction.")
    }

    // MARK: - The caller has already cancelled itself

    /// Mirrors `JevJudgmentClient`'s cancellation-sensitive awaits (`Task.sleep`,
    /// `URLSession.data(for:)`) without touching the network. `Task.sleep` throws
    /// immediately when it runs inside a task that is already cancelled — the same failure
    /// mode the real client hits when the resolver is called from a cancelled task — so it
    /// stands in for the real client here.
    private struct CancellationSensitiveJudge: SystemOneJudging {
        let result: JudgmentResult

        func judge(state: JudgmentState, questions: [JudgmentQuestion]) async throws -> JudgmentResult {
            try await Task.sleep(nanoseconds: 1)
            return result
        }
    }

    func testARecordStillLandsWhenTheCallingTaskHasAlreadyCancelledItself() async {
        let lines = LineSink()
        let recorder = JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: { CancellationSensitiveJudge(result: .stub()) }),
            isEnabled: { true },
            appendLine: { lines.append($0) }
        )

        // Both expiry sites call `invalidatePendingAskUserTimeout(for: session)` — which
        // cancels `session.askUserTimeoutTask`, the very task this code runs inside — a few
        // lines before calling the resolver. Reproduce that here: cancel the task from
        // inside its own body, before it calls the resolver.
        var handle: Task<Void, Never>!
        handle = Task { @MainActor in
            handle.cancel()
            _ = await AskUserExpiryBehaviorResolver.effectiveBehavior(
                configured: .returnNoAnswer,
                interaction: interaction,
                recorder: recorder
            )
        }
        await handle.value

        XCTAssertEqual(lines.decodedRecords.count, 1)
        XCTAssertEqual(
            lines.decodedRecords.first?["judgment_available"] as? Bool,
            true,
            "The resolver must hop to a task that does not inherit the caller's cancellation, or every expiry judgment silently comes back unavailable."
        )
    }

    // MARK: - Disabled recording

    func testADisabledRecorderSkipsTheWholeRecordingPathAndStillReturnsTheConfiguredBehavior() async {
        let lines = LineSink()
        let judgeRequests = CallCounter()
        let recorder = JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: {
                judgeRequests.increment()
                return StubSystemOneJudge(result: .success(.stub()))
            }),
            isEnabled: { false },
            appendLine: { lines.append($0) }
        )

        let behavior = await AskUserExpiryBehaviorResolver.effectiveBehavior(
            configured: .chooseRecommended,
            interaction: interaction,
            recorder: recorder
        )

        XCTAssertEqual(behavior, .chooseRecommended)
        XCTAssertTrue(lines.appended.isEmpty)
        XCTAssertEqual(judgeRequests.count, 0, "With recording off the resolver must not hop a task or build a judge.")
    }

    // MARK: - Concurrency

    /// Each judgment carries its own 2-second whole-operation deadline and the API answers
    /// the questions of a request independently, so awaiting them one at a time would let
    /// a 10-question expiry delay `continuation.resume` by up to 20 seconds.
    private struct SlowJudge: SystemOneJudging {
        let seconds: Double

        func judge(state: JudgmentState, questions: [JudgmentQuestion]) async throws -> JudgmentResult {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return .stub()
        }
    }

    func testEveryQuestionIsJudgedConcurrentlyRatherThanOneAfterAnother() async {
        let questionCount = 6
        let perJudgmentSeconds = 0.25
        let lines = LineSink()
        let recorder = JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: { SlowJudge(seconds: perJudgmentSeconds) }),
            isEnabled: { true },
            appendLine: { lines.append($0) }
        )
        let many = AgentAskUserInteraction(
            title: "Question",
            timeoutSeconds: 30,
            questions: (0 ..< questionCount).map { index in
                AgentAskUserQuestion(
                    id: "q\(index)",
                    question: "Question \(index)?",
                    options: [AgentAskUserOption(label: "Yes", isRecommended: true)]
                )
            }
        )

        let started = Date()
        let behavior = await AskUserExpiryBehaviorResolver.effectiveBehavior(
            configured: .returnNoAnswer,
            interaction: many,
            recorder: recorder
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(behavior, .returnNoAnswer)
        XCTAssertEqual(lines.decodedRecords.count, questionCount, "Every question still gets its own record.")
        XCTAssertLessThan(
            elapsed,
            perJudgmentSeconds * Double(questionCount) / 2,
            "Serialized judgments would take at least \(perJudgmentSeconds * Double(questionCount)) seconds."
        )
    }

    // MARK: - Doubles

    /// `judgeFactory` is `@escaping @Sendable` and cannot capture a mutable local.
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

    private final class LineSink {
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
