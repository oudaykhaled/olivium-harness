# Browser outcome and repeatable regression review

**Blocking — P2, regression only:** `tmp/ticket-delivery/A02-browser/tests/generated-artifact.e2e.ts:51` reads an attempt-relative download path against the process working directory. The available runner report records ENOENT at this line: one failed test, zero passes. Resolve the download through the runner’s supported attempt-artifact location/API before reading bytes. The download event passed, but ZIP assertions and narrow geometry never ran.

**Blocking — P2, repeatability:** The fixed `repeatable-download01.json` destination with `flag: 'wx'` at lines61–62 will fail on the second successful invocation. Use an attempt/run-specific evidence destination, retaining prior receipts. Verify two consecutive runs without manually deleting evidence.

**Non-blocking / proof limits:** Lines52–58 check ZIP magic and minimum size, then record its hash; they do not compare archive entries or contents with the immutable artifact. Keep the separate exact-byte comparison as the integrity evidence, or add an explicit expected-entry/content comparison before claiming this regression verifies exact ZIP bytes. The test verifies the eight displayed paths, one instructions passage, three historical statuses and qualification disclaimers. Geometry assertions cover 320px width and vertical Download placement, not 390px, all controls, or a novice journey. It reuses the existing artifact and may reuse an authenticated session; the login branch was not exercised in the available run.

**Nit:** None.

**Praise / boundaries:** The config and test use normal access-code UI authentication when required; no cookie injection, protection override, model step, provider call, or generated-code execution appears in the reviewed source. Export bytes are read as data. Browser evaluation is limited to DOM geometry. The report records zero model tokens. Its automatic failure screenshot is marked redacted; I did not open it and cannot independently certify its contents. Trace/video being disabled does not suppress all runner failure screenshots.

`connected-browser-result02.json` and `WEB_EVIDENCE.md` clearly separate synthetic connected-browser success, historical PASS/BLOCKED checks, current qualification limits, and baseline versus focused suites. They support a bounded recorded outcome, not a new independent browser reproduction by this reviewer; linked evidence was not recursively inspected.

**Verdict:** Preserve the recorded bounded WEB outcome; changes requested before calling the repeatable CLI regression passing/repeatable. No product defect established. Only assigned review artifacts were written; implementation and runtime ownership return to Root.
