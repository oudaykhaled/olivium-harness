# Iteration 07 — pre-edit API and impediment brief

**Complete, source-only advice.** Owner: `/root/i07_conductor/impediments07`. The full accepted [ADR07](../decision.md), [coordination plan](../coordination.md), root acceptance record, repository `AGENTS.md`, and relevant current implementation/tests were read. No product edits, tests, Mix, Docker, process, database, browser or local HTTP operations were performed. This brief does not modify the accepted ADR or authorize authors. Root remains the sole board/state/results writer and Mix/native operator; the three product author slots include root.

The agreed direction is implementable with the existing Elixir/Phoenix/Ecto stack and pinned OpenCode 1.19.5/images. The concrete impediments are unsafe backend dispatch, public-map-only applicability, schema/privacy lifetime, and fixture assumptions—not SSD capacity. The supplied 11 GiB is a scheduling input, with no deletion authority.

## Agreed A/B/root contract

This proposal was exchanged directly with `/root/i07_conductor/guardrail07_astra`; its final finite route predicate and bounds govern. Root accepted the direct same-host/rootful native topology as a support assumption, not attestation or protection against hostile local forwarding. Desktop does not require a Linux host. Unknown observations never select Unix; unsupported future versions refuse. The native signature is an explicit finite OS set plus matching host OS/kernel, root-owned default socket, `/var/lib/docker`, cgroup v2 and positive security controls; Desktop requires exact Desktop/Linux and LinuxKit recognition. Read the guardrail brief for exact values, topology checks and official Docker citations rather than inferring a broader predicate from this summary.

Author A owns `execution/command.ex`, `execution/coding.ex`, optional `execution/coding_transport.ex`, new transport/pinning tests and, if needed, the shared synthetic Docker fixture under `test/support`. Author B owns `evaluations.ex`, existing `evaluations_test.exs` and `coding_evaluation_test.exs`. Root owns `evaluation/run.ex`, one migration, snapshot/purge, their tests, release/readiness integration and tests, and fixed Portal/PackageReadiness copy. These assignments avoid two authors editing the existing coding test file. The shared fixture exercises actual Port argv and daemon decoys; it provides no production qualification override.

Use these exact internal seams, with `observation()` opaque outside the transport module and no raw observation returned through a public DTO:

```elixir
# Author A: Command. Existing docker/1..3 remains the offline backend contract.
local_endpoint() :: {:ok, String.t()} | {:error, atom()}
docker_at(String.t(), [String.t()], pos_integer(), pos_integer()) ::
  {:ok, %{output: binary(), exit_status: non_neg_integer()}} | {:error, atom()}
# Defaults may expose docker_at/2 and /3; every new coding call uses this name.

# Author A: CodingTransport.
observe() :: {:ok, observation()} | {:error, atom()}
verify(observation()) :: :ok | {:error, atom()}
context(observation(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
decode_context(term(), %{workspace_id: String.t(), run_id: String.t()}) ::
  {:ok, observation()} | {:error, atom()}

# Author A: Coding.
admit(map()) :: {:ok, observation()} | {:error, atom()}
profile(observation()) :: map()                 # pure
profile_digest(observation()) :: String.t()    # pure
run(String.t(), map(), observation()) :: map() # public result patch only
cleanup(String.t()) :: :ok | {:error, atom()}   # loads persisted owned context

# Author B: existing public result interfaces remain result-only.
get(String.t()) :: {:ok, map()} | {:error, :evaluation_not_found}
list_runs() :: {:ok, [map()]}
applicability(map(), map()) :: :ok | {:error, :evaluation_inapplicable}
# Internal cross-module purge hook, not a new UI/CLI/MCP tool:
cleanup_runs(:all | {:ids, [String.t()]}) :: :ok | {:error, :cleanup_failed}
```

`Command.local_endpoint/0` resolves once using nonempty `DOCKER_CONTEXT`, then nonempty `DOCKER_HOST`, then configured context. `docker_at` validates the bounded Unix endpoint and invokes the fixed Docker executable with global `--host`; it does not resolve context again. Clear `DOCKER_CONTEXT`, `DOCKER_HOST`, `DOCKER_TLS`, `DOCKER_TLS_VERIFY`, `DOCKER_CERT_PATH` and `DOCKER_API_VERSION` in the child. Internal command arguments cannot supply a competing global host/context. Existing default-backend operations retain their separate contract.

