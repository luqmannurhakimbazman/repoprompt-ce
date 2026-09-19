# System One judgment calibration report

Spec: `docs/architecture/system-one-judgment-seam.md`
Plan: kept locally under `docs/designs/`, which this repository git-ignores.

Fill this in from the shadow JSONL before proposing slice 2. Slice 2 proceeds only if all
three gates hold. If they do not, the seam is deleted and the measured result stays here.

## Sample

| Field | Value |
| --- | --- |
| Records | |
| Human-answered records | |
| Expired records | |
| Skipped records | |
| Observed model versions | |
| First record | |
| Last record | |
| Rubric revision count during collection | |
| Total input tokens | |
| Total cost | |
| Median judgment latency | |

A rubric revision resets the count. Records from more than one model version must be
reported separately, not pooled.

## Gate 1: agreement inside the safe band

Safe band, as proposed by the spec: `needs_human_authority` at or below 0.15, and
`recommended_option_risk` at or below 1.0 with score confidence at or above 0.7.

| Measure | Value | Threshold |
| --- | --- | --- |
| Human-answered records in the safe band | | at least 100 |
| Of those, the human picked the recommended option | | at least 90% |

## Gate 2: the confidence signal carries information

| Band | Records | Human picked the recommended option |
| --- | --- | --- |
| Safe band | | |
| Outside the safe band | | |

The two rates must differ materially. If they are similar, confidence carries no
information on this workload and the thresholds are arbitrary.

## Gate 3: no judged-safe high-risk case

| Measure | Value | Threshold |
| --- | --- | --- |
| Safe-band records the rubric rated at risk level 2 or 3 | | 0 |

## Verdict

- [ ] All three gates hold. Slice 2 may be brainstormed, with thresholds taken from the
  distributions above rather than from the spec's initial proposal.
- [ ] A gate failed. Delete `Infrastructure/AI/Judgment`, the recorder, the settings keys,
  and the four wiring edits, and record the measured numbers above as the reason.
