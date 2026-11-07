# Iteration 02 impediment removal

Status: interface/ownership blockers resolved for author dispatch; implementation and verification remain pending. Governing ADR: [frozen decision](../decision.md). Contract: [interface freeze](interface-contract.md). Guardrail: [brief](guardrail-brief.md).

| Evidence / actual impediment | Smallest removal | Owner |
| --- | --- | --- |
| `CompanyPanel` already mounts unconditionally and hides via `active`; retention must not be replaced with conditional mounting. | Preserve component identity/DOM across ordinary tab trips. | A/C |
| `Catalog.setup/1` derives form values only from saved payloads; profile/repository/project lack change handlers. | Three bounded draft maps/change events; pinned original hashes; per-form success/discard reset; refuse dirty edit switching. | A/B |
| Parent `reload/1` converts failed loaders to empty lists while retaining `data_errors`. | Pass integer-or-nil claim queue count plus loader errors; child owns plan count. | C/A |
| Plan DTO exposes decision/successor, not current eligibility; render currently enables approved plans without preflight. | One selected approved-plan `Company.build_inputs/1` call on selection/reload, no render I/O; actual mutation admission still rechecks. | A/B |
| `privacy_result/2` conflates backup/restore/purges; hidden component caches survive ordinary update. | Operation-aware reset generation, fixed existing-topic notification for sibling views, full cache clear before fresh loading; preserve harmless backup/validation drafts. | C/A |
| Progressive disclosure can hide error/destination controls. | Fixed-ID server focus event and minimal existing-JS listener; per-form summary focus after submit failure. | A/B/C |

No missing dependency, service credential, schema migration or hosted help is needed. Existing `Company` functions already admit exact immutable revisions; there is no new domain `Admission` abstraction to build. Current approved predecessor behavior is explicitly covered by existing tests and must remain.

Dependency/blast radius: `PortalLive → CompanyPanel → Guide/Catalog/Plan → existing Company/Harnesses/Releases admission`. Changes affect Company presentation and its portal wiring; the small JS listener is page-wide but inert without a fixed allowed focus event. Persisted decisions/packages remain unchanged. Root retains shared infrastructure ownership. This applies the ADR and blast-radius disciplines locally; a cross-repo registry or rollout process is unnecessary for this internal interface.

Split A state/projection, B disclosure/draft/focus rendering, C wiring/regressions into reviewable units near 400 net lines where practical. Rollback reverts presentation/wiring/listener together, with no data migration. No evidence establishes completed implementation yet.

Conductor must serialize focused then canonical Mix checks and independent review. C covers saved/scoped progress, separate proposed queues/loader failure, draft text/checkbox/milestone retention and dirty-switch refusal, stale hashes/malformed browser markers, current versus stale approved plan, eligible predecessor, isolated privacy reset and revoked sessions. Root uses native Chrome for guide journeys, keyboard/error focus, 390px screenshots, 320px overflow and 200% zoom. Privacy fixtures run only in isolated test workspaces; do not purge the main/demo/browser workspace. Existing Docker skips and Dialyzer diagnostics remain explicit limitations.
