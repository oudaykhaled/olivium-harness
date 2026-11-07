# Iteration03 independent code review

**Final corrected source verdict: PASS — source-freeze-02, accepted amendment, final bounded round 3.** Zero unresolved Blocking, Non-blocking or Nit findings. The corrected canonical and static checks pass against the frozen bytes; CR-2 and CR-3 are resolved as recorded below. This is a bounded local source/regression verdict. Root's corrected native interaction acceptance remains pending; no merge, release, hosted CI or company-fitness pass is issued.

**Candidate01 remains CHANGES_REQUESTED; its earlier PASS is withdrawn.** Its transitive Docker probe, timeout, new Dialyzer diagnostics, earlier focused passes and hash audits remain historical records below. The corrected result deliberately loses OpenCode task admission preflight: current task identities, applicability and release admission abstain rather than compute a live runtime identity. Full positive OpenCode task gate parity is not claimed. Pure static/smoke and non-OpenCode branches retain the unchanged gate behavior; no new authority is created.

Reviewed repository AGENTS, PROGRAM, frozen decision, guardrail brief, selected scope, UX contract and impediments. Applied the review severity taxonomy and the correctness, security, performance, tests, observability and operability checklists. Reviewer performed only source/document/log reads and wrote this report; no Mix, services, browser/native operations, source edits, remotes or generated-code execution.

## Provenance and bounded change

Compared candidate bytes with `tmp/enhancement-program/03/source-before/`, then independently verified every one of the 397 snapshot files against `source-before.json`: no snapshot hash mismatch. The repository is wholly untracked, so git diff is not historical evidence. Within the captured source/test surface, the only existing file changed is `lib/harness_forge_web/live/portal_live.ex`; additions are `lib/harness_forge/readiness.ex`, `lib/harness_forge_web/components/package_readiness.ex` and their two dedicated test files. Files absent from the capture are not described as iteration additions.

`mix.exs`, `mix.lock`, Evaluations, Releases.Validation, Compiler, adapters and execution code remain byte-identical to the baseline. No new dependency, schema, compiler identity, release authority, runtime backend or execution path is introduced. Root's actual historical-artifact before/after verification remains required; unchanged source alone is not that behavior check.

Finalized against `tmp/enhancement-program/03/source-freeze-01.json`, captured at **2026-11-01 13:58:02.996918 UTC**, and the actual bytes in `source-freeze-01/`. **At the pre-build candidate audit**, independently hashed all 401 entries, comparing then-current source and frozen copies to the manifest: zero mismatches or missing files. This is a time-specific observation; the post-build overlay metadata changes are recorded below. Baseline comparison at that audit confirmed exactly one changed file, four additions and no deletions. Reviewed frozen hashes:

| File | SHA-256 |
| --- | --- |
| `lib/harness_forge/readiness.ex` | `c4eed2dc575a99b94f4b8b3271895d13c22074b0475b8d8409d02e11bcc04f45` |
| `lib/harness_forge_web/live/portal_live.ex` | `64c53fa79a705ab50d4cda348039dc2964542aae162e72730819f00144f129b9` |
| `lib/harness_forge_web/components/package_readiness.ex` | `32f33eb47cb54dc83db120994f2664e07c7cc7c88f413420a8c73ff982a989bb` |
| `test/harness_forge/readiness_test.exs` | `7a786e5fe01b691aeed2637152a6a8775ffccddb0644af4f63a1b9cad44c1e91` |
| `test/harness_forge_web/package_readiness_test.exs` | `fde2fc0fbcca0119175f78973f2770a9e26ac7e185cefaf0f8a7fd9f9a616dfa` |

## Blocking

**CR-2 — resolved in corrected02; blocking in rejected01: transitive runtime probe.** In frozen01, `lib/harness_forge/readiness.ex:70` calls `Evaluations.applicability/1`; `lib/harness_forge/evaluations.ex:91` reaches `Coding.profile_digest/0`. `Coding.profile/0` at lines 35, 36 and 38 calls private `transport/0` three times. `lib/harness_forge/execution/coding.ex:428` calls `Command.docker(["info", "--format", "{{.OperatingSystem}}"], 3_000, 4096)`. `lib/harness_forge/execution/command.ex:27` may first execute a separate Docker-context lookup with another 3,000 ms timeout. Consequently frozen01 inspection was not a configuration/file-only read: it probed Docker repeatedly in the synchronous LiveView request and under the purge lock. A profile computation could consume up to approximately 18 seconds of command timeout budget before repeated applicability/release checks. Gate reuse and byte-identical shared code did not establish purity.

