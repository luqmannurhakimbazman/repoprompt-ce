import Foundation

/// How an `ask_user` interaction actually ended.
///
/// An expired interaction has no human answer, so it can never supply accuracy. Only
/// `.answered` carries a label, which is why it is the primary measurement set.
// swiftformat:disable redundantSendable
enum AskUserShadowOutcome: Sendable, Equatable {
    case answered(pickedRecommended: Bool?)
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

extension AskUserShadowOutcome {
    /// Whether this one question's transmitted answer was its own recommended option, or
    /// `nil` when it has no recommendation to compare against — there is no comparison to
    /// make, so the record should say nothing rather than claim a match or a mismatch it
    /// never checked.
    ///
    /// Computed per question, not per interaction. Each record carries a judgment about
    /// one question and `ask_user` accepts up to 10 of them, so an interaction-level
    /// verdict stamped on every row would let one custom answer drag nine unrelated rows
    /// to `false` and depress the gate for reasons that have nothing to do with
    /// calibration.
    ///
    /// Reads the transmitted answer through `AgentAskUserQuestion.answer(from:)` rather
    /// than the raw draft, so a single-select answer that also carries custom text, or a
    /// question the user skipped, is judged by what was actually sent rather than by a
    /// leftover selection that was never sent. Does not reimplement `answer(from:)`'s
    /// precedence rules.
    static func pickedRecommended(for question: AgentAskUserQuestion, draft: AgentAskUserDraft?) -> Bool? {
        guard let recommended = question.recommendedOption?.label else { return nil }
        return question.answer(from: draft ?? AgentAskUserDraft()).answers == [recommended]
    }
}

/// How an `ask_user` interaction ended, before it is resolved into one outcome per
/// question.
///
/// The answered case carries the drafts rather than a single verdict, because the
/// recorder needs each question's own draft to label that question's own row.
enum AskUserShadowInteractionOutcome: Sendable, Equatable {
    case answered(draftsByQuestionID: [String: AgentAskUserDraft])
    case skipped
    case expired(behavior: String)

