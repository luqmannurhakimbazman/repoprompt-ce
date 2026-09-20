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

    private var choiceQuestion: JudgmentQuestion {
        JudgmentQuestion(
            id: "triage",
            instructions: "What kind of failure is this?",
            kind: .choice(rubricByOption: ["compile": "The compiler rejected a file."])
        )
    }

    private var scoreQuestion: JudgmentQuestion {
        JudgmentQuestion(
            id: "risk",
            instructions: "How costly is choosing wrong?",
            kind: .score(levels: ["Free", "Wasteful"])
        )
    }

    /// Sends one body against arbitrary questions, with a state declared for exactly them.
    private func judgmentError(
        from stub: StubHTTPClient,
        questions: [JudgmentQuestion]
    ) async -> JudgmentError? {
        let declared = JudgmentState.forTesting(
            questionIDs: questions.map(\.id),
            fields: ["question": .text("Which database?")]
        )
        do {
            _ = try await client(stub).judge(state: declared, questions: questions)
            return nil
        } catch let error as JudgmentError {
            return error
        } catch {
            return nil
        }
    }

    private func expectMalformed(
        _ error: JudgmentError?,
        mentioning fragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .malformedResponse(message) = error else {
            return XCTFail("expected malformedResponse, got \(String(describing: error))", file: file, line: line)
        }
        for fragment in fragments {
            XCTAssertTrue(
                message.contains(fragment),
                "message '\(message)' must name '\(fragment)'",
                file: file,
                line: line
            )
        }
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

    func testAValidationFailureReportedAs400KeepsTheServerMessage() async {
        // The live service answers a malformed request with 400, not the documented 422:
        // an unknown model and an over-long score rubric both came back 400. Mapping it to
        // `unexpectedStatus` would keep the number and discard the only account of what was
        // wrong, and the recorder writes no error reason of its own.
        let body = Data(#"{"detail":"Too many score levels. Must have at most 10 levels."}"#.utf8)
        let stub = StubHTTPClient(responses: [.status(400, body)])

        let error = await judgmentError(from: stub)

        guard case let .invalidRequest(message) = error else {
            return XCTFail("expected invalidRequest, got \(String(describing: error))")
        }
        XCTAssertTrue(message.contains("Too many score levels"))
        XCTAssertEqual(stub.recordedRequests.count, 1, "A malformed request must not be retried.")
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

    // MARK: - Required response fields

    //
    // The vendor documents `confidence` and `probabilities` as required on choice and score
    // answers, and `legend` as required on score. Defaulting them locally would turn a
    // contract violation into a genuine-looking judgment — `confidence 0` lands outside the
    // calibration band instead of being discarded, which shrinks the sample with nothing
    // recording that it happened. A missing required field is a malformed response.

    func testAChoiceAnswerWithoutConfidenceIsMalformed() async {
        let body = Data("""
        {"model":"jev-1.12","answers":{"triage":{"type":"choice","choice":"compile",
        "probabilities":{"compile":1.0}}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)

        let error = await judgmentError(from: StubHTTPClient(responses: [.status(200, body)]), questions: [choiceQuestion])

        expectMalformed(error, mentioning: ["triage", "confidence"])
    }

    func testAChoiceAnswerWithoutProbabilitiesIsMalformed() async {
        let body = Data("""
        {"model":"jev-1.12","answers":{"triage":{"type":"choice","choice":"compile","confidence":0.9}},
        "usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)

        let error = await judgmentError(from: StubHTTPClient(responses: [.status(200, body)]), questions: [choiceQuestion])

        expectMalformed(error, mentioning: ["triage", "probabilities"])
    }

    func testAScoreAnswerWithoutConfidenceIsMalformed() async {
        let body = Data("""
        {"model":"jev-1.12","answers":{"risk":{"type":"score","score":1.4,"legend":{"0":"Free"},
        "probabilities":{"0":1.0}}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)

        let error = await judgmentError(from: StubHTTPClient(responses: [.status(200, body)]), questions: [scoreQuestion])

        expectMalformed(error, mentioning: ["risk", "confidence"])
    }

    func testAScoreAnswerWithoutALegendIsMalformed() async {
        // Without the legend nothing in a recorded row says which probability key is which
        // rubric level, so the calibration gate that sums the two highest-risk levels has to
        // assume an index convention instead of reading one.
        let body = Data("""
        {"model":"jev-1.12","answers":{"risk":{"type":"score","score":1.4,
        "probabilities":{"0":1.0},"confidence":0.7}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)

        let error = await judgmentError(from: StubHTTPClient(responses: [.status(200, body)]), questions: [scoreQuestion])

        expectMalformed(error, mentioning: ["risk", "legend"])
    }

    func testAScoreAnswerWithoutProbabilitiesIsMalformed() async {
        let body = Data("""
        {"model":"jev-1.12","answers":{"risk":{"type":"score","score":1.4,"legend":{"0":"Free"},
        "confidence":0.7}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)

        let error = await judgmentError(from: StubHTTPClient(responses: [.status(200, body)]), questions: [scoreQuestion])

        expectMalformed(error, mentioning: ["risk", "probabilities"])
    }

    func testAProbabilityMapWithANonNumericEntryIsMalformed() async {
        // Dropping the bad entry and keeping the rest would silently renormalize the
        // distribution the risk gate is computed from.
        let body = Data("""
        {"model":"jev-1.12","answers":{"triage":{"type":"choice","choice":"compile",
        "probabilities":{"compile":0.9,"flake":"nope"},"confidence":0.9}},
        "usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)

        let error = await judgmentError(from: StubHTTPClient(responses: [.status(200, body)]), questions: [choiceQuestion])

        expectMalformed(error, mentioning: ["triage", "probabilities"])
    }

    func testABooleanConfidenceIsMalformed() async {
        // `true` bridges to NSNumber, so `as? Double` would read it as 1.0 — maximum
        // confidence invented out of a type error.
        let body = Data("""
        {"model":"jev-1.12","answers":{"triage":{"type":"choice","choice":"compile",
        "probabilities":{"compile":1.0},"confidence":true}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)

        let error = await judgmentError(from: StubHTTPClient(responses: [.status(200, body)]), questions: [choiceQuestion])

        expectMalformed(error, mentioning: ["triage", "confidence"])
    }

    func testABooleanNoulProbabilityIsMalformed() async {
        // Same coercion as the boolean confidence above, on the field a `noul` answer is
        // entirely made of.
        let body = Data("""
        {"model":"jev-1.12","answers":{"authority":{"type":"noul","noul":true}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)

        await expectMalformed(judgmentError(from: StubHTTPClient(responses: [.status(200, body)])), mentioning: ["authority", "noul"])
    }

    func testAResponseWithoutAModelIsMalformed() async {
        // `model_version` is how the calibration sample is partitioned: pooling records from
        // two model versions under an empty string would merge samples that must not merge.
        let body = Data("""
        {"answers":{"authority":{"type":"noul","noul":0.04}},"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)

        await expectMalformed(judgmentError(from: StubHTTPClient(responses: [.status(200, body)])), mentioning: ["model"])
    }

    func testAResponseWithoutOutputTokensIsMalformed() async {
        let body = Data("""
        {"model":"jev-1.12","answers":{"authority":{"type":"noul","noul":0.04}},"usage":{"input_tokens":1}}
        """.utf8)

        await expectMalformed(judgmentError(from: StubHTTPClient(responses: [.status(200, body)])), mentioning: ["output_tokens"])
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
