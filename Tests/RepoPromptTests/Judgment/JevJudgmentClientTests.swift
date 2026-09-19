@testable import RepoPromptApp
import XCTest

/// Covers the request the client sends and the three answer shapes it decodes.
final class JevJudgmentClientTests: XCTestCase {
    private let noulQuestion = JudgmentQuestion(
        id: "authority",
        instructions: "Does this need the user?",
        kind: .noul(trueCriteria: "Yes it does.", falseCriteria: "No it does not.")
    )

    private let scoreQuestion = JudgmentQuestion(
        id: "risk",
        instructions: "How costly is choosing wrong?",
        kind: .score(levels: ["Free", "Wasteful", "Manual undo", "Irreversible"])
    )

    private func client(_ stub: StubHTTPClient) -> JevJudgmentClient {
        JevJudgmentClient(
            httpClient: stub,
            apiKey: "test-key",
            deadlineSeconds: 2,
            maxAttempts: 3,
            backoffSeconds: { _ in 0 }
        )
    }

    private var state: JudgmentState {
        JudgmentState.forTesting(questionIDs: ["authority", "risk"], fields: ["question": .text("Which database?")])
    }

    func testRequestCarriesTheEndpointAuthModelStateAndQuestions() async throws {
        let body = Data("""
        {"model":"jev-1.12","answers":{"authority":{"type":"noul","noul":0.04}},"usage":{"input_tokens":120,"output_tokens":0}}
        """.utf8)
        let stub = StubHTTPClient(responses: [.status(200, body)])

        _ = try await client(stub).judge(state: state, questions: [noulQuestion])

        let request = try XCTUnwrap(stub.recordedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let sent = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "jev-latest")
        XCTAssertEqual((object["state"] as? [String: Any])?["question"] as? String, "Which database?")
        let questions = try XCTUnwrap(object["questions"] as? [String: Any])
        XCTAssertEqual((questions["authority"] as? [String: Any])?["type"] as? String, "noul")
    }

    func testDecodesANoulAnswer() async throws {
        let body = Data("""
        {"model":"jev-1.12","answers":{"authority":{"type":"noul","noul":0.04}},"usage":{"input_tokens":120,"output_tokens":0}}
        """.utf8)

        let result = try await client(StubHTTPClient(responses: [.status(200, body)]))
            .judge(state: state, questions: [noulQuestion])

        XCTAssertEqual(result.modelVersion, "jev-1.12")
        XCTAssertEqual(result.answersByQuestionID["authority"], .noul(probability: 0.04))
        XCTAssertEqual(result.usage.inputTokens, 120)
        XCTAssertEqual(result.usage.outputTokens, 0)
        XCTAssertGreaterThanOrEqual(result.latencySeconds, 0)
    }

    func testDecodesAScoreAnswerWithItsLegendAndConfidence() async throws {
        let body = Data("""
        {"model":"jev-1.12","answers":{"risk":{"type":"score","score":1.4,"legend":{"0":"Free","1":"Wasteful"},
        "probabilities":{"0":0.3,"1":0.7},"confidence":0.68}},"usage":{"input_tokens":210,"output_tokens":0}}
        """.utf8)

        let result = try await client(StubHTTPClient(responses: [.status(200, body)]))
            .judge(state: state, questions: [scoreQuestion])

        XCTAssertEqual(
            result.answersByQuestionID["risk"],
            .score(value: 1.4, legend: ["0": "Free", "1": "Wasteful"], probabilities: ["0": 0.3, "1": 0.7], confidence: 0.68)
        )
    }

    func testDecodesAChoiceAnswer() async throws {
        let choiceQuestion = JudgmentQuestion(
            id: "triage",
            instructions: "What kind of failure is this?",
            kind: .choice(rubricByOption: ["compile": "The compiler rejected a file.", "flake": "It passes on a retry."])
        )
        let body = Data("""
        {"model":"jev-1.12","answers":{"triage":{"type":"choice","choice":"compile",
        "probabilities":{"compile":0.9,"flake":0.1},"confidence":0.88}},"usage":{"input_tokens":90,"output_tokens":0}}
        """.utf8)

        let result = try await client(StubHTTPClient(responses: [.status(200, body)]))
            .judge(state: state, questions: [choiceQuestion])

        XCTAssertEqual(
            result.answersByQuestionID["triage"],
            .choice(option: "compile", probabilities: ["compile": 0.9, "flake": 0.1], confidence: 0.88)
        )
    }

    func testAnswersBothQuestionsOfASingleRequest() async throws {
        let body = Data("""
        {"model":"jev-1.12","answers":{"authority":{"type":"noul","noul":0.04},
        "risk":{"type":"score","score":0.6,"legend":{"0":"Free"},"probabilities":{"0":0.8},"confidence":0.74}},
        "usage":{"input_tokens":260,"output_tokens":0}}
        """.utf8)
        let stub = StubHTTPClient(responses: [.status(200, body)])

        let result = try await client(stub).judge(state: state, questions: [noulQuestion, scoreQuestion])

        XCTAssertEqual(result.answersByQuestionID.count, 2)
        XCTAssertEqual(stub.recordedRequests.count, 1, "Both questions must travel in one request.")
    }
}
