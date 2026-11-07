# A03-01 browser readiness debugging

This is a new bounded single-debugger task, separate from the accepted privacy and test-helper fixes. Root owns the browser, test runner, runtime and boards. Only the Home CLI test is changed. Imported/generated content remains data; the debugger performs no browser action, provider call, generated-code execution, secret access or runtime mutation.

## Retained observations

Root reports current source 10/candidate 06 already passed the 60-test focused check, format/build and scoped Astra11 review. Real MCP checks observed all three viewport geometries, keyboard focus and disclosure/demo Tab access. CLI check 52 passed Home; check 53 passed artifact delivery; the independent repeated Home check 54 failed after its single Enter on the primary action. These observations do not establish complete tool reliability.

The actual text/JSON report `tmp/ticket-delivery/A02-browser/home-cli-output02/report.json` records the final `app.open('/')` completing at 17:57:44.484Z, static visibility passing by .510Z, and the primary Enter starting at .512Z. At .547Z, that exact step 22 logged `no component found matching phx-target of 1 {target: 1}`. Its focus assertion never reached `company-plan-review-step`. No readiness condition preceded those actions. Root separately reports no server errors or artifact/model-request changes; the debugger has not operated or inspected private runtime state.

The original test and complete original RED report are separately preserved as `tmp/ticket-delivery/A03-01/browser-debug/iteration00-company-home.e2e.ts` and `iteration00-red-report.json`; check 54 and its original report remain untouched. No screenshots were inspected.

## Source-backed hypothesis

Installed Phoenix LiveView source defines `phx-connected` and `data-phx-main` in `constants.ts:37–43`. In `view.ts:623–647`, `applyJoinPatch` applies the connected DOM patch, mounts children/hooks, clears `joinPending`, dispatches events and applies pending updates before calling `hideLoader`. `hideLoader` sets the public `phx-connected` class at `view.ts:329–334`. The observed component error comes from `withinTargets` at `view.ts:378–399`, when the current component DOM target cannot be found; `dom.ts:105–112` shows the exact DOM lookup. These installed sources are pinned by SHA256 in `iteration00-facts.json`.

The leading hypothesis is therefore a missing connected-LiveView precondition in a test that repeatedly reloads and acts on SSR-visible HTML. The alternative remains a product routing fault after a completed connected join. A passing action after an observable wait supports the first hypothesis; the same failure after readiness requires reporting/escalation rather than additional clicks or weakened assertions.

## Implementation attempt 1

Three read-only `expect.poll` statements now require the current document to contain `[data-phx-main].phx-connected`: after the initial authenticated Home-open/login branch, after every viewport-loop Home open, and after the final Home open. This waits on a public DOM state set after the real join patch, using the existing assertion timeout. It does not read LiveSocket/private globals, mutate the app or dispatch an action.

Every existing interaction, single primary Enter, exact focus expectation, selected-goal caveat, geometry/count/fold assertion, demo disclosure/Tab assertion and navigation assertion is unchanged. No sleeps, action retries, extra Enter, timeout increase or production handler/source changes were introduced. Existing trace/video settings remain unchanged.

## Root-observed verification

Root independently ran the corrected frozen test twice: check 55 (`home-cli-output03`) passed in 4.07 seconds, and separate check 56 (`home-cli-output04`) passed in 3.62 seconds. Root reports all 385 product source pins unchanged and zero model tokens in both runs. Both passes retain the original viewport geometry, exact focus, single Enter, help disclosure, demo Tab and navigation assertions. Check 54's failed run and its original report remain retained; no failure was overwritten or converted to a pass.

These two independent passes support the missing connected-readiness precondition diagnosis for this test. The early-click/loading affordance remains open under the existing A03/A04 acceptance work: this test precondition does not make an SSR-visible action safe for a human who activates it before connection. No full reliability or company/task effectiveness claim follows from this correction. Four implementation attempts remain if a new failure occurs. The debugger releases its sole test-file ownership and performs no further test, browser, runtime or board action.
