# System One judgment seam (TypeSafe Jev)

Date: 18 September 2026
Status: slice 1 implemented. Shadow recording is DEBUG-only and off unless a key is stored and
`judgment.shadow_enabled` is on. The calibration gate below has not been called yet.
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

Slice 1 declares exactly three entries, all for `ask_user`. All three travel in one request, because
Jev answers the questions in a request independently and in parallel:

- `ask_user.recommended_option_risk`, a `score` with ordered levels:
  0. "Choosing wrong costs nothing. The run can change course later at no cost."
  1. "Choosing wrong wastes work that is easy to redo."
  2. "Choosing wrong writes files or changes local state that a person must undo by hand."
  3. "Choosing wrong acts outside this machine, or does something no one can undo."
- `ask_user.needs_human_authority`, a `noul` with criteria:
  - true: "The question asks for permission, approval, or a decision the user reserved for themselves."
  - false: "The question asks for a preference, a name, or a technical detail the agent could have
    worked out itself."
- `ask_user.picks_recommended_option`, a `noul` with criteria:
  - true: "The user would accept the recommended option as their own answer."
  - false: "The user would pick one of the other options, write their own answer, or decline to answer
    the question."

The first two gate the agent's recommendation and predict nothing, so neither can be scored against
what the person did. The third predicts the label every answered row already carries, which is what
lets the sample separate a model that discriminates from one riding a high base rate: if people take
the recommended option most of the time anyway, a band clearing 90% agreement has shown nothing. It
asks about the recommended option rather than naming the choices, because catalogue wording is fixed
at compile time — the options themselves travel in the state payload, so the model reads them without
the question varying per interaction.

**`JudgmentStateRedactor.swift`** — builds the `state` payload.

Redaction is a required stage, not a courtesy. The redactor reads the catalogue entry's declared
fields and emits only those. For the `ask_user` questions the payload is the question text, the
per-question context string, the option labels and descriptions, and which label is recommended.
Adding the third question added no field: it reads the same five.

`JudgmentState` lives in the redactor's own file behind a `fileprivate` initialiser, so no call site
outside that file can assemble a payload at all. A `#if DEBUG` `forTesting` factory is the single
exception and exists only in debug builds. That makes the allow-list a property the compiler holds
rather than one reviewers must remember to check.

The redactor fixes which fields are sent, not what they contain. The five `ask_user` fields carry free
text the calling agent wrote, so a path, snippet or credential an agent puts in its own question text
does travel. What the app never contributes, because no request case carries it: file contents it
read, transcript text, environment variables, workspace names, and anything read from a secret-bearing
path. A test asserts the serialized payload's key set
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
In slice 2, whose direction was decided on 2026-09-20 as substitution, a judgment inside the safe band
answers the expired question with its recommended option instead of returning no answer. An earlier
draft of this section said the opposite, that slice 2 would downgrade a judged-unsafe interaction to
`.returnNoAnswer`; the gates in the calibration report were written against that reading and have been
re-specified. The enum stays pure and unit-testable, and the async work sits at the call site that
already awaits a timer.

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

Three DEBUG-only keys in `Sources/RepoPrompt/Infrastructure/MCP/AppSettingsMCPService.swift`,
following the `agent_mode.claude_raw_event_logging_enabled` precedent:

- `judgment.shadow_enabled` — bool, default false.
- `judgment.shadow_log_file_path` — raw text, empty clears the override and logging then writes to a
  non-workspace temp debug directory.
- `judgment.api_key` — raw text, write-only. A write stores the key in secure storage under the
  `typeSafeSystemOneAPI` account; an empty or whitespace-only value deletes it. A read returns the
  presence indicator `set` or `not set` and never the key, so the secret cannot reach
  `app_settings list` output or a diagnostics dump. This key exists because `KeyManager.saveAPIKey`
  is keyed on `AIProviderType` and registering this model there is prohibited, so without its own
  writer nothing in the tree could ever store the key and every record would say
  `judgment_available: false`.