    /// The outcome to write on one question's row.
    func resolved(for question: AgentAskUserQuestion) -> AskUserShadowOutcome {
        switch self {
        case let .answered(draftsByQuestionID):
            .answered(
                pickedRecommended: AskUserShadowOutcome.pickedRecommended(
                    for: question,
                    draft: draftsByQuestionID[question.id]
                )
            )
        case .skipped:
            .skipped
        case let .expired(behavior):
            .expired(behavior: behavior)
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

    /// Whether recording is on right now.
    ///
    /// Lets a caller skip the work that only exists to feed the recorder — the expiry
    /// resolver checks it so the release path does not hop tasks for a feature that is
    /// hard-`false` there.
    var isRecordingEnabled: Bool {
        isEnabled()
    }

    /// Records every question of an interaction, without blocking the caller.
    ///
    /// Fire-and-forget on purpose: recording must not change what the caller returns or
    /// when it returns it. The interaction-level outcome is resolved into a per-question
    /// outcome here, so each row's label describes the question that row is about.
    func record(interactionID: UUID, questions: [AgentAskUserQuestion], outcome: AskUserShadowInteractionOutcome) {
        guard isEnabled() else { return }
        for question in questions {
            let questionOutcome = outcome.resolved(for: question)
            Task { @MainActor [weak self] in
                await self?.record(interactionID: interactionID, question: question, outcome: questionOutcome)
            }
        }
    }

    /// Records the answered or skipped end of an interaction.
    ///
    /// Both answered funnels — `AgentModeViewModel.resolveAskUserResponse` and
    /// `ContextBuilderAgentViewModel.resolveAskUserResponse` — call this one method, so
    /// the mapping from "the user skipped every question" to an outcome is written once
    /// and can be exercised without building a view model. This is the funnel that
    /// carries the only ground-truth label, so it is the one that most needs a seam.
    func recordResolved(
        interaction: AgentAskUserInteraction,
        draftsByQuestionID: [String: AgentAskUserDraft],
        skipAll: Bool
    ) {
        record(
            interactionID: interaction.id,
            questions: interaction.questions,
            outcome: skipAll ? .skipped : .answered(draftsByQuestionID: draftsByQuestionID)
        )
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
            // `recommendedOption` falls back to the first option when the agent flagged
            // none, so an analyst cannot otherwise tell an explicit recommendation from a
            // positional guess. The two may calibrate differently, so the record says which.
            "recommended_option_is_flagged": question.options.contains(where: \.isRecommended),
            "outcome": outcome.label,
            "judgment_available": judgment != nil,
            "catalogue_version": JudgmentQuestionCatalogue.version
        ]

        switch outcome {
        case let .answered(pickedRecommended):
            if let pickedRecommended {
                record["picked_recommended"] = pickedRecommended
            }
        case .skipped:
            break
        case let .expired(behavior):
            record["expiry_behavior"] = behavior
        }

        if let judgment {
            record["model_version"] = judgment.modelVersion
            record["latency_seconds"] = judgment.latencySeconds
            record["input_tokens"] = judgment.usage.inputTokens
            // Both token counts, because the calibration report's cost row needs both and
            // an analyst cannot recover the output count from anything else in the row.
            record["output_tokens"] = judgment.usage.outputTokens
            record["answers"] = judgment.answersByQuestionID.mapValues(Self.recordBody(for:))
        }

        guard let line = Self.line(for: record) else { return }
        appendLine(line)
    }

    /// Serializes a record, retrying without `answers` if the first attempt fails.
    ///
    /// `answers` is the only part of a record built from server-supplied values, so it is
    /// the only part that can carry something `JSONSerialization` rejects. Dropping the
    /// whole row on that failure would also discard the human label, which is the one
    /// field nobody can reconstruct afterwards, so the outcome row survives without the
    /// judgment instead.
    private static func line(for record: [String: Any]) -> String? {
        if let line = serialize(record) { return line }
        var withoutAnswers = record
        withoutAnswers["answers"] = nil
        withoutAnswers["answers_dropped"] = true
        return serialize(withoutAnswers)
    }

    private static func serialize(_ record: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: []),
              let line = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return line
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
            // Positional, not compacted: `compactMap` drops the entry for an option with
            // no description and shifts every later description onto the wrong option.
            // Descriptions are one of only five fields the rubric reads, so a shifted
            // field degrades the judgments being calibrated.
            optionDescriptions: question.options.map { $0.description ?? "" },
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
        case let .score(value, legend, probabilities, confidence):
            body["value"] = value
            // The legend is what makes `probabilities` readable later: it maps each level
            // key back to the rubric text that produced it. Without it a gate that sums
            // the highest-risk levels has to assume the key convention, and that
            // assumption silently changes meaning if the rubric gains or loses a level.
            body["legend"] = legend
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
    private var resolvedCacheKey: String?

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
        /// Re-resolved whenever the override path or the calendar day changes, so a
        /// mid-session settings edit and a run that crosses UTC midnight both pick up a
        /// fresh URL instead of reusing an unconditionally cached one.
        private func fileURL() -> URL? {
            let override = GlobalSettingsStore.shared.judgmentShadowLogFilePath()
            let dateStamp = Self.dateStampFormatter.string(from: Date())
            let cacheKey = "\(override)|\(dateStamp)"
            if let resolvedFileURL, resolvedCacheKey == cacheKey {
                return resolvedFileURL
            }

            let directory = override.isEmpty
                ? FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-ce-judgment-shadow", isDirectory: true)
                : URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let url = directory.appendingPathComponent("judgment-shadow-\(dateStamp).jsonl")
            resolvedFileURL = url
            resolvedCacheKey = cacheKey
            return url
        }

        private static let dateStampFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd"
            return formatter
        }()
    #endif
}