Concrete fix: after conductor scope selection, provide a genuinely non-probing identity/profile path while retaining existing release authority and historical identity compatibility, or make the smallest explicit contract amendment justified by that limitation. Review all transitive identity/gate calls. Add a regression tracing the actual `Command.docker/3` boundary during inspection, including current identities, selected evidence and release validation; the existing test at `test/harness_forge_web/package_readiness_test.exs:171` watches only named capabilities/availability functions and misses this path. Do not mask the defect by increasing test timeouts, mocking admission or claiming the inspection did not probe.

Verified resolution: the ROOT_ACCEPTED amendment chooses abstention instead of a substituted current identity. Frozen02 excludes OpenCode `/1` at `readiness.ex:105`, and matched task `/2`/Validation at line 198, while preserving actual-record pure comparisons. The low-level context and actual LiveView trace matrices passed both focused and independent canonical execution with matched instrumentation, calibration, delivery/descendant checks and zero prohibited calls. No timeout increase, mock or shared gate/execution change was introduced. This establishes the bounded synchronous inspected paths; shared task identity discovery remains live-bearing outside this inspector.

**CR-3 — resolved in corrected02; blocking in rejected01: new Dialyzer regressions.** Frozen01 `lib/harness_forge/readiness.ex:247` and `lib/harness_forge_web/live/portal_live.ex:470` both reported `pattern_match_cov`: their wildcard branches could not match the inferred return types. These were two new diagnostics, separate from the two accepted baseline `releases.ex` opacity diagnostics. The correction removes the unreachable Readiness catchall while retaining fixed safe atom-error mapping, and routes the Portal read through existing exception-safe `load_records/2`, making invalidation/empty-run fallback reachable for storage refusal. Independent corrected Dialyzer now reports exactly the baseline findings at `releases.ex:47` and `:121`, zero new/removed diagnostics and no suppression. Exit 2 is explicitly baseline-limited, not a clean zero-exit Dialyzer claim.

**CR-1 — resolved.** `lib/harness_forge/readiness.ex:35` originally relied only on `Validation.digest?/1`, whose `$` anchor accepts a final LF after 64 hexadecimal characters. This violated the frozen exactly-64-byte input contract and treated malformed input as an artifact lookup. The author added a binary/exact-byte guard in `digest_reference?/1` at line 46, reused it for projected digests and added the trailing-LF rejection case. No shared validation semantics changed. The amended domain suite passed 20 tests, zero failures (retained attempt 02).

## Non-blocking

None identified within the frozen scope. Existing unbounded run listing and permissive completion/check schema semantics are inherited limitations; the selected unit does not change their authority or claim to harden arbitrary privileged database rewrites.

## Nit

None.

## Historical source assessment — corrected by the blocking findings above

