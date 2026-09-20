@testable import RepoPromptApp
import XCTest

/// Covers the failure contract. `JudgmentPolicy` turns all of these into `nil`, so an
/// error mapped to the wrong case shows up as a retry storm or a silent hang, not as a
/// visible bug.
final class JevJudgmentClientErrorTests: XCTestCase {
    private let question = JudgmentQuestion(
        id: "authority",
        instructions: "Does this need the user?",
        kind: .noul(trueCriteria: nil, falseCriteria: nil)
    )

    private var state: JudgmentState {
        JudgmentState.forTesting(questionIDs: ["authority"], fields: ["question": .text("Which database?")])
    }

    private func client(
        _ stub: StubHTTPClient,
        deadlineSeconds: Double = 2,
        maxAttempts: Int = 3
    ) -> JevJudgmentClient {
        JevJudgmentClient(
            httpClient: stub,
            apiKey: "test-key",
            deadlineSeconds: deadlineSeconds,
            maxAttempts: maxAttempts,
            backoffSeconds: { _ in 0 }
        )
    }

    private func judgmentError(
        from stub: StubHTTPClient,
        deadlineSeconds: Double = 2,
        maxAttempts: Int = 3
    ) async -> JudgmentError? {
        do {
            _ = try await client(stub, deadlineSeconds: deadlineSeconds, maxAttempts: maxAttempts)
                .judge(state: state, questions: [question])
            return nil
        } catch let error as JudgmentError {
            return error
        } catch {
            return nil
        }
    }

    private var okBody: Data {
        Data("""
        {"model":"jev-1.12","answers":{"authority":{"type":"noul","noul":0.04}},"usage":{"input_tokens":1,"output_tokens":0}}
        """.utf8)
    }

    // MARK: - Status mapping

    func testUnauthorizedIsNotRetried() async {
        let stub = StubHTTPClient(responses: [.status(401, Data()), .status(200, okBody)])

        let error = await judgmentError(from: stub)

        XCTAssertEqual(error, .unauthorized)
        XCTAssertEqual(stub.recordedRequests.count, 1, "A bad key must not be retried.")
    }

