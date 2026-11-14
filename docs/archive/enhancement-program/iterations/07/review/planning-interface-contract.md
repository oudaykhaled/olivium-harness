# Iteration07 — agreed pre-edit interface contract

All three fresh advisors completed; conductor and root read every original report fully. Root accepted the exact finite guardrail policy/bounds, APIs, storage/privacy lifetime, six labels and ADR07 A1–A9 through its scheduling message. **No unresolved advisory disagreement remains.** This records that agreement without changing the immutable ADR. Root records the final technical resolution and directly dispatches A/B; this conductor stops before authors and remains read-only. No product edit or advisor/conductor runtime operation occurred. Current Mix owner: none.

| Frozen original | SHA256 |
|---|---|
| [Astra guardrail](guardrail-brief.md) | `5eecde83ccd24b29d408fe5e82dfa56b3e0020398d309d1030844e705b4cd9b3` |
| [Impediments/API](impediments.md) | `a99b9e860f34c68802a6f53d3d991536681fc69ec86915a14220465743d7aaec` |
| [Actual UI/UX](uiux-brief.md) | `424f9115e0c1ba76227997b911a7c90ea817cc5b10ceb7dae718c9c6fff7857a` |

## Exact ownership and APIs

**A:** `execution/command.ex`, `execution/coding.ex`, optional `execution/coding_transport.ex`; new transport/pinning tests and optional shared synthetic Docker fixture under `test/support`. **B:** `evaluations.ex`, existing `evaluations_test.exs` and `coding_evaluation_test.exs`. **Root:** Run schema/migration, snapshot/purge and associated tests; release/readiness/MCP integration/traces and fixed UI helper/Portal/PackageReadiness labels. A does not edit B's existing coding test file. Shared fixture is test-only; no production qualification override. Three distinct product authors total, including root.

```elixir
# A: Command; old docker/1..3 remains the separate offline backend.
local_endpoint() :: {:ok, String.t()} | {:error, atom()}
docker_at(String.t(), [String.t()], pos_integer(), pos_integer()) ::
  {:ok, %{output: binary(), exit_status: non_neg_integer()}} | {:error, atom()}
# Optional docker_at/2,/3 defaults retain the distinct pinned name.

# A: CodingTransport; observation() is opaque/internal.
observe() :: {:ok, observation()} | {:error, atom()}
verify(observation()) :: :ok | {:error, atom()}
context(observation(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
decode_context(term(), %{workspace_id: String.t(), run_id: String.t()}) ::
  {:ok, observation()} | {:error, atom()}

# A: Coding.
admit(map()) :: {:ok, observation()} | {:error, atom()}
profile(observation()) :: map()              # pure
profile_digest(observation()) :: String.t() # pure
run(String.t(), map(), observation()) :: map() # public result patch only
cleanup(String.t()) :: :ok | {:error, atom()}   # persisted owned context

# B: result-only public interfaces and internal scoped purge hook.
get(String.t()) :: {:ok, map()} | {:error, :evaluation_not_found}
list_runs() :: {:ok, [map()]}
applicability(map(), map()) :: :ok | {:error, :evaluation_inapplicable}
cleanup_runs(:all | {:ids, [String.t()]}) :: :ok | {:error, :cleanup_failed}
```

All input maps remain data; no input-derived atoms. Exact finite Desktop/native signatures, endpoint grammar, field limits, deadlines and pinned child environment are **guardrail sections1–3**, accepted verbatim by root. Native rootful direct same-host/path-sharing is an explicit trusted-host support assumption, not topology attestation. Darwin Desktop does not require host Linux. Unknown/future signatures refuse; Mac Unix fixtures cannot qualify Linux. Resolve nonempty `DOCKER_CONTEXT` before `DOCKER_HOST`, otherwise current context; `docker_at` pins `--host`, clears the six specified Docker override variables and never resolves again.

## Admission and authority

`Coding.admit`: provider/model → existing authorization/consent → bounded Ollama health → **one new observe** → pinned image checks. No old `Docker.probe` or discovering `profile/0` competes. B atomically commits public identity and private context before relay, ledger preparation, candidate paths or resources; failed commit starts nothing. Every coding command and cleanup uses the captured endpoint with daemon guards; route selection is not repeated.

