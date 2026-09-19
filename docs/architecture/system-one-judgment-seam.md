# System One judgment seam (TypeSafe Jev)

Date: 18 September 2026
Status: design approved, not implemented
Scope: slice 1 only (the seam plus shadow-mode measurement). Slice 2 is sketched, not specified.

## Summary

RepoPrompt CE makes many small decisions that are neither deterministic nor worth a frontier-model
call: should the app answer an expired `ask_user` question on the user's behalf, which candidate files
deserve a heavy context pass, what kind of failure a daemon log describes. Today each of these is a
hand-written heuristic or a blunt timer.

TypeSafe's Jev answers exactly this shape of question. It takes program state and returns typed,
probabilistic decisions in about 100 ms for $0.042 per million input tokens, with no text output at
all.

This design adds a narrow judgment seam for it. Slice 1 ships the seam and a DEBUG-only shadow
recorder that measures whether Jev's confidence is calibrated on this workload. Slice 1 changes no
user-visible behavior. A numeric gate at the end of slice 1 decides whether any consumer is wired up
at all, or whether the seam is deleted.

## What Jev provides

One endpoint: `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer <key>`,
`Content-Type: application/json`.

Request body:

```json
{
  "state": "string | object | array",
  "model": "jev-latest",
  "questions": {
    "<question_id>": { "type": "noul|choice|score", "instructions": "...", "criteria": "..." }
  }
}
```

Three question types:

| Type | Criteria format | Answer fields |
| --- | --- | --- |
| `noul` | optional `{"true": "...", "false": "..."}` | `noul`: probability 0–1 that the answer is yes |
| `choice` | map of option name to rubric | `choice`, `probabilities`, `confidence` |
| `score` | ordered array of at least 2 level descriptions | `score`, `legend`, `probabilities`, `confidence` |

Response body:

```json
{
  "model": "jev-1.12",
  "answers": { "<question_id>": { "type": "...", "...": "..." } },
  "usage": { "input_tokens": 0, "output_tokens": 0 }
}
```

Properties that matter for this design:

- Questions in one request are answered independently and in parallel. There is no shared reasoning
  between them and no hidden context.
- `confidence` exists on `choice` and `score` only. A `noul` answer carries its probability and
  nothing else, so a `noul` must be read with a two-sided band rather than a confidence threshold.
- Errors are `401` (bad key), `422` (validation), `429` (rate limit), `529` (overloaded).
- Jev is early access and versioned. The observed version, not `jev-latest`, must be recorded with
  every measurement.
- DataCamp reports about 68% accuracy on TypeSafe's own four-workflow benchmark. Jev cannot
  hallucinate a string, because it emits no strings, but it is plainly wrong often enough that every
  consumer must gate on confidence and degrade to existing behavior.

## Why this belongs in the app

Candidate consumers, ranked. Only the first is in scope for slice 2; the rest justify building a
shared seam rather than a single-purpose call site.

1. **`ask_user` expiry stakes.** `AskUserTimeoutBehavior` currently offers `.returnNoAnswer` or
   `.chooseRecommended`. The second takes the recommended option whatever the question was. A
   judgment lets the app separate cheap questions from consequential ones and auto-answer only the
   cheap ones.
2. **Context Builder relevance prefilter.** `context_builder` is the heaviest sub-agent in the
   product. Scoring several hundred candidate paths plus code-map signatures against the task costs
   roughly $0.004 and one round trip, and shortens what the heavy model must read.
3. **Daemon failure triage.** A `choice` over `{compile-error, test-failure,
   input-modified-during-build, heavy-slot-contention, lifecycle-supersession, flake, infra}` gives
   `job wait` a typed cause. `CLAUDE.md` already warns that a compile failure is not lifecycle
   supersession, which is the distinction readers of raw logs get wrong.
4. **Tool-result honesty checks.** Commit 43e01915 stopped `read_file` reporting empty undecodable
   output as success. A `noul` asking whether a result answers the request generalizes that for cases
   no deterministic check catches.
5. **Auto-wake admission.** `AgentModeViewModel+SessionLinkAutoWake` decides whether a lane may start
   an automatic turn now. A judged attention score can choose wake-now against batch, as policy only.
6. **Model and effort routing.** `AutoRecommendationEngine` routes on provider availability flags
   alone and could route on judged task complexity.

Lower-value candidates, recorded and not pursued: semantic rerank over `RepoSearchBatchScorer`,
Oracle-against-explore escalation, transcript retention tiering.

## Non-goals

These are prohibitions, not deferrals.

- No agent-facing MCP tool. The decisions above are app-internal and are never initiated by an agent.
  A network-capable judgment tool on the agent surface would widen the prompt-injection surface for
  no gain.
