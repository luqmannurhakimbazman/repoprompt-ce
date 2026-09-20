import Foundation

/// The only `SystemOneJudging` conformance that makes network calls.
///
/// It enforces its own whole-operation deadline rather than relying on the URLSession
/// timeout, because a judgment is worthless once the caller has fallen back.
struct JevJudgmentClient: SystemOneJudging {
    static let defaultEndpointURLString = "https://api.typesafe.ai/v1/systemone"
    static let defaultModelIdentifier = "jev-latest"

    private let httpClient: any HTTPClient
    private let apiKey: String
    private let endpointURLString: String
    private let modelIdentifier: String
    private let deadlineSeconds: Double
    private let maxAttempts: Int
    private let backoffSeconds: @Sendable (Int) -> Double

    init(
        httpClient: any HTTPClient = DefaultHTTPClient.judgmentClient,
        apiKey: String,
        endpointURLString: String = JevJudgmentClient.defaultEndpointURLString,
        modelIdentifier: String = JevJudgmentClient.defaultModelIdentifier,
        deadlineSeconds: Double = 2,
        maxAttempts: Int = 3,
        backoffSeconds: @escaping @Sendable (Int) -> Double = { attempt in 0.1 * Double(attempt) }
    ) {
        self.httpClient = httpClient
        self.apiKey = apiKey
        self.endpointURLString = endpointURLString
        self.modelIdentifier = modelIdentifier
        self.deadlineSeconds = deadlineSeconds
        self.maxAttempts = maxAttempts
        self.backoffSeconds = backoffSeconds
    }