Private context has **exactly six string keys and string values**:

```elixir
%{
  "version" => "coding-transport-v2",
  "route" => "desktop_loopback_proxy" | "unix_socket_proxy",
  "endpoint" => validated_local_unix_endpoint,
  "daemon_id" => bounded_validated_daemon_id,
  "workspace_id" => owned_workspace_uuid,
  "run_id" => owned_run_uuid
}
```

Decode rejects extra/missing keys, wrong types/version/route, invalid endpoint/daemon bounds and ownership mismatch. `verify` queries the captured endpoint and compares its daemon identity; it never reselects route or falls back. Public profile ID is `docker-coding-isolated-v2`; its `transport_identity_digest` is the canonical digest of version/route/endpoint/daemon ID. Only profile/digest identities enter `result`. Every new OpenCode task row includes fixed public `execution_profile_id = "docker-coding-isolated-v2"` and safe persisted `runtime_name`; a digest alone cannot distinguish new missing-context corruption from a legacy row. No credential, token, environment dump or raw discovery payload belongs in either identity contract.

The six agreed transport reasons are `coding_transport_unavailable`, `coding_transport_unsupported`, `local_docker_required`, `coding_transport_changed`, `coding_cleanup_context_invalid` and `coding_cleanup_origin_unknown`. Keep existing model/consent/backend reasons. Errors and changesets must not serialize the private map; aggregate cleanup errors remain `{:error, :cleanup_failed}` while the owned run records the relevant fixed reason.

## Admission, execution and current authority

1. `Coding.admit(artifact)` preserves prerequisite order: provider/model selection, existing authorization/consent, `Ollama.available` health, **one new `CodingTransport.observe`**, then pinned runtime/proxy/grader image checks. Validate the existing runtime/source requirements without preparing resources. Do not call `Docker.probe`, old `transport/0`, or command-discovering `profile/0` on this path. `Coding.availability/0`, if retained for explicit capabilities, must use this captured path rather than supply a competing route.
2. B creates one Run row whose public identity and private context derive from the same successful observation, in the same insert/transaction. Commit before `Coding.run/3`, relay/session start, ledger-backed `Runtime.prepare`, candidate paths, networks or containers. A failed admission still inserts the actual blocked/unqualified attempt, v2 marker, `environment_profile_digest: nil`, `execution_context: nil`, `usage_status: not_dispatched`, `cleanup_status: not_started`; it fabricates no successful profile.
3. A checks the actual owned stored row/context matches the passed observation and public digest before effects, and retains the model/configuration guards. Thread the captured route through relay socket mode, proxy bytes/user/mounts, Desktop bridge connection and network/container expectations. Thread its endpoint through **every** Coding Docker read and mutation: image checks, create/start/exec/wait/logs/inspect/list/remove/network operations and absence verification. Current helpers at `coding.ex:398–715` and `803–921` all need this handoff. A daemon identity guard precedes resource-effect and cleanup boundaries. A supplied observation never permits a different cleanup target.
4. Completion checks current authority/configuration again before persisting `passed` plus qualified. A fresh current observation here, or at live release applicability, is an authority observation; it never replaces the attempt observation, rewrites context, or retargets resources. Drift/unknown authority leaves qualification false; a successful task observation becomes inconclusive if qualification cannot be established. Keep cancellation terminal and never turn a retry into passed.
5. For OpenCode task `Evaluations.applicability(artifact, supplied_result)`, B loads the real Run by `id` and current workspace, verifies its artifact ownership, and requires `supplied_result == record.result`. It requires v2 marker, decodes **stored** context, recomputes its profile digest and matches the stored public digest, then obtains a fresh validated current observation and compares profile/endpoint/daemon/route plus existing model/configuration identities. Missing/corrupt/foreign context, marker-only rows, legacy v1, unavailable discovery and caller-forged results fail. `/1` remains an identity producer; constructing its map never grants qualification. Static/offline/non-OpenCode identity contracts remain separate. Command-free Readiness continues to abstain for current OpenCode tasks.

## Cancellation, restart and target-aware purge