- No registration in `AIProviderFactory`, `ProviderConfiguration`, `AIModel`, or any model catalog.
  Jev has no chat interface, no streaming, and no message history, and a user must never be able to
  select it as an agent model.
- No use in any path that requires human authority: permission grants, tool auto-approval,
  secret-scanning verdicts, force-push, history rewrite, branch or fork deletion, credential
  rotation, or visible app lifecycle actions. A judgment informs; it never authorizes. This mirrors
  the rule already stated in `docs/architecture/agent-session-oversight-auto-wake.md`.
- No replacement of a deterministic check. Git porcelain parsing, path matching, type checks, and
  decoding stay deterministic. A judgment may only handle the residue no rule can decide.
- No text generation, summarization, or explanation. The model cannot do it.

## Architecture

New area: `Sources/RepoPrompt/Infrastructure/AI/Judgment/`. It is cross-cutting service substrate, so
`docs/architecture/source-layout.md` places it under `Infrastructure`, owned by `RepoPromptApp`.

### Files

**`SystemOneJudgment.swift`** — value types, no I/O.

- `JudgmentQuestion`: `id`, `kind`, `instructions`, `criteria`. `JudgmentQuestionKind` is
  `.noul(trueCriteria:falseCriteria:)`, `.choice([option: rubric])`, `.score([levelDescription])`.
- `JudgmentAnswer`: enum with `.noul(probability: Double)`,
  `.choice(option: String, probabilities: [String: Double], confidence: Double)`,
  `.score(value: Double, legend: [String: String], probabilities: [String: Double], confidence: Double)`.
- `JudgmentState`: the redacted payload sent as `state`, built only by `JudgmentStateRedactor` and
  carrying its originating catalogue entry ids so the redactor's allow-list can be checked at encode
  time.
- `JudgmentUsage`: `inputTokens`, `outputTokens`.
- `JudgmentResult`: `modelVersion`, `answersByQuestionID`, `usage`, `latency`.
- `JudgmentError`: `.unauthorized`, `.invalidRequest(String)`, `.rateLimited`, `.overloaded`,
  `.transport(Error)`, `.malformedResponse(String)`, `.timedOut`, `.missingAnswer(questionID: String)`.

**`SystemOneJudging.swift`** — the seam.

```swift
protocol SystemOneJudging: Sendable {
    func judge(state: JudgmentState, questions: [JudgmentQuestion]) async throws -> JudgmentResult
}
```

One method. Test doubles stay trivial and no consumer can reach the network another way.

**`JevJudgmentClient.swift`** — the only conformance that makes network calls.

- Builds the request over the existing `HTTPClient` protocol in
  `Sources/RepoPrompt/Infrastructure/Networking/HTTPClient.swift`.
- Adds `DefaultHTTPClient.judgmentClient`, configured with `requestTimeout: 5` and
  `resourceTimeout: 5`, beside the existing `aiClient` and `uiCriticalClient` statics. The existing
  120-second `aiClient` is wrong for a service whose whole premise is a 100 ms answer.
- Enforces its own deadline of 2 seconds across retries. A judgment that arrives late is worthless,
  because the caller has already fallen back.
- Retries `429` and `529` only, with exponential backoff, at most twice, inside that deadline.
  `401` and `422` never retry.
- Maps every HTTP status and decode failure to a `JudgmentError` case. It never returns a partially
  decoded answer.

**`JudgmentQuestionCatalogue.swift`** — every question the app may ask, declared once.

No call site composes instructions or criteria inline. A catalogue entry owns its `id`, its rubric
text, and its declared state fields. Two consequences: shadow records stay comparable across builds,
and the redactor has a single place to read an allow-list from. A later conductor-side reuse copies
this file's rubrics verbatim rather than paraphrasing them.

Slice 1 declares exactly two entries, both for `ask_user`. Both travel in one request, because Jev
answers the questions in a request independently and in parallel:

- `ask_user.recommended_option_risk`, a `score` with ordered levels:
  0. "Choosing wrong costs nothing. The run can change course later at no cost."
  1. "Choosing wrong wastes work that is easy to redo."
  2. "Choosing wrong writes files or changes local state that a person must undo by hand."
  3. "Choosing wrong acts outside this machine, or does something no one can undo."
- `ask_user.needs_human_authority`, a `noul` with criteria:
  - true: "The question asks for permission, approval, or a decision the user reserved for themselves."
  - false: "The question asks for a preference, a name, or a technical detail the agent could have
    worked out itself."

**`JudgmentStateRedactor.swift`** — builds the `state` payload.

Redaction is a required stage, not a courtesy. The redactor reads the catalogue entry's declared
fields and emits only those. For the two `ask_user` questions the payload is the question text, the
per-question context string, the option labels and descriptions, and which label is recommended.