| Axis | Reviewed result |
| --- | --- |
| Correctness | The API requires the exact digest and explicit nil/36-byte UUID evaluation reference. Nil never chooses an existing pass. Verified artifacts, current eligibility, scoped run loading, applicability and release validation use the existing contexts. Different-artifact evidence returns no run identities. Seven stages stay independent; only unchanged `Validation.check/3 == :ok` can pass release admission. Sorted retained bindings preserve any-valid-binding admission rather than making every binding an approval requirement. |
| Security/privacy | The entire read is inside `Purge.synchronize/1` and the existing privacy-ready fence. The artifact-directory lstat prevents the delegated read from creating a missing store. No direct write, audit, export, scheduler, model request or automatic mutation was identified. **The previous no-probe conclusion was wrong: CR-2 establishes transitive Docker commands under this lock.** Digest/label keys and values, enum states, reasons and action destinations remain bounded/allowlisted; raw run/configuration/source/actor/error text is excluded. Scope is hashed. |
| Authentication/freshness | Portal replaces only its inherited event hook with the same `OperatorSession.valid?/1` predicate; invalid events halt through `revoke_operator/1`, clearing readiness before redirect. Inspector authentication precedes generation validation and cached action dispatch. Per-mount random generation rotates on selection, reload, reset and revocation. Pair changes clear the report/action/identities; package change also clears the run. Evaluation reload invalidates changed records; explicit inspection re-reads the domain. Stateless presentation adds no component event cache. |
| Performance | Render presents cached stages and filters loaded runs. Inspect/Refresh avoids the general model-status reload, but **that does not prevent the transitive Docker work in CR-2**. Synchronous probe latency and its purge-lock impact invalidate the previous inspection-path performance conclusion. |
| Tests | Dedicated cases cover explicit selection, gate parity, synthetic positives, malformed references/metadata, identity drift, lifecycle/cleanup, privacy fence, no-write snapshots, stale authority and multiple bindings. LiveView tests cover clearing/filtering, no implicit mutation, reload/reset/remount generations and revocation. **The named-function no-probe trace was incomplete and the canonical suite actually timed out.** Earlier focused green logs do not establish no-probe behavior or current acceptance. |
| Observability/operability | Reports carry exact selected references, observation time, fixed reason codes and explicit limitations. Navigation uses one fixed destination and repeats no mutation. No new service, external boundary, background job, migration or persisted readiness authority requires rollout machinery. Reverting the additive inspector/context has no readiness data migration. Labels and native controls expose all seven independent statuses, full digest/run text, one navigation action and expandable identities/limitations; actual keyboard/viewport/announcement behavior remains root-owned evidence. |

## Evidence and separate acceptance gates

Read the retained author logs directly:

| Evidence | Result and attribution |
| --- | --- |
| `author-a/test-attempt-01.log` | 20 tests, zero failures, 72.5 seconds; before CR-1's amendment, retained as historical evidence. |
| `author-a/test-attempt-02.log` | Corrected candidate: 20 tests, zero failures, 58.9 seconds, seed 883419; command/exit recorded in `implementation-a.md`. |
| `author-b/02-focused-attempt1.log` | 12 tests, 10 failures, exit 2; test helpers submitted a disabled evaluation field and referenced absent Floki. This attempt is retained rather than relabeled. |
| `author-b/04-focused-attempt2.log` | After helper correction to enabled inputs and installed LazyHTML: 12 tests, zero failures, 20.4 seconds, seed 581370, exit 0. Reviewed accompanying bounded map/UUID option guards. |

Log paths are under `tmp/enhancement-program/03/`. Author evidence records owned-file `mix format` exit 0. The corrected focused runs compiled the candidate modules without warning output. At the source verdict, canonical tests, warning-gated compilation, format check, Credo, security acceptance and historical-artifact checks remained separate root/independent gates; the post-build compile result is recorded below. Hosted CI has not run for this wholly untracked local candidate. No merge or release approval is issued before the applicable checks complete. A subsequent feature/shared-source change invalidates this freeze-specific verdict.

Managed Codex/Claude execution remains unavailable; configured OpenCode/model identity does not establish live availability. Persisted synthetic positives prove projection parity only. No company fitness, policy completeness, contradiction detection, portable authenticated approval, live inference, screen-reader or true zoom claim follows from this review.

## Post-build metadata note — 2026-11-01 14:00 UTC

Rehashed the current candidate against `source-freeze-01.json` after root's native build. **All five reviewed feature/test files still match the exact frozen SHA-256 values above.** The complete current-vs-freeze comparison now has exactly eight differences, all documentation/progress metadata beneath `rel/overlays/share/harnessforge/`:

- `PROGRESS.md`
- `docs/enhancement-program/PROGRAM.md`
- `docs/enhancement-program/conductor.md`
- `docs/enhancement-program/iterations/02/implementation-a.md`
- `docs/enhancement-program/iterations/02/implementation-c.md`
- `docs/enhancement-program/iterations/02/review/code-review.md`
- `docs/enhancement-program/iterations/02/review/security-review.md`
- `docs/enhancement-program/state.json`

