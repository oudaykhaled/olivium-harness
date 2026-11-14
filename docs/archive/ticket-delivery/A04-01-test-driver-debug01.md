# A04-01 setup test-driver debugging

This is a separate bounded sequential audit, reset from the resolved A03 work. Root is the sole check runner, runtime operator and board writer. The debugger changes only `test/harness_forge_web/setup_live_test.exs`; product source and dependencies remain unchanged. No formatter, tests, browser, runtime, network or board actions were run by the debugger.

## Retained facts

Root check 59 retained 75 tests, four failures, 6.5 seconds and stable source hashes. The current test hash matched that check before editing: `c67707fb8307d6561b833814a12a220b2fe9034f359fe3152efefbcd4d191d78`. A separate before-copy is retained in `tmp/ticket-delivery/A04-01/debug/iteration00-setup_live_test.exs`; original check 59 receipts, UI source-01 copies and prior accepted work remain untouched.

Two failures occur inside LiveViewTest's select validation before a production command: the driver submits the assigned goal while its rendered options contain only the blank choice. Current `SetupLive.choices_for/2` derives repository options from the locally selected project and goal options from the locally selected profile/project. `setup_edit` clears dependent inputs when those parents change. Installed LiveViewTest `client_proxy.ex:1338–1369` collects the real form defaults, validates supplied values against rendered controls and merges only those supplied values. A single all-fields submit bypassed the required preceding UI changes in the driver, but the DOM validator correctly refused it.

The third failure is a mount response mismatch: an unauthorized candidate route returns `{:error, {:live_redirect, %{to: saved_outcome_path}}}`, while the test expected an already mounted view and subsequent patch. The fourth failure expects old error copy superseded by approved UX review block 12. Decision01 preserves separate note/choice save commands, authoritative saved navigation, exact reference acknowledgement and unavailable later steps; UX review01 changes copy/classes without altering authority.

## Hypothesis and attempt 1

The leading hypothesis is incorrect test driving and expectations, with no production fault established by these four failures. The helper now emits DOM-validated form changes in dependency order: profile, project, repository, goal; or corpus followed by declaration. Each change supplies only its selected field plus the existing note fields, allowing real rendered options to update while retaining the exact tokens and note. The final submit still uses the original complete inputs and original save/change command. No raw forged event replaces real control validation, and no preliminary event persists or acknowledges choices.

The forged-route test now asserts the exact live redirect destination equals the original saved path, follows that redirect, and then executes all existing outcome/version/draft, malformed-version and forged-owner assertions. Its original saved version remains the expected version. The unsent-navigation assertion now matches the approved phrase `Back and Continue do not save changes`; its no-version-write, privacy invalidation, session invalidation and zero-dispatch checks remain unchanged.

All remaining assertions are unchanged, including refresh/fresh-auth restoration, exact selected reference pins, explicit corpus/declaration acknowledgement, unavailable later-stage shell, two-tab conflict and local-note retention, stale catalog pins and meaningful primary-action priority. No test was skipped, retried or given a larger timeout. A mechanical exact-diff receipt verifies that only these three bounded blocks changed.

Prediction: normal control changes populate each dependent select before it is selected; redirect/copy checks reach and retain their original authority assertions. Root's next immutable focused check and formatting are pending on the frozen bytes. A failure after those corrections requires a new sourced iteration or explicit product ownership coordination; it must not be hidden by weakened assertions. Four implementation attempts remain. Test-file ownership is released to Root for verification.

## Iteration 2: scope option dependency

Root formatted attempt 1 in check 60, then check 61 retained 75 tests with one failure in 6.7 seconds and stable source hashes. All original Root59 failures were resolved. The newly reached assertion looked for `Saved coverage revision` before selecting any corpus, although both initial selections correctly remained blank. `choices_for/2` intentionally exposes no declaration rows while the local corpus is blank (`SetupLive:566–569`), and `clear_dependents/2` clears the declaration when a corpus changes (`416–417`).

The formatted pre-change test hash `0b3dad6e30cc77642ba6301f5b873223372cfabde7b2ea490e0a35f5160fb62a` matched check 61 exactly and is separately retained in `iteration02-before-setup_live_test.exs`. Original check 61 RED and all earlier receipts remain unchanged.

Attempt 2 adds only the normal corpus-select form `render_change` before the existing coverage-option assertion. Both original initial-blank assertions remain. A new assertion explicitly proves the declaration remains blank after choosing that corpus; merely revealing an option never selects it. The later normal Save note/Save choices driver, exact declaration digest/current-scope pins, unavailable-stage and zero-dispatch assertions are unchanged. No raw event, seeded state, option-validation bypass, retry or weakened assertion was added.

Prediction: choosing the corpus reveals its checked coverage option while preserving explicit declaration choice. Root's next format and focused check are pending on the frozen test bytes. No production, formatter, test, browser, runtime or board operation was performed by the debugger. Three implementation attempts remain, and ownership is released for Root verification.