    func testValidationFailureIsNotRetriedAndKeepsTheServerMessage() async {
        let stub = StubHTTPClient(responses: [.status(422, Data(#"{"error":"criteria must have 2 levels"}"#.utf8))])

        let error = await judgmentError(from: stub)

        guard case let .invalidRequest(message) = error else {
            return XCTFail("expected invalidRequest, got \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("criteria must have 2 levels"))
        XCTAssertEqual(stub.recordedRequests.count, 1)
    }

    func testALongValidationMessageIsTruncatedWithoutBeingLost() async {
        // 600 three-byte characters: truncating the `Data` at 512 bytes would split the
        // 171st character's UTF-8 sequence and decode to nothing, discarding the server's
        // only account of why it rejected the request.
        let body = Data(String(repeating: "€", count: 600).utf8)
        XCTAssertNil(String(data: body.prefix(512), encoding: .utf8), "The cut must actually split a sequence.")
        let stub = StubHTTPClient(responses: [.status(422, body)])

        guard case let .invalidRequest(message) = await judgmentError(from: stub) else {
            return XCTFail("expected invalidRequest")
        }
        XCTAssertEqual(message.count, 512, "The message is shortened by characters, not bytes.")
        XCTAssertTrue(message.hasPrefix("€€"))
    }

    // MARK: - Redaction allow-list

    func testAStateRedactedForOtherQuestionsIsRejectedBeforeAnyRequest() async {
        let stub = StubHTTPClient(responses: [.status(200, okBody)])
        let mismatched = JudgmentState.forTesting(
            questionIDs: ["something.else"],
            fields: ["question": .text("Which database?")]
        )

        do {
            _ = try await client(stub).judge(state: mismatched, questions: [question])
            XCTFail("expected invalidRequest")
        } catch let error as JudgmentError {
            guard case let .invalidRequest(message) = error else {
                return XCTFail("expected invalidRequest, got \(error)")
            }
            XCTAssertTrue(message.contains("authority"), "The message must name the undeclared question.")
        } catch {
            XCTFail("expected JudgmentError")
        }
        XCTAssertTrue(stub.recordedRequests.isEmpty, "Nothing may leave the machine on a payload the redactor did not build.")
    }

    func testAStateRedactedForTheAskedQuestionsIsAccepted() async throws {
        let stub = StubHTTPClient(responses: [.status(200, okBody)])
        let generous = JudgmentState.forTesting(
            questionIDs: ["authority", "unused.extra"],
            fields: ["question": .text("Which database?")]
        )

        _ = try await client(stub).judge(state: generous, questions: [question])

        XCTAssertEqual(stub.recordedRequests.count, 1, "A superset of the asked questions is fine; a missing one is not.")
    }

    func testAnUndocumentedStatusIsReportedAsItself() async {
        let stub = StubHTTPClient(responses: [.status(503, Data())])

        let error = await judgmentError(from: stub)

        XCTAssertEqual(error, .unexpectedStatus(503))
        XCTAssertEqual(stub.recordedRequests.count, 1)
    }

    func testTransportFailureIsWrapped() async {
        let stub = StubHTTPClient(responses: [.failure(URLError(.notConnectedToInternet))])

        guard case .transport = await judgmentError(from: stub) else {
            return XCTFail("expected transport error")
        }
    }

    // MARK: - Retry

    func testRateLimitIsRetriedAndThenSucceeds() async throws {
        let stub = StubHTTPClient(responses: [.status(429, Data()), .status(200, okBody)])

        let result = try await client(stub).judge(state: state, questions: [question])

        XCTAssertEqual(result.answersByQuestionID["authority"], .noul(probability: 0.04))
        XCTAssertEqual(stub.recordedRequests.count, 2)
    }

    func testOverloadIsRetriedAndThenSucceeds() async throws {
        let stub = StubHTTPClient(responses: [.status(529, Data()), .status(200, okBody)])

        _ = try await client(stub).judge(state: state, questions: [question])

        XCTAssertEqual(stub.recordedRequests.count, 2)
    }

    func testRetriesStopAtTheAttemptLimit() async {
        let stub = StubHTTPClient(responses: [.status(429, Data()), .status(429, Data()), .status(429, Data()), .status(200, okBody)])

        let error = await judgmentError(from: stub, maxAttempts: 3)

        XCTAssertEqual(error, .rateLimited)
        XCTAssertEqual(stub.recordedRequests.count, 3)
    }

    // MARK: - Deadline

    func testASlowCallIsAbandonedAtTheDeadline() async {
        let stub = StubHTTPClient(responses: [.slow(seconds: 5, status: 200, body: okBody)])

        let started = Date()
        let error = await judgmentError(from: stub, deadlineSeconds: 0.3)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(error, .timedOut)
        XCTAssertLessThan(elapsed, 2, "The deadline must abandon the call, not wait for the session timeout.")
    }

    // MARK: - Malformed responses

    func testAResponseThatIsNotJSONIsMalformed() async {
        let stub = StubHTTPClient(responses: [.status(200, Data("not json".utf8))])

        guard case .malformedResponse = await judgmentError(from: stub) else {
            return XCTFail("expected malformedResponse")
        }
    }

    func testAMissingQuestionIsReportedByID() async {
        let stub = StubHTTPClient(responses: [.status(200, Data(#"{"model":"jev-1.12","answers":{},"usage":{}}"#.utf8))])

        let error = await judgmentError(from: stub)

        XCTAssertEqual(error, .missingAnswer(questionID: "authority"))
    }

    func testAnAnswerOfTheWrongTypeIsMalformed() async {
        // The fixture carries a valid `noul` value on purpose. Without it, the wrong-type
        // body would also fail the missing-field guard, and this test would keep passing
        // even if `requireType` were deleted — which is the guard it exists to pin.
        let body = Data("""
        {"model":"jev-1.12","answers":{"authority":{"type":"choice","choice":"yes","noul":0.5}},"usage":{}}
        """.utf8)
        let stub = StubHTTPClient(responses: [.status(200, body)])

        guard case let .malformedResponse(message) = await judgmentError(from: stub) else {
            return XCTFail("expected malformedResponse")
        }
        XCTAssertTrue(message.contains("authority"))
    }

    func testEmptyQuestionsAreRejectedBeforeAnyRequest() async {
        let stub = StubHTTPClient(responses: [.status(200, okBody)])

        do {
            _ = try await client(stub).judge(state: state, questions: [])
            XCTFail("expected invalidRequest")
        } catch let error as JudgmentError {
            guard case .invalidRequest = error else {
                return XCTFail("expected invalidRequest, got \(error)")
            }
        } catch {
            XCTFail("expected JudgmentError")
        }
        XCTAssertTrue(stub.recordedRequests.isEmpty)
    }
}