    func judge(state: JudgmentState, questions: [JudgmentQuestion]) async throws -> JudgmentResult {
        guard !questions.isEmpty else { throw JudgmentError.invalidRequest("questions must not be empty") }
        let request = try makeRequest(state: state, questions: questions)
        let startedAt = Date()

        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await withDeadline(seconds: remainingSeconds(since: startedAt)) {
                    try await send(request, questions: questions, startedAt: startedAt)
                }
            } catch let error as JudgmentError {
                guard Self.isRetryable(error), attempt < maxAttempts else { throw error }
                let backoff = backoffSeconds(attempt)
                guard remainingSeconds(since: startedAt) > backoff else { throw JudgmentError.timedOut }
                try? await Task.sleep(nanoseconds: UInt64(max(0, backoff) * 1_000_000_000))
            }
        }
    }

    // MARK: - Request

    private func makeRequest(state: JudgmentState, questions: [JudgmentQuestion]) throws -> URLRequest {
        guard let url = URL(string: endpointURLString) else {
            throw JudgmentError.invalidRequest("endpoint is not a URL: \(endpointURLString)")
        }
        // `JudgmentState.questionIDs` records which catalogue entries the redactor built
        // this payload for. Checking it here is what makes that field load-bearing: a
        // payload redacted for one question set can never be sent with another, so the
        // allow-list is enforced at encode time rather than only at redaction time.
        let declared = Set(state.questionIDs)
        let asked = Set(questions.map(\.id))
        guard asked.isSubset(of: declared) else {
            let undeclared = asked.subtracting(declared).sorted().joined(separator: ", ")
            throw JudgmentError.invalidRequest("state was not redacted for: \(undeclared)")
        }
        var questionBodies: [String: Any] = [:]
        for question in questions {
            questionBodies[question.id] = question.wireBody
        }
        let body: [String: Any] = [
            "state": state.jsonObject,
            "model": modelIdentifier,
            "questions": questionBodies
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [])
        else {
            throw JudgmentError.invalidRequest("state or questions are not JSON-serializable")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    private func send(_ request: URLRequest, questions: [JudgmentQuestion], startedAt: Date) async throws -> JudgmentResult {
        let response: HTTPResponse
        do {
            response = try await httpClient.data(for: request)
        } catch let error as JudgmentError {
            throw error
        } catch {
            throw JudgmentError.transport(String(describing: error))
        }

        switch response.http.statusCode {
        case 200 ..< 300:
            return try Self.parse(
                data: response.data,
                questions: questions,
                latencySeconds: Date().timeIntervalSince(startedAt)
            )
        case 401:
            throw JudgmentError.unauthorized
        case 400, 422:
            // The documented validation status is 422, but the live service answers a
            // malformed request with 400 — an unknown model and an over-long score rubric
            // both did. Routing 400 to `unexpectedStatus` would keep the number and discard
            // the server's only account of what was wrong, and nothing downstream records a
            // reason of its own: a shadow row would read `judgment_available:false` forever
            // with no way to find out why.
            throw JudgmentError.invalidRequest(Self.truncatedMessage(from: response.data))
        case 429:
            throw JudgmentError.rateLimited
        case 529:
            throw JudgmentError.overloaded
        default:
            throw JudgmentError.unexpectedStatus(response.http.statusCode)
        }
    }

    /// The server's explanation, decoded before it is shortened.
    ///
    /// Truncating the `Data` first would split a multi-byte UTF-8 sequence and collapse
    /// the whole message to empty, losing the only account of why the request was
    /// rejected. Decoding first makes the cut fall on characters instead.
    private static func truncatedMessage(from data: Data, limit: Int = 512) -> String {
        let message = String(decoding: data, as: UTF8.self)
        return message.count <= limit ? message : String(message.prefix(limit))
    }

    // MARK: - Response

    private static func parse(data: Data, questions: [JudgmentQuestion], latencySeconds: Double) throws -> JudgmentResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JudgmentError.malformedResponse("response is not a JSON object")
        }
        guard let rawAnswers = root["answers"] as? [String: Any] else {
            throw JudgmentError.malformedResponse("response has no answers object")
        }

        var answers: [String: JudgmentAnswer] = [:]
        for question in questions {
            guard let rawAnswer = rawAnswers[question.id] as? [String: Any] else {
                throw JudgmentError.missingAnswer(questionID: question.id)
            }
            answers[question.id] = try Self.answer(from: rawAnswer, for: question)
        }

        // Checked after the answers, so a response missing an answer is still reported as
        // `missingAnswer` rather than as an envelope fault.
        //
        // These are required rather than defaulted because both feed the calibration
        // record directly. `model` partitions the sample: defaulting it to `""` would pool
        // records judged by two different model versions, which is the one thing the
        // version field exists to prevent. The token counts are the cost figures, and a
        // silent `0` under-reports rather than reporting nothing.
        guard let modelVersion = root["model"] as? String, !modelVersion.isEmpty else {
            throw JudgmentError.malformedResponse("response has no model")
        }
        guard let usage = root["usage"] as? [String: Any] else {
            throw JudgmentError.malformedResponse("response has no usage")
        }
        guard let inputTokens = usage["input_tokens"] as? Int else {
            throw JudgmentError.malformedResponse("response has no usage.input_tokens")
        }
        guard let outputTokens = usage["output_tokens"] as? Int else {
            throw JudgmentError.malformedResponse("response has no usage.output_tokens")
        }

        return JudgmentResult(
            modelVersion: modelVersion,
            answersByQuestionID: answers,
            usage: JudgmentUsage(inputTokens: inputTokens, outputTokens: outputTokens),
            latencySeconds: latencySeconds
        )
    }

    /// Maps one raw answer, trusting the question's declared kind and rejecting a
    /// response that disagrees with it.
    private static func answer(from raw: [String: Any], for question: JudgmentQuestion) throws -> JudgmentAnswer {
        let reportedType = raw["type"] as? String
        switch question.kind {
        case .noul:
            try requireType(reportedType, equals: "noul", questionID: question.id)
            return try .noul(probability: number(raw["noul"], field: "noul", questionID: question.id))
        case .choice:
            try requireType(reportedType, equals: "choice", questionID: question.id)
            guard let option = raw["choice"] as? String else {
                throw JudgmentError.malformedResponse("\(question.id) has no choice")
            }
            return try .choice(
                option: option,
                probabilities: numberMap(raw["probabilities"], field: "probabilities", questionID: question.id),
                confidence: number(raw["confidence"], field: "confidence", questionID: question.id)
            )
        case .score:
            try requireType(reportedType, equals: "score", questionID: question.id)
            return try .score(
                value: number(raw["score"], field: "score", questionID: question.id),
                legend: stringMap(raw["legend"], field: "legend", questionID: question.id),
                probabilities: numberMap(raw["probabilities"], field: "probabilities", questionID: question.id),
                confidence: number(raw["confidence"], field: "confidence", questionID: question.id)
            )
        }
    }

    private static func requireType(_ reported: String?, equals expected: String, questionID: String) throws {
        guard let reported, reported == expected else {
            throw JudgmentError.malformedResponse("\(questionID) answered as \(reported ?? "nothing"), expected \(expected)")
        }
    }

    // MARK: - Required field decoding

    //
    // `confidence` and `probabilities` are required on a choice or score answer, and
    // `legend` is required on a score. Defaulting any of them locally would turn a contract
    // violation into a judgment that looks genuine: a `confidence` of 0 is not "no
    // confidence reported", it is the most under-confident value there is, and it lands
    // outside the calibration band instead of being discarded. Dropping one bad entry from
    // a probability map is worse still, because it silently renormalizes the distribution
    // the risk gate is computed from.

    /// A JSON number, rejecting a boolean.
    ///
    /// `true` bridges to `NSNumber`, so reading it as a `Double` yields 1.0 — maximum
    /// confidence invented out of a type error. `CFBoolean` is the only way to tell the two
    /// apart once `JSONSerialization` has boxed them.
    private static func number(_ value: Any?, field: String, questionID: String) throws -> Double {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(), let number = value as? NSNumber else {
            throw JudgmentError.malformedResponse("\(questionID) has no numeric \(field)")
        }
        return number.doubleValue
    }

    private static func numberMap(_ value: Any?, field: String, questionID: String) throws -> [String: Double] {
        guard let object = value as? [String: Any], !object.isEmpty else {
            throw JudgmentError.malformedResponse("\(questionID) has no \(field)")
        }
        return try object.mapValues { try number($0, field: field, questionID: questionID) }
    }

    private static func stringMap(_ value: Any?, field: String, questionID: String) throws -> [String: String] {
        guard let object = value as? [String: Any], !object.isEmpty else {
            throw JudgmentError.malformedResponse("\(questionID) has no \(field)")
        }
        return try object.mapValues { entry in
            guard let text = entry as? String else {
                throw JudgmentError.malformedResponse("\(questionID) has a non-text entry in \(field)")
            }
            return text
        }
    }

    // MARK: - Retry and deadline

    private static func isRetryable(_ error: JudgmentError) -> Bool {
        switch error {
        case .rateLimited, .overloaded:
            true
        case .unauthorized, .invalidRequest, .unexpectedStatus, .transport,
             .malformedResponse, .timedOut, .missingAnswer:
            false
        }
    }

    private func remainingSeconds(since startedAt: Date) -> Double {
        max(0, deadlineSeconds - Date().timeIntervalSince(startedAt))
    }

    private func withDeadline<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds > 0 else { throw JudgmentError.timedOut }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw JudgmentError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw JudgmentError.timedOut }
            return first
        }
    }
}