`Evaluations.cleanup_all/1` currently invokes `Execution.cleanup` then `Coding.cleanup` for **every kind** (`evaluations.ex:463`); different names do not make that safe. Replace it with one classifier over the actual persisted kind/runtime/context. Static and unsupported managed rows issue no backend command. Offline OpenCode smoke uses only `Execution.cleanup`. V2 coding uses only persisted-context `Coding.cleanup(id)`; never perform offline cleanup first. Identify legacy runtime from explicit persisted `runtime_name` or known pinned runtime identity; unknown unfinished coding origin stays unresolved without Docker commands. Inconsistent/corrupt ownership fails closed, rather than authorizing a guessed backend.

Normal restart enumerates current-workspace stored unresolved rows—running/pending outcome or pending/failed cleanup—and dispatches that classifier. It must not require today's `Execution.probe` before attempting an original coding endpoint. Remove the current default-daemon `Execution.reconcile`/`Coding.reconcile` lifecycle sweep; the latter's label enumeration cannot discover switched-away contexts. Keep cancellation on interrupted/retried cleanup. Terminal legacy rows remain readable with no new guessed-daemon obligation. Exact restored quarantine (`restored_requires_reevaluation`, `not_dispatched`, null context) is a no-contact branch. Predispatch blocked/not_started/null-context v2 rows also require no cleanup.

Keep **all successful v2 contexts, including completed-clean contexts, until scoped purge**. Root accepted the resulting availability tradeoff: purge must reverify original daemon/labels/absence even if cleanup was recorded complete earlier; unavailable original daemon blocks purge with retained authority and a retryable fence.

Root `Purge.cleanup/1` currently globally calls both reconciliations when **any workspace runtime row** exists (`purge.ex:252`). Instead call B's `cleanup_runs({:ids, op.plan["run_ids"]})` for source purge, and `cleanup_runs(:all)` for workspace purge. The hook scopes all reads to the current workspace and rechecks every retained targeted v2 context, including completed ones; it neither updates unrelated rows nor addresses current-daemon decoys. Terminal legacy/no-resource/quarantine cases follow the classifier above. It preserves existing terminal/cancelled outcomes, rather than marking every targeted row interrupted. Any cleanup failure returns before context/row deletion; existing durable prepared operation and readiness fence remain retryable.

**Root's final integration choice:** retain **all scoped evaluation_runs rows through `database_purged`**, as with existing artifact bindings. Delete them only inside `complete()` after owned file removal succeeds. This preserves context on filesystem failure as well as backend failure. Retrying `cleanup_runs` must work after evidence/artifacts/model configuration have been deleted: it depends only on persisted owned row metadata/context, the workspace identity and pinned cleanup. It must not call `Workspaces.ensure_writable`, `Purge.ready`, current model admission or artifact lookup while the purge fence is active. The existing release approval evaluation ID has no Run foreign key, so this deletion ordering is feasible. Do not clear contexts separately before final row deletion.

There is a second concrete A7 defect: source plan files contain `runs/<id>`, while Coding writes `runs/coding-<id>` (`coding.ex:957`). Root must derive both required owned paths from validated UUIDs, include the coding path in the persisted source plan and allowlist, and remove targeted coding roots **after pinned cleanup but before deleting execution_context**. Workspace purge already covers all runs. Reuse `Privacy.Files.remove_owned` and its no-symlink/parent-chain checks; reject traversal/foreign paths and retain the row/context on failure. Root's retained-row ordering above permits the existing `cleanup → database_purged → remove_files → complete` flow, with authority removed only at complete. No exhaustive orphan sweep is added.

## Root storage, restore and installation seam

Add `field :execution_context, :map, redact: true` and one nullable migration, without default/backfill. `get/list_runs` already return `.result`, which is the public boundary; preserve it. Redaction protects normal schema/changeset inspection, not query logs or database encryption, so sanitize persistence failures and do not log context. Rollback refuses **any non-null context in any workspace**, even completed/corrupt maps, before dropping the column; a rollback is not permission to forget authority.

`Snapshot.alter_quarantine/3` must clear the column only when `PRAGMA table_info(evaluation_runs)` confirms it exists; old backups still restore before startup migration. Keep the existing result quarantine transformation and historical bytes otherwise; restoration must never contact the old daemon. Document that existing unencrypted private backups contain a non-secret but identifying endpoint path. Restore removes that execution authority; it does not clean the original workspace.

