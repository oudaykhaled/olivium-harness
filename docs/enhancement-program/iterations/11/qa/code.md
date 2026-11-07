# Iteration 11 independent code review — candidate02

**Verdict: changes requested. One P2 Blocking finding; no Nit findings.** This is a frozen source/evidence review. I executed no product code, tests, app/helper imports, browser, HTTP, process inspection or database operations and read no peer QA reports. Root alone owns runtime confirmation and correction.

References use `S = tmp/enhancement-program/11/source-freeze-02/`, `D = tmp/enhancement-program/11/qa-final-inputs-01/docs/enhancement-program/iterations/11/`, and `E = tmp/enhancement-program/11/qa-final-inputs-01/tmp/enhancement-program/11/`.

## Blocking

**CODE-11-01 · P2 — A removed obligation ID can acquire different meaning later in the same family.** At `S/lib/harness_forge/company/assessment_validation.ex:79–85`, `stable_ids/2` compares only the immediate predecessor. `S/lib/harness_forge/company/assessments.ex:283–287,306–314` applies that same adjacent-only comparison during freezing and lineage validation.

Concrete counterexample: freeze v1 with an additional mandatory owner-authored `release-owner` obligation; freeze v2 without it, retaining the required goal/guidance mappings; freeze v3 with `release-owner` again but different text or kind. Both successor comparisons allow the ID because v2 lacks it. The editable ID and removal controls expose this sequence through ordinary rubric authoring (`S/lib/harness_forge_web/components/company/assessment.ex:454–510`).

This violates the selected semantic-ID contract: “a successor reusing an ID must preserve that obligation's kind/text/mandatory/claim_refs exactly. Changed meaning gets a new ID” (`D/review/implementation-interface.md:42`), also promised in the UI at `S/lib/harness_forge_web/components/company/assessment.ex:350`. The risk is inconsistent identity across linked family history. Earlier receipts still bind their own rubric hashes and retain their original interpretation; this is not a receipt rewrite or trusted-evaluation bypass.

**Fix:** the original domain author should compare reused IDs against every ancestor in the bounded family, and validate the same invariant on reads. Add a three-revision test: changed reintroduction refuses without rubric/audit writes; identical reintroduction succeeds; earlier payload/hash bytes remain unchanged. I sent this exact sequence to conductor/root for serial runtime confirmation. It is source-derived here; no reproducer was run by this reviewer.

## Non-blocking

`list_rubrics/0` repeatedly reloads and hashes ancestor chains; each DTO also validates its successor twice (`S/lib/harness_forge/company/assessments.ex:94–100,294–319,426–445,488–497`). A single family of n revisions therefore requires quadratic ancestry work under the workspace privacy fence, on portal reloads (`S/lib/harness_forge_web/live/portal_live.ex:939–975`). The 100-row cap bounds it, but no cap-sized lineage latency evidence is supplied. Reuse a transaction-local validated graph if this becomes material; latency impact is unmeasured, so this does not block the present slice.

## Nit

None.

## Praise and supported behavior

Exact chosen-plan approval, supersession, binding and reconstructed artifact equality are enforced by `S/lib/harness_forge/harnesses.ex:30–116`; the alias/content traps are covered in `S/test/harness_forge/company_assessment_lifecycle_test.exs:40–91`. Goal coverage includes every selected-goal analysis claim and retains other-goal examined context (`S/lib/harness_forge/company/assessments.ex:173–280`; domain tests:261–319).

Strict nested shapes, UTF-8/byte limits, canonical hashes, complete result accounting and explicit unsuccessful states are implemented. Authorization, origin and token validation precede replay; identical replay precedes mutable eligibility/caps; receipt and safe audit commit atomically (`S/lib/harness_forge/company/assessments.ex:121–138,321–402,409–418,544–585`). The domain/authority tests cover rollback, concurrent retry, substituted pins, session/reset tokens and release rejection. Privacy source-family closure, leaf-first deletion and outer-workspace-only restore rekeying are present; lifecycle tests exercise real backup/restore and pre-feature backup migration.

I independently inert-compared root's native projections: initial three negative outcomes and uncited-drift refusal leave all32 tables unchanged; accepted recording changes only assessment/audit tables. Both predecessor records remain exact after successor recovery. Reconstructed canonical hashes match both public rubrics and all four receipts, including their request digests (`E/native-assessment-successor-correct-reopened.json`). The independent four-obligation oracle matches the initial rubric (`E/oracle/task-oracle.json`; `E/native-frozen-oracle-rubric-01.json`). `E/native-authenticated-malformed-ids-07.json` contains three correlated malformed-ID refusals with equal before/after32-table projections;02–06 retain failed/partial attempts. Protocol evidence is not a Chrome or SDK test.

Root's `E/checks/canonical-02-command.json` binds the frozen source; its actual stdout logs 788 registered/773 passed/0 failed/15 optional Docker skips. Format/compiler/Credo-warning gates exit0; the retained full-style Credo run exits14 and Dialyzer exits2 for existing release opacity diagnostics. SQLite lock messages remain in canonical02/lifecycle03 stdout. The native empty-button failure (`E/browser/012-assessment-continuation-refused.txt:300–308`) and `E/checks/browser-click-red-01.stdout.log` remain retained, followed by the narrowly tested correction in browser-click-green01.

False owner testimony remains intentionally structurally accepted, visibly unverified and isolated from `Evaluation.Run`/release authority. Dense navigation, collapsed successor notice, immediate arbitrary-domain-purge notification, real company/model/MCP qualification and local installation remain outside this review's supported claims.

Packet SHA256 `05068a34bad3daf4c2661132539570bf09e7a10c6e00e26dd4eb10fc4cc09564`; copied source-manifest SHA256 `9320c0077f1f4d948daee4421f29b1326c6f470b0846f3d279b021f447a04f77`. All260 frozen source copies hash-match; this does not claim semantic fullreading of260 files. Exact consumed-byte fingerprints, read modes and repaired truncations are recorded in the companion audit.
