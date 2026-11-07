# WEB harness outcome handoff

The Company page is now the default home. Five primary navigation actions lead through Scope → Sources → Review → Your harness → Checks. Existing navigation IDs and event handlers remain in use. Chat, goals, releases, audit and privacy remain accessible under the native “More workspace tools” disclosure. Navigation does not report completion.

A successful Company plan build shows **Open your harness** and **Download ZIP** for the digest returned by that build. Existing package rows offer the same actions. The standard browser download requires no filesystem destination; the existing contained local export is retained under “Advanced: export to a local directory.” Exact claim and separate exact plan decisions remain unchanged.

`HarnessForgeWeb.HarnessLive` presents the verified artifact through `HarnessForgeWeb.HarnessDelivery.preview/1`. Root owns the preview route and authenticated download route; the delivery service owns current artifact verification, purge readiness, bounded text and ZIP bytes. The LiveView checks operator authentication and server workspace on each load and event, and checks them again before assigning returned files. Failed reads clear displayed files. Existing privacy/company invalidations clear bodies; operator-session revocation clears bodies and redirects to login. There is no cached-body fallback.

The page lists the exact generated filenames and escaped text, with native disclosures for each file. Truncation is explicit and the ZIP retains complete bytes. Generated availability, current byte integrity and decision eligibility are distinct from representative-task outcomes and release qualification, which this preview labels unobserved. No generated instructions, code or Markdown are executed or rendered as active HTML.

Four new tests in `test/harness_forge_web/harness_outcome_live_test.exs` exercise the real Company plan decision/build → preview → ZIP path, hostile text escaping, session/workspace denial, unavailable artifacts, privacy invalidation and pending-purge refusal, and source/session revocation. They use synthetic documents and real domain commands; no provider or evaluation result is mocked. These tests were authored but **not executed by this worker**, because Root owns the running checks and integration.

Owned-file `mix format` succeeded. The worker performed no service startup, browser interaction, provider call, private import, generated-target execution, board mutation or shared router/config edit. Source hashes and the formatter receipt are saved under `tmp/ticket-delivery/web-outcome/ui/`. Root must execute focused checks, reconcile tests which assumed Evidence was the default home, run appropriate regression checks and capture actual browser/download evidence. This handoff alone establishes neither browser usability at 320px nor representative company/task benefit.

Suggested focused command after Root integrates routes:

```sh
mix test test/harness_forge_web/harness_outcome_live_test.exs test/harness_forge_web/harness_delivery_test.exs test/harness_forge_web/company_builder_test.exs test/harness_forge_web/package_export_test.exs test/harness_forge_web/portal_test.exs
```

## Corpus priority followup

The existing real-browser record `tmp/ticket-delivery/A02-browser/29-coverage320-hf_metrics.json` at 320×844 showed the primary search-mode control at y=2129.80 and its action at y=2173.80, the supplementary `corpus-query` input at y=3563.67, and a later disclosure at y=6532.39. The primary textarea itself was absent from that control measurement. These positions showed why absence of horizontal overflow did not establish usable task priority.

The selected corpus page now keeps project, connection, goal and named optional omissions concise and visible. Existing scope choices and technical capture facts remain mounted under a native disclosure; cold setup opens that disclosure. After capture, the primary question and submit action precede receipt details. Search options and draft limits remain in the same form under a disclosure below the action. Capture failures keep a visible recovery notice and open their controls automatically. All existing authority controls and limits remain unchanged.

Two component regression tests were authored for cold/selected scope disclosure and the captured question/action order, and existing failure assertions were strengthened. Owned-file formatting succeeded. No tests or fresh browser measurements were run by this worker; Root must remeasure the changed layout. Receipt `tmp/ticket-delivery/web-outcome/ui/implementation-format-receipt02.json` preserves receipt01 and records this followup separately.

## Recorded checks beside the exact files

The preview now displays “Previously recorded checks for this exact harness” after its current proof and Download ZIP block. It consumes only the delivery service's bounded, server-selected history metadata. The newest three are visible; any remaining entries, within the latest-ten limit, are available in a native disclosure. Dates, human check labels, recorded outcomes and fixed reason explanations are shown; exact run identities remain under details. Unknown metadata, an empty matching history and an unavailable history read have distinct labels. Arbitrary recorded reason strings are never displayed.

Historical static PASS and runtime/task BLOCKED records do not change the current representative-task and release fields. They remain unobserved here. No automatic evaluation, retry, provider probe or target execution is added. No content was inserted before the existing Download ZIP block, and this cut changes no CSS; Root owns the next actual browser measurement.

Two tests were added to the existing outcome test file. One authors real static-integrity, runtime-smoke and task commands for a Codex target whose managed backend is unavailable, then checks the recorded PASS/BLOCKED display and unchanged qualification boundaries. The other tests presentation-only empty, unavailable and malformed history cases with explicit synthetic metadata. The tests were not executed by this worker. Formatting passed, and receipt03 records source hashes without replacing receipts01 or02.
