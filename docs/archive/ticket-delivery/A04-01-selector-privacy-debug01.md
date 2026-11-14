# A04-01 selector privacy repair

This is a new bounded single-debugger audit, independent of the closed A04 test-driver work. Root reported driver GREEN63, full GREEN67 (1164 passed, 15 existing skips), and stable source02. Those receipts and source copies remain immutable. Root owns all execution, runtime changes and boards. The debugger changes only `lib/harness_forge_web/live/setup_live.ex`; the Root-authored seventh UI regression is unchanged. No tests, formatter, browser, runtime, network or board operation was executed by the debugger.

## Frozen RED and source-backed cause

The independent Astra review identified a P2 metadata privacy issue. Root check 68 then retained seven UI tests with one failure in 0.6 seconds and stable source hashes: a source-backed profile option was rendered again after revocation and reopening, despite `SetupSessions.get/2` returning nil for its unavailable saved pin. Current source and test matched that RED exactly before editing. Copies and read hashes are retained in `tmp/ticket-delivery/A04-01/selector-debug/iteration00-*`.

The cause is a missing authority check in the WEB selector projection. `SetupSessions.source_access?/2` (`setup_sessions.ex:417–425`) uses the existing `CorpusReview.summary_refs/2` authority to determine source availability before presenting profile/project pins. The WEB's `load_choices/1` instead mapped raw workspace-scoped profile/project catalogue rows directly to IDs, hashes and names. Commands still rejected revoked selections; this repair concerns what the selector discloses.

`CorpusReview.summary_refs/2` (`corpus_review.ex:340–367`) reports unavailable source IDs on a successful observation. Its guarded read (`370–388`) separately returns authorization/read errors. Those cases cannot be merged into an empty-success filter. Each guard owns a database transaction; source observations must begin only after the preceding catalogue transaction has returned, rather than recovering a nested rollback as a successful outer transaction.

## Implementation attempt 1

An existing outer `Purge.synchronize/1` now encloses the metadata load and source observations. The original `Corpora.guard/2` still performs the catalogue read and its caller/privacy checks. It returns raw profile/project rows only to the local checked projection. Once that transaction has ended, each row is checked through the same `CorpusReview.summary_refs(%{"profile_ids" => source_ids}, caller)` used by the service. No eligibility SQL, permission policy, new API, framework, consent path or dispatch path was copied or added.

Only a successful empty unavailable-ID list permits `catalog_choice/1` to produce the row's option metadata. A successful nonempty unavailable list withholds that profile/project row. Actual error tuples propagate to the existing fatal `choices_error` path; malformed observations are fatal as well. No partial result is presented as success after an error. Repository and goal metadata projection, all command handlers and authoritative service validation remain unchanged.

Withheld rows produce the separate nonfatal `choices_warning`: “Some saved choices are unavailable. Review source access.” This warning is visible as a status message, is cleared by reset/revocation and recomputed on reload, and never enters the existing fatal `choices_error`/disabled-Save-choices condition or primary-action selection. Valid unrelated choices therefore remain available for partial acknowledgement. Fatal catalogue/source/scope observation paths clear the warning and retain unavailable/error behavior.

The Root regression remains byte-for-byte unchanged. It must prove both actual reopen and explicit reload withhold the affected option tokens and names, retain nil/unavailable service pins, expose the warning, preserve the unrelated source-free project, and successfully acknowledge that partial choice without provider dispatch. Existing refresh/fresh-auth, exact reference, two-tab/CAS, stale-pins, privacy, loading and primary-action assertions are untouched.

Prediction: Root's retained check 68 turns GREEN while the valid unrelated partial-choice acknowledgement remains accepted. Next unused Root checks are 69 for formatting and 70 for focused verification. No GREEN, deployment or whole-ticket qualification is claimed before those checks. The optional postcommit-observation failure test remains open and outside this fix. Four implementation attempts remain; the frozen source is released to Root for verification.