No release-build surface and no Settings UI in slice 1. The feature has no user-visible effect yet, so
it needs no user-visible control.

### The calibration gate

Slice 1 is finished when the recorder has collected **at least 100 human-answered interactions** and
a report states all three numbers. The floor is counted in interactions, not records: the recorder
writes one record per question and `ask_user` accepts up to 10 questions per interaction, so records
are clustered within an interaction and 100 records can be far less evidence than 100 interactions.
The report states the record count alongside the interaction count. Overall records carry no floor;
safe-band records do, because that is the subset gate 1 is computed over — at least 50 of them, from
at least 30 distinct interactions, which also bounds how concentrated the clustering can be.

Slice 2 proceeds only if all three gates hold:

1. Among questions the rubric judges safe to auto-answer, the **Wilson 95% lower bound** on the rate
   at which the person picked the recommended option is at least 80%, over at least 50 safe-band
   records drawn from at least 30 distinct interactions. The bound is the gate rather than the rate,
   because a bare point estimate can pass on almost nothing: 27 of 30 reads as 90% and is consistent
   with a true rate near 74%. In practice the bound asks for 46/50, or 90% once there are 75 records.

   The safe band for this measurement is the initial proposal `needs_human_authority` at or below
   0.15, and `recommended_option_risk` at or below 1.0 with score confidence at or above 0.7. These
   three numbers exist to make the gate measurable, not because they are known to be right; slice 2
   may move them anywhere the report's distribution supports. Evaluate the band as pre-registered —
   a band refitted to the data that validates it is a hypothesis for a second collection window, not
   a pass.

   **A skip counts as a disagreement**, in the denominator and against the rate. A skip is a person
   declining to choose, and slice 2 would substitute the recommended option in exactly that case, so
   a skip is precisely where an auto-answer would act. Excluding skips would inflate agreement on the
   questions people found least answerable.
2. Disagreements concentrate outside that band. If judged-safe and judged-unsafe cases disagree with
   the human at similar rates, the confidence signal carries no information and the thresholds are
   arbitrary.
3. No safe-band record puts more than 0.20 combined probability on risk levels 2 and 3. The
   threshold is zero such records.

   Gate 3 is about the recorded distribution, not about the point estimate. The safe band already
   requires `recommended_option_risk` at or below 1.0, so "a safe-band record the rubric rated 2 or
   3" is empty by construction and would pass without measuring anything. Reading the tail of
   `probabilities` instead catches the case the gate is for: a judgment whose expected value sits in
   the safe band while it holds real probability mass on an irreversible outcome.

If the gate fails, the seam is deleted rather than kept as dead code, and this document records the
measured result. Keeping an unused network seam is worse than having none.

Rubric wording may be revised and re-measured before the gate is called, but a revision resets the
100-interaction count. Every record carries `catalogue_version`, a fingerprint of the exact wire
bodies of every catalogue entry, so a revision is visible in the data rather than remembered: two
records with different values were judged against different rubrics and must not be pooled.
Synthetic questions replayed from real transcripts may be used to sanity-check rubric wording; they
must never contribute to the accuracy number.

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
- `JudgmentCatalogueRedactionTests` — the serialized payload's key set equals the catalogue's
  declared set for each entry; `allQuestions` covers every question any `JudgmentRequest` case asks;
  the catalogue fingerprint tracks rubric wording.
- `JudgmentPolicyTests` — every `JudgmentError` case maps to `nil`; no key means no call.
- `AskUserExpiryBehaviorResolverTests` — the resolver returns the configured behavior unchanged in
  slice 1, for every combination of judged answer, including a stub that throws.
- `JudgmentShadowRecorderTests` — a recorded interaction returns the same `AgentAskUserResponse` as
  an unrecorded one; a record carries the observed model version and the catalogue fingerprint; each
  row's `picked_recommended` is computed from its own question's draft.

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
