# Iteration 11 code correction addendum 01

**Disposition: CODE-11-01 closed for frozen candidate03. No remaining Blocking finding in this correction; CODE-11-02 remains Non-blocking and unresolved.** This is the same reviewer's scoped source/evidence followup, not a fresh full implementation audit, runtime PASS or installation approval. Original report/audit remain unchanged.

Bindings: packet02 SHA256 `36476cdcb15d83feffc4da42bc1e795826b5b23ea0f13069fb9056020b525121`; source-freeze03 manifest SHA256 `56c66ad2ff28e6fd32f4b68ee91c2f53c9e35c2e728b94217e82238b28fb1c97`. Below, `S3 = tmp/enhancement-program/11/source-freeze-03/`; `E2 = tmp/enhancement-program/11/qa-final-inputs-02/tmp/enhancement-program/11/`.

## Blocking — resolved

`S3/lib/harness_forge/company/assessments.ex:283–325` now uses the same cumulative ancestor traversal for creation and stored reads. Root obligations seed an ID-to-definition map. Every descendant checks all accumulated definitions before merging its own; omission does not remove a reservation. Changed reappearance returns `invalid_input` at creation; an otherwise hash-valid conflicting stored chain returns `invalid_record_hash`. Neither path repairs history or reassigns observations.

Each ancestor still passes scoped `Store.get`, canonical payload/hash validation, family equality, seen-ID cycle detection and the `length(seen) < 100` guard. Thus a 100-node chain remains allowed by the traversal and a 101st node is refused; ordinary creation additionally retains the workspace cap. Existing fences and receipt/hash/authority contracts remain unchanged. These boundary conclusions are source review, not new exhaustive runtime tests.

The four added cases at `S3/test/harness_forge/company_assessments_test.exs:421–507`, with helpers at600–647, test changed reuse after omission with no rubric/audit insertion, exact-meaning reappearance, changed meaning under a fresh ID, and directly inserted hash-valid conflicting history refusing get/list/new_attempt. Raw receipt payload BLOB/full-row equality and captured payload/hash preservation prevent a passing test through history rewriting. Existing immediate-predecessor checks remain at348–387.

The red evidence is meaningful: `E2/checks/family-id-red-01.stdout.log` shows the exact refusal assertion instead receiving a new current rubric; one test/one failure, exit2, against the previous domain hash. The corrected focused run records52 tests/0 failures. Final canonical03 records792 registered/777 passed/0 failed/15 existing optional Docker skips. Command source hashes match freeze03. Format, warning-gated compiler and Credo-warning exit0. Dialyzer retains the same two releases.ex opacity diagnostics; full-style Credo is not claimed clean. The successful canonical log retains its SQLite lock message.

## Non-blocking — retained

**CODE-11-02 remains open.** A shared cumulative traversal establishes correctness; list/DTO paths still repeatedly traverse lineage under the workspace fence. The cap bounds the work, but neither the new tests nor native evidence measures cap-sized history latency. No performance resolution is inferred.

## Nit

None.

## Praise and bounded native evidence

Only assessments.ex and its domain test differ from freeze02. Candidate03's supplied build inputs match current source; its four build steps exit0,57 static hashes match and142 retained-module chunk sets match. Root's native identity is candidate03 PID32905, provider32904, numeric loopback8879/8880, workspace `b34fb543-f41a-4b44-858d-0debf8207cb6` (`E2/native-start-03.json`). I did not inspect live processes.

I inert-compared startup and final projections: startup preserves all32 tables; the Chrome attempt adds exactly one receipt and one audit, with the other30 projections,18 artifact files and8 external export files unchanged. Root's read-only observer separately asserts the original two rubric/four receipt/39 audit rows stayed raw-identical. Its first wrong audit-action expectation failed and is retained in `E2/record-native-correction03-attempt01.json`; only the observer label changed. The final observer checks the existing `company.assessment_recorded` action.

Receipt `07843c10-bc81-4a78-889a-d7bb862d09d4` displays all four fixed synthetic observations and explicit owner-report limits; saved/reopened text files are byte-identical. Protocol08 contains three correlated missing/duplicate/extra-ID refusals; I compared every supplied32-table before/after pair, all equal. See `E2/root-native-correction-verification-03.json`, `browser03/001–004` and `native-authenticated-malformed-ids-08.json`. This supports the bounded correction regression, not real semantic grading or SDK qualification.

False structurally accepted testimony, successor-notice/dense-authoring debt and native02 responsive-matrix provenance remain. Main11 is not installed; official completion remains10/50. No product execution, app/helper import, test, browser/HTTP/DB/process operation, peer addendum or subagent informed this review. The updated retrieval priority was read as context without selecting a future scope.