At that 14:00 UTC audit, no feature, shared gate, compiler, execution, dependency or other captured source/test file drift was found. The original all-401 match describes the pre-build candidate audit, not later packaging or source corrections. The source PASS was retained at that moment; it is now withdrawn by the correction below.

Read root's `tmp/enhancement-program/03/native-build.json`: inventory, `mix compile --warnings-as-errors`, `mix assets.deploy` and `mix release --path tmp/enhancement-program/03/native-candidate` each exited 0, finishing by 13:58:34 UTC. `native-build-inputs.json` records 339 inputs observed at 13:58:27.962628 UTC; its non-overlay inputs that are in the source freeze match that freeze. These are root-executed build results, not reviewer-run commands, native interaction acceptance or independent canonical-suite results. Reviewer used no Mix and changed only this report.

## Independent-evidence correction — frozen01 pass withdrawn

Read `tmp/enhancement-program/03/independent-qa/canonical.log`, `canonical.json` and `dialyzer-comparison.json`. The canonical run registered **449 tests: 433 passed, one failed by 60,000 ms timeout, 15 skipped**, taking 240.6 seconds. The failing identity-mismatch test at `test/harness_forge/readiness_test.exs:278` timed out in `Command.collect/4` via `Coding.transport/0`, `profile/0`, `profile_digest/0` and evaluation identity construction. The captured stack is in fixture construction using the same identity path; source inspection confirms Readiness itself also reaches it. This is an actual failed check and transitive side-effect finding, not evidence that the readiness assertion failed or a reason to extend the timeout.

The Dialyzer comparison records two new `pattern_match_cov` diagnostics at Readiness 247 and Portal 470, alongside the two unchanged `releases.ex` baseline diagnostics. The previous review missed both the transitive profile probe and the incomplete trace coverage. The earlier statement that applicability was a pure local configuration/file identity computation is explicitly retracted.

Current source corrections (including B's loader wrapper and root's separately reported focus adjustment) are not frozen01 and have no verdict here. Root is selecting the minimal no-probe amendment after A's read-only facts/alternatives. Re-review the amended source and actual focused/canonical/Dialyzer evidence against a new freeze before issuing any pass. Reviewer remains limited to this report: no source edits, Mix, services or native/browser operations.

## Accepted amendment read — corrected candidate not yet reviewed

Read the full `decision-amendment.md`, accepted by root at **2026-11-01 14:14:21 UTC**. It selects context-only conservative abstention and explicitly withdraws unconditional OpenCode task identity/positive-parity promises. This is the binding correction contract for the final bounded review; authors' partial writes are not approved here. Frozen01 remains CHANGES_REQUESTED.

The amended inspector must not call `/1` for any verified OpenCode package, including no-run and non-task selections. Its current task identity map stays empty with fixed `current_identity_assessment` metadata. A matched OpenCode task preserves historical outcome/cleanup/allowlisted identities but calls neither task applicability `/2` nor Validation; both applicability and admission abstain with `runtime_identity_check_required`. Static/smoke uses the real selected record for unchanged pure applicability and exact Validation refusal. Non-OpenCode pure branches retain existing gate parity; unknown/malformed kinds cannot masquerade as a pure comparison. Earlier actual evaluation/cleanup failures must drive actions before abstention; summary copy must distinguish refusal, not-assessed and pure gate success.

Independently inspected the remaining allowed model helper: `Coding.model_identity/0` calls workspace-scoped `Configuration.get/0` and constructs a string; that path reads model settings without transport discovery, credentials, HTTP clients or subprocess calls. This narrow source fact is not a purity claim for the rest of Coding. Static/smoke identity construction uses fixed Docker profile constants and verified configuration bytes; any corrected control flow still requires transitive-call audit and actual no-probe evidence.

Final proof must cover actual synchronous context and LiveView events after explicitly excluded setup/mount: Docker default wrappers/implementation, private endpoint/invoke, Coding profile/digest/transport, named health entry points, Port/open_port and System.cmd. Verify actual matched instrumentation, use a separate collector and trace-delivery barrier, cover spawned descendants, and restore tracing. Recheck source/exports for `Command.run/*` rather than inventing it. Inert task fixtures must avoid live identity construction and cannot supply a current identity. No new source verdict until corrected freeze plus actual required focused/canonical/Dialyzer evidence; failed01 records stay intact.