Before installation root must reverify protected process/release/workspace/database identity, then repeat a read-only compatibility inventory against that exact database: schema versions/column presence, legacy evaluation columns and result-byte hashes; enumerate legacy task rows whose outcome is running/pending **or** cleanup pending/failed, excluding explicit restored no-contact quarantine. With no context column all such tasks lack provable origin. Stop the local transition if any exist; preserve them unresolved, do not backfill today's daemon or run default cleanup. Also inspect pending privacy operations and unresolved offline smoke under their own backend contract. Back up and compare legacy rows/artifact bytes around migration. Root's early compatibility file reports 8 static passed/not_started, 6 task blocked/not_started, zero legacy unfinished tasks, no context column and nine versions; it is an early observation, not final installation evidence. Main 52191/8865 release06 and MCP 36093/8867 remain protected pending root's accepted sequence.

## Concrete verification impediments and ordering

Root first integrates schema/restore compatibility; A implements agreed transport and shared synthetic fixture; B integrates the agreed APIs. Parallel edits are limited to these disjoint files. Root then runs checks; advisors run none.

- Existing missing-model tests assert task applicability is `:ok`; unavailable/v2-null-context task authority must now be inapplicable. Existing `Coding.profile/0` tests must use a controlled observation and pure `/1`.
- `evaluations_test.exs` currently fabricates a **static** running row to test offline foreign-container cleanup. Change that fixture to explicit offline smoke; static cancellation/recovery must issue zero backend calls.
- `releases_test.exs:evaluation_fixture` fabricates passed rows from `applicability/1` with no private context. Update controlled fixtures to persist a valid owned context and use the shared synthetic observation boundary; never weaken stored-record validation to retain those assertions. Add fake caller-map/missing/corrupt/foreign-context failures.
- Existing privacy cleanup-failure tests insert an unrelated opaque runtime row; scoped purge should no longer fail for that unrelated row. Use a target-dependent pinned context for failure/retry and retain an unrelated decoy as a zero-contact assertion. Committed privacy test `on_exit` invokes workspace purge: leave no unfinished fixture/context that accidentally contacts a real daemon; explicitly clean/remove test-owned fixtures or use terminal/not_started records.
- Root's new migration test should mirror `goal_basis_migration_test.exs`: isolated actual Ecto migration/up/down, opaque legacy-row preservation, nullable/no-default inspection, refusal with a non-null foreign-workspace context while migration state survives, and pre07 backup restore before actual migration runner. New-schema restore proves cleared context and zero old-daemon contact.
- A8 tracing currently requires old `transport/0` and existing arities to exist. Update the prohibited MFA inventory for removed helpers and new `local_endpoint`, `docker_at/2..4`, `observe/0`, `verify/1`, and admission helpers; retain calibrated actual caller/descendant traces for synchronous Readiness, LiveView Inspect/Refresh and all three MCP reads. A missing trace pattern is a failure, not evidence of zero calls.
- A9 must reach the **new captured transport refusal** after model/consent/health, not `model_not_selected` or old `Docker.probe` relabeled. Root alone calibrates the separate local synthetic Ollama tags fixture and absent Unix socket described by UI/UX, traces observation reached and zero relay/ledger/files/resource creation, and checks the existing run card's fixed copy/qualification. Fixture Desktop/native cases and actual available Docker routes are distinct evidence; Mac native fixtures do not qualify Linux topology.

All required A1–A9 cases remain necessary, particularly current-context switch, same-path daemon replacement, cross-daemon decoys, cancellation/restart retry, scoped purge and privacy sentinel checks. Root records actual canonical counts, 15 historical default Docker skips as skips, and the two known unsuppressed Dialyzer baseline findings with zero new. Changed execution contracts cannot inherit blanket historical Docker verification.

**Remaining conflicts: none in this exchanged API/data/ordering proposal.** Root must record acceptance of the guardrail's exact finite predicate/bounds and this handshake before authors start; that is the scheduled technical decision, with no extra user permission gate. Proposed precise clarification alongside ADR07: “Fresh completion/applicability observations assess current authority and never retarget the attempt; retain completed v2 context until scoped pinned purge; source coding roots are removed after verified cleanup and before context deletion.” No product implementation, migration pass, native support, installation or iteration completion is claimed here.
