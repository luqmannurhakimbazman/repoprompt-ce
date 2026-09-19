import Foundation

/// The only entry point consumers use to ask for a judgment.
///
/// It returns `nil` for every failure, including no stored key and a disabled setting.
/// Consumers must be written so that `nil` runs today's behavior unchanged, which makes
/// every failure mode resolve to the status quo.
// swiftformat:disable redundantSendable
struct JudgmentPolicy: Sendable {
    /// Builds a judge, or returns `nil` when the feature is unavailable.
    ///
    /// Availability is resolved per call rather than cached, so removing the key or
    /// turning the setting off takes effect immediately.
    private let judgeFactory: @Sendable () -> (any SystemOneJudging)?

    init(judgeFactory: @escaping @Sendable () -> (any SystemOneJudging)?) {
        self.judgeFactory = judgeFactory
    }

    func judgment(for request: JudgmentRequest) async -> JudgmentResult? {
        guard let judge = judgeFactory() else { return nil }
        let plan = JudgmentStateRedactor.plan(for: request)
        do {
            return try await judge.judge(state: plan.state, questions: plan.questions)
        } catch {
            return nil
        }
    }
}

extension JudgmentPolicy {
    /// The app-wide policy. Its factory reads the stored key each call and returns `nil`
    /// when none is present, so no key means no network call at all.
    static let shared = JudgmentPolicy(judgeFactory: {
        guard let key = Self.storedAPIKey(), !key.isEmpty else { return nil }
        return JevJudgmentClient(apiKey: key)
    })

    private static func storedAPIKey() -> String? {
        try? SecureKeysService().getPlainValue(for: .typeSafeSystemOneAPI)
    }
}