Private nullable `execution_context` has exactly six string-valued keys: `version="coding-transport-v2"`, `route` in `desktop_loopback_proxy|unix_socket_proxy`, `endpoint`, `daemon_id`, `workspace_id`, `run_id`. Decode validates bounds and actual persisted ownership. Root uses `field :execution_context, :map, redact: true`, no default/backfill. Context never enters result/DTO/error/audit/export; backups remain unencrypted and contain its non-secret identifying endpoint path.

Every new OpenCode task result has `execution_profile_id="docker-coding-isolated-v2"` and safe `runtime_name`. Profile identity includes `Contracts.digest` of exact version/route/endpoint/daemon_id; expose only safe profile/digests. Admission refusal persists blocked/unqualified, null environment digest/context, not_dispatched/not_started and empty checks.

Live applicability loads the actual current-workspace Run, verifies artifact ownership and supplied-result equality, decodes stored context and recomputes its public digest before fresh current transport/model/config comparison. Caller maps/markers/digest equality alone grant no authority. Completion validates the pending owned context plus candidate outcome, **not** equality of a new terminal candidate to the still-running stored result. Fresh authority observations never retarget original resources. Legacy v1 cannot qualify; synchronous Readiness/Inspect/Refresh and MCP stay command-free and Not assessed.

## Cleanup and privacy lifetime

Dispatch by actual persisted kind/runtime/context. Static/unsupported managed: no backend. Offline smoke: only Execution. V2 coding: only pinned Coding; no default-daemon cleanup first. Restart enumerates stored unresolved rows without default probe/global reconciliation. Unknown unfinished legacy origin stays unresolved; terminal legacy, explicit no-resource predispatch and restored quarantine make no guessed contact. Preserve cancellation and existing terminal outcomes on cleanup/retry.

Retain **all** v2 contexts, including completed-clean, until scoped purge. Source purge passes exact planned run IDs; workspace purge passes `:all`. The hook scopes to current workspace, rechecks every targeted retained context and uses only owned persisted metadata/context—not artifacts/models/current admission, `ensure_writable` or `Purge.ready` while fenced. Unavailable original daemon blocks retryable purge even after earlier cleanup success; no unrelated current-daemon sweep.

Root retains all scoped Run rows through `database_purged`; delete only `complete()` after owned files succeed. Include contained nonsymlink `runs/coding-<UUID>` paths in selective plans alongside existing run paths. Backend/file failure retains row/context/fence. Restore clears context only when the column exists, keeps quarantine and never contacts the old daemon; old backups remain supported. Rollback refuses any nonnull context. Final root install preflight repeats identity-bound legacy/schema inventories; early zero unfinished rows is no final guarantee.

## Fixed presentation and verification handoff

Use exactly the UI brief's six labels for `coding_transport_unavailable`, `coding_transport_unsupported`, `local_docker_required`, `coding_transport_changed`, `coding_cleanup_context_invalid`, `coding_cleanup_origin_unknown`. Root maps Portal's raw reason and PackageReadiness labels, updates Readiness allowlist and uses fixed unknown fallback; no extra panel. Model/backend prerequisites retain their distinct reasons.

A9 uses a separately scheduled isolated QA workspace, synthetic local Ollama `/api/tags` health fixture, unset `DOCKER_CONTEXT` and verified absent local socket. It must trace the **new observe** refusal after healthy model prerequisites, with v2 blocked/null identity and zero inference/resource effects; an early model/old-probe refusal does not count. Native keyboard/reflow covers measured320/390 CSS widths at actual100/200% zoom. Root updates A8 tracing for new/removed MFAs; a missing pattern cannot falsely pass. Test fixtures must not trigger real Docker through `on_exit` purge.

All A1–A9 execution, canonical/guarded Docker checks, native qualification and installation evidence remain pending. Root alone schedules Mix/Docker/build/native/browser operations and writes board/state/results. No extra user permission gate, new benefit or iteration count follows from these reports. **Stop here pending root's direct author scheduling.**