`JudgmentState` lives in the redactor's own file behind a `fileprivate` initialiser, so no call site
outside that file can assemble a payload at all. A `#if DEBUG` `forTesting` factory is the single
exception and exists only in debug builds. That makes the allow-list a property the compiler holds
rather than one reviewers must remember to check.

It must never include file contents, transcript text, environment variables, absolute paths, workspace
names, or anything read from a secret-bearing path. A test asserts the serialized payload's key set
equals the declared set exactly, so adding a field to the request without declaring it fails the
suite.

**`JudgmentPolicy.swift`** — the wrapper every consumer uses.

```swift
func judgment(for questions: [JudgmentQuestion], state: JudgmentState) async -> JudgmentResult?
```

It returns `nil` on every error, on timeout, when no key is stored, and when the feature is off. It
never throws into product flow. Consumers must be written so that `nil` runs today's behavior
unchanged. Failure always resolves to the status quo.

### The `ask_user` hook point

`AskUserTimeoutBehavior.expiredResponse(for:drafts:elapsedSeconds:)` is synchronous and pure, and it
should stay that way. The judged path therefore does not live inside that switch.

Instead a resolver runs before it:

```swift
// Features/AgentMode/Runtime/AskUserExpiryBehaviorResolver.swift
func effectiveBehavior(
    configured: AskUserTimeoutBehavior,
    interaction: AgentAskUserInteraction
) async -> AskUserTimeoutBehavior
```

In slice 1 the resolver returns `configured` unchanged, and records a shadow judgment on the way past.
In slice 2 it may downgrade a judged-unsafe interaction to `.returnNoAnswer`. The enum stays pure and
unit-testable, and the async work sits at the call site that already awaits a timer.

Latency is free here. The expiry path has already waited out the full inactivity window, so an extra
100 ms is invisible.

## Credential and privacy

- Add `case typeSafeSystemOneAPI` to `SecureStorageAccount` in
  `Sources/RepoPrompt/Infrastructure/Security/SecureStorageAccountCatalog.swift`, and store the key
  through `SecureKeyService` like every other provider key.
- Debug builds inherit the existing rule: ephemeral in-memory storage unless an explicit
  `SIGN_IDENTITY` opted into persistent Keychain storage. No new Keychain prompt appears on ad-hoc
  builds.
- The seam constructs no client unless a key is stored **and** the opt-in setting is on. With no key,
  `JudgmentPolicy` returns `nil` without touching the network.
- The settings copy states plainly that enabling the feature sends the redacted question text to
  TypeSafe, a third-party API. `docs/privacy/telemetry.md` gains a section naming what leaves the
  machine and what cannot.

## Shadow mode

`Sources/RepoPrompt/Features/Diagnostics/AgentMode/JudgmentShadowDiagnostics.swift`, beside the
existing `AgentModePerfDiagnostics`, with the documented entry point that directory requires.

### What it records

For every `ask_user` interaction that reaches a terminal state, with the feature enabled, the recorder
writes one JSONL line: interaction id, catalogue question ids, judged answers, probabilities and
confidence, observed model version, request latency, token usage, the option the app would have
chosen, and how the interaction actually ended.

Behavior is byte-identical to today. The recorder reads the judgment and discards it.

### Where ground truth comes from

An expired interaction produces no human answer, so expired interactions alone cannot measure
accuracy. The recorder therefore runs on **answered** interactions too, and that is the primary
measurement set.

When a person answers inside the window, the app knows both what the judgment said and what the person
chose. The question "would auto-answering have matched the human?" then has a real label: did the
person pick the recommended option or not. Expired interactions are still recorded, but they only
supply rate and cost data, never accuracy.

### Settings surface

Two DEBUG-only keys in `Sources/RepoPrompt/Infrastructure/MCP/AppSettingsMCPService.swift`, following
the `agent_mode.claude_raw_event_logging_enabled` precedent exactly:

- `judgment.shadow_enabled` — bool, default false.
- `judgment.shadow_log_file_path` — raw text, empty clears the override and logging then writes to a
  non-workspace temp debug directory.

No release-build surface and no Settings UI in slice 1. The feature has no user-visible effect yet, so
it needs no user-visible control.

### The calibration gate

Slice 1 is finished when the recorder has collected at least 100 human-answered interactions and a
report states all three numbers. Slice 2 proceeds only if all three hold:

1. Among interactions the rubric judges safe to auto-answer, the person picked the recommended option
   in at least 90% of cases. The safe band for this measurement is the initial proposal
   `needs_human_authority` at or below 0.15, and `recommended_option_risk` at or below 1.0 with score
   confidence at or above 0.7. These three numbers exist to make the gate measurable, not because
   they are known to be right; slice 2 may move them anywhere the report's distribution supports.
2. Disagreements concentrate outside that band. If judged-safe and judged-unsafe cases disagree with
   the human at similar rates, the confidence signal carries no information and the thresholds are
   arbitrary.
