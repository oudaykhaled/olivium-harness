# A02-02 declaration review 01

**Changes requested: two P2 blockers; no P1 found.** This verdict covers all sixteen complete source-freeze01 files and the source-freeze02 formatter-only successor. Both immutable copy sets were hash-verified. A02-02 remains In Progress.

**Blocking**

1. **A02-DECL-R01 · P2 — an unchanged WEB save can remove required scope.** `lib/harness_forge_web/live/corpus_review_live.ex:722–733` rebuilds the entire declaration as primary plus at most one optional connection. The backend accepts up to sixteen entries (`evidence/requirements.ex:178–186`), and saved-link restore accepts them, but `restore_requirements_draft/2` at line 840 retains only the first optional entry. Repro: save required primary A with a current complete receipt, required B with a failed zero-member receipt, and optional C with a failed zero-member receipt. Open its saved URL and submit the unchanged form. B disappears from the successor; the membership check cannot detect its absence because it has zero members, and required status changes from blocked to complete. This loses explicit operator intent; it does not bypass admission or consent.

   Fix: make unsupported declaration shapes read-only and enforce that restriction in begin/save handlers, or preserve every unedited entry. Read-only handling keeps this WEB slice bounded; a full sixteen-entry editor is larger work. Regress unchanged submission and forged begin/save, asserting no successor write and no dropped B.

2. **A02-DECL-R02 · P2 — stale saved coverage survives an explicit status refresh.** `lib/harness_forge_web/live/corpus_review_live.ex:910–919` replaces only `readiness`; the saved card still consumes the old `large.declaration` (`components/company/requirements.ex:26–34`). `revalidate_large/1` at line 941 checks corpus/run state, not declaration supersession or receipt-only revisions. Repro: open a complete declaration with an optional omission, create its successor in another authorized tab without a corpus generation change, then click **Refresh capture and index status** in the original tab. Readiness becomes stale, while **Saved selected coverage** still says complete and repeats the old omission. An optional receipt revision change without member changes has the same stale-cache path.

   Fix: recheck the selected declaration and replace its checked DTO, or withhold the saved preview/edit context and omissions on failure. Retain the explicit reference so the view cannot fall back to a single capture. Regress both surfaces after supersession and receipt-only changes.

These reproductions are source-derived. This reviewer ran no product code or tests. Root acknowledged both findings and is implementing fixes; those edits are outside this verdict.

**Non-blocking**

No additional merge concern is raised. Metadata output is bounded, but each selected receipt calls `Capture.read_summary/2`, which also aggregates whole-corpus index counts. Up to sixteen entries repeat that aggregate, and chained LiveView assignments can recompute readiness. Measure this before any physical-scale claim. No latency regression was measured; this is not an additional blocker.

**Nit**

None. Source01→source02 only reformats the privacy-test `Repo.query` options call.

**Praise**

The producer reuses caller/privacy transaction fences, checks explicit declaration and receipt identities, keeps missing outcomes unknown, prevents undeclared active members from completing declared coverage, and blocks optional partial members. Save/read do not call acquisition, synthesis, grants or approvals. The additive table has workspace-qualified foreign keys and immutable update/delete triggers. Purge ordering and quarantine remapping include it, preserving historical payload/digest while revoking restored authority.

All six axes were checked. Correctness/currentness yielded the findings. No new security authority bypass was found in this slice. Performance conclusions are limited to source structure. Tests cover actual local capture, persistence, pagination, invalid scope/revision, partial members, purge/trigger restoration and committed backup/restore mechanics. Declaration audit writes are atomic, and WEB failures remain visible. The ancestor-plan compatibility handling in `Readiness.for_plan/6` was inspected; this review does not request changing it.

Original check04 report/log: **36 tests, 0 failures**, exit 0, with identical before/after source hashes. Retained first RED check02: **32 tests, 3 failures**, covering the index/currentness fixture, repeated queued-receipt fixture, and invisible no-scope WEB error. Complete test source was read independently of these counts. Root also reported canonical05 at 1101 registered, 0 failures, 15 existing skips, and format08 PASS; those later reports were not independently consumed here. Full CI/security/build and fixed-source verification remain Root-owned. No approval is issued.

`tmp/ticket-delivery/A02-declarations/review01-audit.json` records every consumed local input, frozen copies, and current-file comparisons at audit time. Initially all sixteen current files matched source01. Source02 has only the checked formatter change; later Root fixes may differ from both freezes. No runtime, Main installation, browser, company/model benefit, remote connector receipt production, physical-scale or release qualification is claimed. No product source or board was changed; only this report and audit were written.
