# A04-02 Models / Setup review 01

**Blocking:** None identified in the bounded interfaces inspected. **Verdict:** Approve this frozen Models/Setup source scope, subject to Root’s independent current verification. This is not full-ticket, installation, provider-quality or scale acceptance.

**Evidence.** `SetupRuns.command/2` authenticates before receipt replay, checks both versions and exact run identity, commits registrations before execution, and never re-executes matching commands (`setup_runs.ex:54–77,254–309,959–1046`). Authorization joins accepted command/CAS, immutable preparation, disclosure and the one budget in one transaction (`run_authorization.ex:234–327,758–792`). The corrected SHA256 root fingerprint is validated at `:923–950`.

Prepared synthesis preserves its reviewed manifest and exact request bytes (`run_authorization.ex:132–176,481–533`; `analysis_v2.ex:65–147`). Compatible consent reuse requires the same owned stage/context and covered sources; current validation remains separate. Registered retry operations resolve one trusted budget, with no missing-binding fallback (`run_authorization.ex:590–646`; `ledger.ex:158–182`). Positive request/token limits and zero local cost are supported; unknown usage remains charged. Cancellation, expiry and final publication checks prevent retained history from restoring authority. StageControl binds authorization, budget and operation digest; the gateway supplies a final dispatch guard.

Legacy entry points reject setup IDs/pins before new budget or manifest work. Retirement-marker lookup extends that denial after setup content deletion, including the unregistered-operation budget fallback (`run_authorization.ex:590–628,648–752`). This covers the Models side of the purge decision; it does not independently approve marker production, purge or restore implementation.

Setup GET/history and inspected LiveView remount paths perform reads without acquisition or model dispatch. Explicit event envelopes bind displayed preparation, versions and generation; server commands remain authoritative. Session selection/outcome changes invalidate admission. Claim and plan decisions remain separate. Async completion reloads current saved state rather than trusting the returned receipt as authorization.

**Tests inspected, not executed.** New persisted-fixture tests cover exact authorization/replay/rollback, changed destination, consent withdrawal, same-pin replacement, distinct operations sharing one budget and exact bytes, uncertain-use retry denial, cancellation/R01 withdrawal during transport, read-only remounts and stale tabs. Their HTTP protocol doubles do not qualify a real provider. Expiry/restart and every foreign-owner interleaving were not independently exercised by this review.

**Non-blocking:** `run_authorization.ex:178–190` loads all compatible preparation candidates before selecting a reusable pin. A long-lived session with many explicit replacements can increase read latency and memory. A bounded paginated scan can preserve reuse semantics; this is not a first-slice blocker.

**Nit:** None. **Praise:** Durable intent, immutable prepared bytes, mutable CAS state and usage settlement have distinct responsibilities and reuse the existing engines.

**Limits.** All 14 inspected source/test files matched their frozen copies and manifest pins. Full RunAuthorization, SetupRuns, Ledger and StageControl were read; adjacent AnalysisV2, StageAuthority, SetupSessions and SetupLive coverage is range-limited in the audit. Capture/Privacy/migrations and unrelated graph paths are outside this approval. Full165 had no completion result when read; no current full-suite PASS is claimed. No execution, source edits or external actions occurred. Ownership released.