3. No judged-safe case is one the rubric rated at risk level 2 or 3.

If the gate fails, the seam is deleted rather than kept as dead code, and this document records the
measured result. Keeping an unused network seam is worse than having none.

Rubric wording may be revised and re-measured before the gate is called, but a revision resets the
100-interaction count. Synthetic questions replayed from real transcripts may be used to sanity-check
rubric wording; they must never contribute to the accuracy number.

100 human-answered interactions may take weeks of ordinary use to accumulate. That is accepted. The
alternative is shipping thresholds that were guessed.

## Failure and cost policy

| Condition | Result |
| --- | --- |
| No key stored | `nil`, no network call |
| Setting off | `nil`, no network call |
| `401` / `422` | `nil`, logged once per process, feature self-disables for the session |
| `429` / `529` | retried within the 2 s deadline, then `nil` |
| Deadline exceeded | `nil` |
| Malformed or missing answer | `nil`, recorded as malformed |

Cost is bounded by construction: slice 1 issues at most one request per `ask_user` interaction, with a
payload of a few hundred tokens. At $0.042 per million input tokens, a thousand interactions cost
under one cent.

## Testing

New directory `Tests/RepoPromptTests/Judgment/` inside the existing `RepoPromptTests` target. No test
touches the network.

- `JevJudgmentClientTests` — decode fixtures for all three answer types; `401`, `422`, `429`, `529`,
  malformed JSON, a response missing a requested question id; retry behavior for `429`/`529` and
  absence of retry for `401`/`422`; deadline enforcement.
- `JudgmentStateRedactorTests` — the serialized payload's key set equals the catalogue's declared set
  for each entry; file contents, absolute paths, and environment values are absent when a caller tries
  to pass them.
- `JudgmentPolicyTests` — every `JudgmentError` case maps to `nil`; no key means no call.
- `AskUserExpiryBehaviorResolverTests` — the resolver returns the configured behavior unchanged in
  slice 1, for every combination of judged answer, including a stub that throws.
- `JudgmentShadowDiagnosticsTests` — a recorded interaction returns the same `AgentAskUserResponse` as
  an unrecorded one; a record carries the observed model version.

Validation before handoff:

```bash
make dev-test FILTER=Judgment
make dev-test FILTER=AskUserExpiryBehaviorResolverTests
make dev-test FILTER=AskUserAutoAnswerTests
make dev-lint
make dev-build
```

The live CE MCP smoke flow is not required. Slice 1 adds no MCP tool and changes no packaging.
The two new `app_settings` keys should be confirmed once against a running debug app:

```bash
rpce-cli-debug -w 1 -c app_settings -j '{"op":"list","group":"judgment","detailed":true}'
```

## Slice 2 sketch (not specified)

If the gate passes, `AskUserTimeoutBehavior` gains a third case, `.chooseRecommendedWhenSafe`, raw
value `choose_recommended_when_safe`. It degrades to `.returnNoAnswer` whenever the judgment is
missing, below threshold, or late. `autoAnswered` stays true, the provisional-answer guidance already
written into `AGENTS.md` still governs, and the MCP response gains a marker so the agent knows a
machine rather than a person cleared the question. Thresholds come from the slice 1 report, not from
this document.

Slice 2 gets its own brainstorm, its own spec, and its own plan.

## Risks

- **Jev is early access behind a waitlist.** Access could change or the model could be withdrawn.
  Mitigation: the seam is one protocol with one conformance, and slice 1 ships no dependent behavior.
- **A model update silently shifts calibration.** Mitigation: every record carries the observed
  version, and a version change invalidates the sample rather than extending it.
- **Rubric text is the real interface.** Accuracy depends more on the level descriptions than on any
  code here. Mitigation: rubrics live in one file, and a revision resets the measurement count.
- **Third-party network dependency in a local-first app.** Mitigation: off by default, no key means no
  call, redaction is enforced by test, and every failure resolves to current behavior.
- **Scope creep into authority paths.** A cheap confident-sounding judgment invites use in approval
  flows. Mitigation: the non-goals above are prohibitions, and `JudgmentPolicy` is the only entry
  point, which makes its consumers greppable in review.

## References

- TypeSafe agent skill documentation: https://docs.typesafe.ai/agent-skill
- System One concepts: https://docs.typesafe.ai/concepts/system-one
- DataCamp, "Jev: TypeSafe's System One Model That Never Hallucinates", 16 September 2026:
  https://www.datacamp.com/blog/system-one-models-jev
- `docs/architecture/source-layout.md` — ownership map for the new `Infrastructure/AI/Judgment` area
- `docs/architecture/agent-session-oversight-auto-wake.md` — the informs-never-authorizes rule this
  design inherits
