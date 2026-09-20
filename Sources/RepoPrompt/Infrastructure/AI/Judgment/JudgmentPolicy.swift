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

#if DEBUG
    /// The only writer of the System One key, behind the DEBUG `judgment.api_key` setting.
    ///
    /// The key is not a provider credential: `KeyManager.saveAPIKey` is keyed on
    /// `AIProviderType`, and registering this model there is prohibited, so slice 1 needs
    /// its own writer or it can never collect the data it exists to collect.
    ///
    /// Nothing here reads the key back out. `presenceLabel()` reports only whether one is
    /// stored, so the secret has no path into `app_settings list` output or a diagnostics
    /// dump. `JudgmentPolicy.storedAPIKey()` above is the sole reader, and it hands the
    /// value straight to an `Authorization` header.
    @MainActor
    enum JudgmentAPIKeyStore {
        static let presentLabel = "set"
        static let absentLabel = "not set"

        /// Substituted by tests so the suite never reaches a real Keychain. `nil` in
        /// production, where every call goes to `SecureKeysService`.
        static var storageForTesting: (any SecurePlainStringStoring)?

        /// Whether a key is stored. Never the key.
        static func presenceLabel() -> String {
            let stored = (try? storage().getPlainValue(for: .typeSafeSystemOneAPI)) ?? nil
            return stored?.isEmpty == false ? presentLabel : absentLabel
        }

        /// Stores a key, or deletes the account when the value is empty or only
        /// whitespace. The stored value is trimmed: a key pasted with a trailing newline
        /// would otherwise fail authorization for reasons nothing reports.
        static func write(_ value: String) throws {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try storage().deletePlainValue(for: .typeSafeSystemOneAPI)
            } else {
                try storage().savePlainValue(trimmed, for: .typeSafeSystemOneAPI)
            }
        }

        private static func storage() -> any SecurePlainStringStoring {
            storageForTesting ?? SecureKeysService()
        }
    }
#endif
