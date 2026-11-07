# Iteration 02 acceptance: Company guidance

**Benefit.** Replace Company’s always-complete workflow and claim-only decision metric with persisted-prerequisite progress, separate pending claim/plan counts, and one keyboard-reachable next action. Progressively disclose existing forms while preserving section access and drafts. Goals and milestones remain optional; build, integrity, runtime, evaluation and release stay distinct.

| Synthetic state | Minimum assertion |
| --- | --- |
| Empty | No setup step appears complete; action reaches first required control; claim/plan counts are separately zero. |
| Partial | Completion reflects persisted records; action targets missing required input; optional goals do not block. |
| Proposed | Counts separate claims/plans; action reaches exact-revision review; proposed plans cannot build. |
| Rejected | Rejection is visible, excluded from pending/approved, and offers revision without implicit approval. |
| Approved | Action reaches build/export; integrity is not runtime qualification; approved predecessor survives proposed successor. |
| Stale | Affected revision and recovery are visible; stale authority cannot build/export or fall back to broader scope. |

Extend `company_builder_test.exs` with transitions against persisted Company/Evidence records and LiveView controls: stale hashes, rejected decisions, tampered submissions and draft survival. Assert `Company.build_inputs/1` refusal and immutable artifact behavior. The LiveView event contract is the contract surface; no OpenAPI schema exists here. Add authenticated `curl --fail-with-body -sS --max-time 30 -w` page smoke with status/timing recording and unauthenticated write denial. Define a timing budget before claiming an SLO.

Capture native Chrome screenshots and DOM/action logs at baseline and narrow widths for empty, proposed and stale journeys. Record keyboard-only Tab/Enter/Space traversal, visible focus, focus after section changes, error-summary reachability and retained drafts. Report browser version, viewport, commands and failures. Synthetic operator evidence cannot establish a novice study or accessibility certification. Use the default short test workspace; the prior 117-byte socket-path failure was QA setup error.