## Final bounded correction review — source inspected, verification/freeze pending

Inspected amended A/B source and the root's exact two-line focus delta. No additional blocking source defect identified at this intermediate point; CR-2/CR-3 remain open until corrected executed checks and a new freeze. OpenCode current identity computation now abstains before `/1`, matched task records abstain before both `/2` and Validation, and known static/smoke or non-OpenCode branches pass the actual loaded record unchanged to the existing comparisons. Unknown kinds do not enter the generic non-task path. Historical task fixtures use inert values; they no longer construct current profiles. Evaluation/cleanup blockers precede the runtime-check action, while UI copy distinguishes refusal from abstention and keeps the assessment allowlisted. Auth, freshness and privacy control flow remain intact.

Reviewed transitive source beyond the corrected conditionals: model identity is scoped DB lookup/string construction; selected non-task identity uses fixed Docker constants, local task fixture/configuration bytes and hashing. Eligibility traverses existing evidence/citation/active-connection records and approved plan snapshots, then deterministic recompilation; the inspected path does not call connector clients, credential resolution or model/network transports. The excluded OpenCode task branch is still live-bearing in shared source and is not characterized as pure. The root focus adjustment only adds `company-panel` to the existing JavaScript focus allowlist and `tabindex="-1"` to the target section; actual focus/next-Tab behavior still needs native evidence.

Inspected both trace helpers' implementation: loaded modules and positive matched-MFA assertions, arity-only calls, a separate collector, actual caller/LiveView and spawned-child marker calibration, inherited child tracing, exact inspection counts, a trace-delivery barrier before assertions and tracing cleanup in `after`. The web helper also rejects any newly introduced worker before claiming coverage. They inspect actual Command exports for absent `run/*`. This is more specific than the inadequate frozen01 named-function trace; no universal application-wide no-process claim follows from it.

Read A's executed `author-a/correction-02/test-attempt-01.log`: **23 tests, zero failures, 29.7 seconds, seed 817108**, with each of the 16 prohibited entrypoints and two observer MFAs reporting `matches=1`. The passed domain test asserts caller/descendant calibration, 24 actual context calls, zero prohibited calls and before/after no-write hashes across its matrix. B execution, independent canonical/Dialyzer reruns and a conductor-issued corrected freeze remain pending; this paragraph is not a renewed PASS.

## Corrected freeze02 audit — independent QA still pending

Verified `tmp/enhancement-program/03/source-freeze-02.json`, captured at **2026-11-01 14:26:38.996863 UTC**, against both all current candidate bytes and all copied `source-freeze-02/` bytes: **435 entries, zero mismatches or missing files at this audit**. Against the original 397-file baseline, there are three changed feature files and four feature additions; eight changed plus 34 added overlay documentation/metadata files are root-generated packaging output, not additional product changes. No baseline file was removed. Shared Evaluations, Validation, Compiler, Coding, Docker, Command, mix.exs and mix.lock match the original baseline exactly.

| Reviewed feature path | Freeze02 SHA-256 |
| --- | --- |
| `lib/harness_forge/readiness.ex` | `7ae6a7b9a3481f820164df4f71ed16346e90006e8fa060cd6572abd25f62a7ac` |
| `lib/harness_forge_web/live/portal_live.ex` | `5b8f7bf75b24c39fb4aeae917e40148152488bb8014f37a2547ebd3a80e5e321` |
| `lib/harness_forge_web/components/package_readiness.ex` | `6d91bd2cde8ad17ed41895d2942fcbbe4d34cc64e7972b080016aa5d3290958b` |
| `test/harness_forge/readiness_test.exs` | `5e7f35d4c4eee8768aec834780c2e7d89dc5b936314abaf503e82ba8b50059e1` |
| `test/harness_forge_web/package_readiness_test.exs` | `47a8db23977fdaacc575130fb034b92fd48a7e75313393c669f0d21adf75e298` |
| `assets/js/app.js` | `1caae30187b284e8f964699f190d26bf1c4eac33dc7cbacf9d6495fe75d684f9` |
| `lib/harness_forge_web/components/company_panel.ex` | `29215dffc684363a4013614b154fb01a27bbf785f06a57d718e9829cc491a27a` |

