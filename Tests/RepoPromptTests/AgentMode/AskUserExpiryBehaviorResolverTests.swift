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

    private func recorder(result: Result<JudgmentResult, JudgmentError>) -> JudgmentShadowRecorder {
        JudgmentShadowRecorder(
            policy: JudgmentPolicy(judgeFactory: { StubSystemOneJudge(result: result) }),
            isEnabled: { true },
            appendLine: { _ in }
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

        let behavior = await AskUserExpiryBehaviorResolver.effectiveBehavior(
            configured: .returnNoAnswer,
            interaction: interaction,
            recorder: recorder(result: .success(confidentlySafe))
        )

        XCTAssertEqual(behavior, .returnNoAnswer, "Slice 1 measures. It must not change what expiry does.")
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

        let behavior = await AskUserExpiryBehaviorResolver.effectiveBehavior(
            configured: .chooseRecommended,
            interaction: interaction,
            recorder: recorder(result: .success(clearlyUnsafe))
        )

        XCTAssertEqual(behavior, .chooseRecommended)
    }

    func testAFailedJudgmentStillReturnsTheConfiguredBehavior() async {
        for configured in AskUserTimeoutBehavior.allCases {
            let behavior = await AskUserExpiryBehaviorResolver.effectiveBehavior(
                configured: configured,
                interaction: interaction,
                recorder: recorder(result: .failure(.timedOut))
            )

            XCTAssertEqual(behavior, configured)
        }
    }

    func testTheExpiredResponseIsIdenticalWithAndWithoutTheResolver() async {
        let direct = AskUserTimeoutBehavior.chooseRecommended.expiredResponse(
            for: interaction,
            drafts: [:],
            elapsedSeconds: 30
        )

        let resolved = await AskUserExpiryBehaviorResolver.effectiveBehavior(
            configured: .chooseRecommended,
            interaction: interaction,
            recorder: recorder(result: .failure(.unauthorized))
        ).expiredResponse(for: interaction, drafts: [:], elapsedSeconds: 30)

        XCTAssertEqual(direct.answersByQuestionID, resolved.answersByQuestionID)
        XCTAssertEqual(direct.autoAnswered, resolved.autoAnswered)
        XCTAssertEqual(direct.timedOut, resolved.timedOut)
        XCTAssertEqual(direct.skipped, resolved.skipped)
    }
}
