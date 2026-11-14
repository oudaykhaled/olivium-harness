# Authenticated native protocol recipe — source only

This is an unexecuted recipe for root's bounded, owned candidate02 check, not browser evidence or SDK qualification. Installed primary sources identify Phoenix1.8.16 and LiveView1.2.13. No application/helper imports, requests, browser credentials, secrets or runtime were inspected. Reads were scoped to the cited source seams; package/tool availability was inspected as filesystem metadata only.

1. **Normal login.** Fix the origin to `http://127.0.0.1:8879`; reject redirects outside it. GET `/login` with an in-memory cookie jar. Parse `#login-form`'s hidden `_csrf_token`; POST `/login` as URL-encoded `_csrf_token` and `access_code`, with this origin and `/login` Referer. Root alone reads its already-authorized QA access-code file. Retain renewed Set-Cookie values only in memory. Follow the successful redirect with GET `/`: SessionController renews the session and deletes the previous CSRF state, so extract this new page's `meta[name="csrf-token"]`, not the login token. Extract the root element's `id`, `data-phx-session` and `data-phx-static`; empty static means null. Never print/save this HTML, headers or values.

2. **Normal WebSocket join.** Open `ws://127.0.0.1:8879/live/websocket?_csrf_token=<URL-encoded fresh CSRF>&vsn=2.0.0`, carrying the fresh cookie and exact HTTP Origin. Existing installed Playwright1.60.0's `/opt/homebrew/lib/node_modules/playwright/node_modules/playwright-core/lib/utilsBundle.js` exports `ws`; it can supply normal Cookie/Origin upgrade headers without a browser or installation. This is a source-observed internal tool path, not a supported Playwright API promise.

   Phoenix text frames are `[join_ref, ref, topic, event, payload]`. Use increasing string refs and topic `lv:<root-id>`. The join ref is the join push's ref. Send `phx_join` with:

   ```json
   {"url":"http://127.0.0.1:8879/","params":{"_csrf_token":"<fresh in-memory value>","_mounts":0,"_mount_attempts":0},"session":"<root data-phx-session>","static":null,"sticky":false}
   ```

   Supply the actual nonempty static attribute instead of null when present. Require the matching `phx_reply` with status `ok` and `response.rendered`. No reconnect/auth fallback. A short bounded run can close normally; if it exceeds the heartbeat interval, send ordinary `phoenix`/`heartbeat` frames and correlate their refs separately.

3. **Use the installed diff renderer offline.** Reuse `deps/phoenix_live_view/assets/js/phoenix_live_view/rendered.js`, bundled by the existing `_build/esbuild-darwin-arm64` for Node/CJS; root may create its isolated public-code bundle, with no install or product modification. `Rendered.extract(diff)` removes reply/events/title metadata; initialize `new Rendered(rootId, extracted.diff)` from `response.rendered`, then call `mergeDiff(extracted.diff)` for every reply `response.diff` and unsolicited `diff` frame, in receive order. For a complete in-memory HTML snapshot, use:

   ```js
   const tree = rendered.get();
   const html = rendered.recursiveToString(tree, tree.c, null, false, {}, null).buffer;
   ```

   Ordinary `toString()` enables skip optimization and may omit unchanged content. Full rendering above disables root skip; component traversal with no `onlyCids` also marks components for rendering. Use a real HTML parser, such as existing Python stdlib HTMLParser over private in-memory IPC, to extract only named controls. Keep renderer diagnostics/errors sanitized: installed diagnostics can otherwise reference browser globals or malformed HTML. This bundling/rendering approach is source-derived and has not been executed here.

4. **Root events, with no component `cid`.** Send outer event `event`, payload `{type:"click",event:"tab",value:{tab:"company",value:""}}`. From the resulting view take the current generation and exact intended successor's Open button. Send `assessment_history_open` with its `rubric_id`, `assessment_event_generation` and empty outer button `value`. Then send `assessment_attempt_start` with the newly rendered rubric ID/hash, generation and empty button value. Obtain attempt ID/token only from that view's `#company-assessment-results-form`. The router's OperatorSession hook checks each parent event; Portal derives authorization/session fingerprint itself. Do not send a component `cid`, synthesize an attempt or reuse another view's generation.

5. **Three malformed result events only.** Build URL-encoded nested form fields from that results form: outer `assessment_event_generation`; `assessment[rubric_id]`, `[expected_rubric_hash]`, `[attempt_id]`, `[attempt_token]`, `[task_status]=completed`, `[critical_status]=none`, `[judgment]=accepted`; and dense `[results][0..N-1][obligation_id|status|observation]`. Use `met` and the four nonblank public oracle observations. Missing: remove one result and reindex densely. Duplicate: append one repeated valid row. Extra: append one otherwise valid row with a new bounded unknown ID. Keep every other value valid/current and total rows below20. Do not append a transport-level empty value field to a form.

   Send `{type:"form",event:"assessment_record",value:"<URL-encoded fields>",meta:{}}`. The channel decodes bracketed fields into maps before the parent handler; a JSON result list or sparse indices would test a different refusal.

6. **Correlate intended refusal, then persistence.** A channel `ok` can contain an application refusal diff. For each matching event reply/ref, merge/render and require `#company-assessment-error` with this exact fixed text:

   > Enter one explicit result for every frozen obligation, with no missing, extra or repeated obligation IDs. Review the identified obligations below.

   That is the presentation mapping for `invalid_obligation_results`, not a returned wire error atom. Root takes its all32-table/receipt/audit baseline after ordinary login/join/history/attempt setup and compares each bounded invocation window. Save only sanitized case/ref/status, expected-message match and nonmutation results; never raw frames, HTML, cookies, CSRF, attempt tokens or exception/request dumps. Close the owned client without logout, since logout rotates the shared workspace epoch. Stop on normal login/join/render failure rather than changing authentication.

Primary source seams: session_controller.ex:14–24; session_html.ex:22–35; router.ex:4–31; endpoint.ex:8–20; local_origin.ex:8–29; operator_session.ex:38–59; assets/js/app.js:116–120; Phoenix serializer.js:12–26 and constants.js:4; LiveView view.ts:203–247,1490–1550,2015–2027,2388–2396; rendered.js:25–90,121–161,358–418,490–528; channel.ex:244–260,567–590,910–932; CompanyAssessmentState capture_results/indexed; Assessment.ex:59–60,624–631; PortalLive:69–73,1049–1057.