Reviewed B's final fixed priority: missing-model metadata remains a managed-runtime observation, while task admission abstention is not falsely announced as a Validation refusal or allowed to hide actual failed outcome/cleanup. Read `author-b/correction-02/test-attempt-01.log`: **13 tests, zero failures, 2.2 seconds, seed 523398, exit 0**. Its two actual-event matrices assert 18 plus six inspections with the low-level trace assertions, including a configured-model task abstention and missing-model pass/failure/cleanup observations. Instrumentation asserts all 16 prohibited MFAs and three observers match once; parent/child calibration, delivery, no new worker and zero prohibited calls are required assertions in those passing cases. This is bounded observed-path evidence after excluded setup/mount, not a global application-wide no-subprocess proof.

No new source defect identified in frozen02, but independent corrected canonical, fast-gate and Dialyzer results are still pending under `independent-qa/candidate-02/`. Frozen01 remains rejected. A renewed final verdict applies only after the corrected evidence is read and does not rehabilitate the withdrawn01 assessment.

## Final corrected verification and verdict

Read the actual `independent-qa/candidate-02/checks.json`, canonical machine report/log, each command record/log, Dialyzer comparison and start/end freeze validation. QA observed all 435 current and copied entries match at **14:27:51 UTC** and again at **14:29:54 UTC**; every recorded command reports no source change. This reviewer separately verified the same freeze and seven feature hashes above. Later packaging metadata changes must retain their own time-specific attribution.

| Corrected check | Actual result |
| --- | --- |
| Canonical seed 0, normal timeout | Exit 0; **453 registered, 438 executed/passed, zero failures, 15 existing Docker skips**, 52.7 seconds suite / 54.1 seconds command. All 36 new domain/web tests passed; no baseline removal or regression. |
| Format and packaging inventory format | Both exit 0. |
| `mix compile --force --warnings-as-errors` | Exit 0; 107 files compiled, no warnings. |
| `mix credo --strict --only warning` | Exit 0; no issues across 156 source files / 23 checks. |
| `node --check assets/js/app.js` | Exit 0. |
| `mix dialyzer` | Exit 2 with exactly the two unsuppressed baseline `call_without_opaque` findings at releases.ex 47/121; zero new diagnostics. |
| Actual low-level no-probe matrices | Passed in canonical: 24 domain inspections plus 18 and six actual LiveView inspections; 16 prohibited entrypoints, exact instrumentation assertions, caller/child calibration, delivered traces, zero prohibited calls. Setup/mount excluded explicitly. |

The retained machine command records contain exact argv, environment, timestamps and stdout paths; this reviewer ran none of those commands. The 15 Docker cases were not rerun in iteration03. QA matched 157 relevant unchanged source/test/config files against original and historical02 evidence, retaining the older Docker evidence with that explicit source-hash limit. This is not a new Docker execution, historical-artifact native exercise, model compatibility or company-outcome result. Coverage and flake rate remain unmeasured.

Approval basis for the bounded source change: strict references and allowlisted metadata/private sentinels; current-workspace exact selection; unchanged claim/plan admission and pure-branch final-gate authority; conservative task abstention without historical/current substitution; no-write assertions and observed command absence; authentication/generation/reset/revocation coverage; no dependency/config/migration change; new public domain/UI behavior tested by 36 passing cases; safe errors/actions and truthful assessment copy. The earlier no-probe conclusion remains retracted for01. Corrected02's PASS depends on this narrower accepted contract and the new evidence, not on rehabilitating01.

**Final counts: Blocking 0 unresolved; Non-blocking 0; Nit 0.** Praise: the correction preserves actual admission authority by declining a result it cannot establish without live discovery, and verifies the true command boundary instead of treating a narrow health-function trace as proof. Root native-final build, focused control/reset behavior, keyboard navigation/focus and viewport acceptance remain separate pending work. No company fitness, portable authenticated approval, policy completeness, real model outcome, true zoom or screen-reader certification is established.
