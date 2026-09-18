import Foundation
@testable import RepoPromptApp

/// An `HTTPClient` that replays queued outcomes and records what it was asked for.
/// No test in this directory touches the network.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    enum Outcome {
        case status(Int, Data)
        case failure(Error)
        case slow(seconds: Double, status: Int, body: Data)
    }

    private let lock = NSLock()
    private var queued: [Outcome]
    private(set) var recordedRequests: [URLRequest] = []

    init(responses: [Outcome]) {
        queued = responses
    }

    var remainingResponseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queued.count
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        lock.lock()
        recordedRequests.append(request)
        let outcome = queued.isEmpty ? Outcome.failure(URLError(.badServerResponse)) : queued.removeFirst()
        lock.unlock()

        switch outcome {
        case let .status(code, body):
            return HTTPResponse(data: body, http: Self.response(code: code, url: request.url))
        case let .failure(error):
            throw error
        case let .slow(seconds, code, body):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return HTTPResponse(data: body, http: Self.response(code: code, url: request.url))
        }
    }

    func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
        _ = request
        throw URLError(.unsupportedURL)
    }

    private static func response(code: Int, url: URL?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? URL(fileURLWithPath: "/"),
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) ?? HTTPURLResponse()
    }
}

/// A `SystemOneJudging` that returns a fixed outcome without any network work.
struct StubSystemOneJudge: SystemOneJudging {
    var result: Result<JudgmentResult, JudgmentError>

    func judge(state: JudgmentState, questions: [JudgmentQuestion]) async throws -> JudgmentResult {
        _ = state
        _ = questions
        return try result.get()
    }
}

extension JudgmentResult {
    /// A minimal result for tests that only care that *something* came back.
    static func stub(
        modelVersion: String = "jev-1.12",
        answers: [String: JudgmentAnswer] = ["a": .noul(probability: 0.1)]
    ) -> JudgmentResult {
        JudgmentResult(
            modelVersion: modelVersion,
            answersByQuestionID: answers,
            usage: JudgmentUsage(inputTokens: 120, outputTokens: 0),
            latencySeconds: 0.1
        )
    }
}
