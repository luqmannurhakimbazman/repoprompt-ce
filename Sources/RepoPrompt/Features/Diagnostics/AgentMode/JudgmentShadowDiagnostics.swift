import Foundation

/// How an `ask_user` interaction actually ended.
///
/// An expired interaction has no human answer, so it can never supply accuracy. Only
/// `.answered` carries a label, which is why it is the primary measurement set.
// swiftformat:disable redundantSendable
enum AskUserShadowOutcome: Sendable, Equatable {
    case answered(pickedRecommended: Bool)
    case skipped
    case expired(behavior: String)

    var label: String {
        switch self {
        case .answered: "answered"
        case .skipped: "skipped"
        case .expired: "expired"
        }
    }
}

/// Records a judgment beside each `ask_user` outcome without acting on it.
///
/// Entry point: `JudgmentShadowRecorder.shared.record(...)`, called from the two
/// `ask_user` funnels in `AgentModeViewModel` and `ContextBuilderAgentViewModel`.
/// Purpose: measure whether System One confidence is calibrated on this workload before
/// any behavior depends on it. It is DEBUG-only and off unless
/// `judgment.shadow_enabled` is set.
@MainActor
final class JudgmentShadowRecorder {
    static let shared = JudgmentShadowRecorder(
        policy: .shared,
        isEnabled: { JudgmentShadowRecorder.defaultIsEnabled() },
        appendLine: { JudgmentShadowLogWriter.shared.append($0) }
    )

    private let policy: JudgmentPolicy
    private let isEnabled: @MainActor () -> Bool
    private let appendLine: @MainActor (String) -> Void
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        policy: JudgmentPolicy,
        isEnabled: @escaping @MainActor () -> Bool,
        appendLine: @escaping @MainActor (String) -> Void
    ) {
        self.policy = policy
        self.isEnabled = isEnabled
        self.appendLine = appendLine
    }

    /// Records every question of an interaction, without blocking the caller.
    ///
    /// Fire-and-forget on purpose: recording must not change what the caller returns or
    /// when it returns it.
    func record(interactionID: UUID, questions: [AgentAskUserQuestion], outcome: AskUserShadowOutcome) {
        guard isEnabled() else { return }
        for question in questions {
            Task { @MainActor [weak self] in
                await self?.record(interactionID: interactionID, question: question, outcome: outcome)
            }
        }
    }

    /// Records one question and waits for it. The `questions:` overload above fans out
    /// to this one; the expiry resolver and the tests await it directly, so neither
    /// races a detached task.
    func record(interactionID: UUID, question: AgentAskUserQuestion, outcome: AskUserShadowOutcome) async {
        guard isEnabled() else { return }
        let judgment = await policy.judgment(for: .askUserExpiry(Self.input(for: question)))
        var record: [String: Any] = [
            "timestamp": Self.timestampFormatter.string(from: Date()),
            "interaction_id": interactionID.uuidString,
            "question_id": question.id,
            "option_count": question.options.count,
            "recommended_option": question.recommendedOption?.label ?? "",
            "outcome": outcome.label,
            "judgment_available": judgment != nil
        ]

        switch outcome {
        case let .answered(pickedRecommended):
            record["picked_recommended"] = pickedRecommended
        case .skipped:
            break
        case let .expired(behavior):
            record["expiry_behavior"] = behavior
        }

        if let judgment {
            record["model_version"] = judgment.modelVersion
            record["latency_seconds"] = judgment.latencySeconds
            record["input_tokens"] = judgment.usage.inputTokens
            record["answers"] = judgment.answersByQuestionID.mapValues(Self.recordBody(for:))
        }

        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: []),
              let line = String(data: data, encoding: .utf8)
        else {
            return
        }
        appendLine(line)
    }

    /// The five fields a judgment may know about an `ask_user` question.
    ///
    /// Built here rather than in the redactor so the domain type never crosses into
    /// `Infrastructure/AI/Judgment`.
    static func input(for question: AgentAskUserQuestion) -> AskUserExpiryJudgmentInput {
        AskUserExpiryJudgmentInput(
            questionText: question.question,
            context: question.context,
            optionLabels: question.options.map(\.label),
            optionDescriptions: question.options.compactMap(\.description),
            recommendedOptionLabel: question.recommendedOption?.label
        )
    }

    private static func recordBody(for answer: JudgmentAnswer) -> [String: Any] {
        var body: [String: Any] = ["kind": answer.kindLabel]
        switch answer {
        case let .noul(probability):
            body["probability"] = probability
        case let .choice(option, probabilities, confidence):
            body["option"] = option
            body["probabilities"] = probabilities
            body["confidence"] = confidence
        case let .score(value, _, probabilities, confidence):
            body["value"] = value
            body["probabilities"] = probabilities
            body["confidence"] = confidence
        }
        return body
    }

    private static func defaultIsEnabled() -> Bool {
        #if DEBUG
            GlobalSettingsStore.shared.judgmentShadowEnabled()
        #else
            false
        #endif
    }
}

/// Appends JSONL records to the shadow log, creating the file on first write.
///
/// Mirrors the append pattern in `ClaudeNativeProcessSessionController`: open, seek to
/// end, write, close, and swallow every failure, because a diagnostics writer must never
/// affect the product path.
@MainActor
final class JudgmentShadowLogWriter {
    static let shared = JudgmentShadowLogWriter()

    private var resolvedFileURL: URL?

    func append(_ line: String) {
        #if DEBUG
            guard let url = fileURL() else { return }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            do {
                try handle.seekToEnd()
                handle.write(data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        #else
            _ = line
        #endif
    }

    #if DEBUG
        private func fileURL() -> URL? {
            if let resolvedFileURL { return resolvedFileURL }
            let override = GlobalSettingsStore.shared.judgmentShadowLogFilePath()
            let directory = override.isEmpty
                ? FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-ce-judgment-shadow", isDirectory: true)
                : URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd"
            let url = directory.appendingPathComponent("judgment-shadow-\(formatter.string(from: Date())).jsonl")
            resolvedFileURL = url
            return url
        }
    #endif
}
