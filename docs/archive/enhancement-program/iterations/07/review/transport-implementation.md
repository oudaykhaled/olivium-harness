# Iteration 07 transport implementation handoff

Author A implemented only the six assigned source/test files. Root is the sole
execution operator and board/results writer. This is an implementation handoff,
not a test pass, live Docker qualification or iteration completion record.

## Implementation

- `execution/command.ex`: public `local_endpoint/0` captures context-over-host
  selection; bounded context inspection decodes exactly one JSON value. The
  conservative Unix grammar rejects repairs, remote schemes and unsafe path
  components. `docker_at/2..4` never resolves again, supplies fixed global host
  argv, rejects competing connection flags, clears the six agreed override
  variables and retains streamed output limits and monotonic deadlines.
- `execution/coding_transport.ex`: one projected discovery with socket evidence,
  exact seven-field validation, finite Desktop/native policies and the agreed
  discovery/identity budgets. Observations retain only endpoint, ID and route;
  normal Inspect excludes endpoint and daemon ID. Exact six-key context decoding
  validates ownership. Identity verification reads only the original daemon ID.
  The pure `supported_route/2` seam evaluates supplied policy data and returns
  only a route name. Runtime observation always collects actual host evidence;
  this seam cannot inject execution authority or qualification.
- `execution/coding.ex`: `admit/1` preserves provider/model, authorization and
  health prerequisite order, validates artifact requirements, observes once and
  checks images through the captured endpoint. Pure profile/digest derivation
  uses v2 and a digest of the exact private transport identity. `run/3` checks the
  actual persisted pending owned context/public identity before relay or files.
  Route and endpoint flow through proxy, network, agent, grader and every Docker
  command. Guards consume remaining command/task time. Fenced resource/file
  setup also rechecks persisted ownership and original identity.
- `cleanup/1` loads the scoped Run and retained context without artifact/model,
  writable-fence or admission dependencies. It checks original identity, exact
  labels and verified absence, including a final identity check, and never clears
  context. Explicit predispatch and restored quarantine branches make no Docker
  contact. Unknown legacy origin and corrupt v2 authority refuse. Compatibility
  reconciliation enumerates persisted unresolved v2 rows, not current labels.

B owns fresh completion/applicability admission and comparison; these observations
never replace A's original resource/cleanup target. Cleanup patches do not alter
the persisted cancellation outcome. Root owns storage, quarantine, scoped purge,
fixed copy, command-free tracing and runtime verification.

## Shared synthetic fixture

`test/support/coding_docker_fixture.ex` supplies a hand-authored Python
standard-library CLI named `docker`, selected only by test PATH. Two real inert
Unix listeners make socket stat meaningful. No production hook or candidate-code
execution is added.

```elixir
f = HarnessForge.CodingDockerFixture.install!()
f.endpoint
f.decoy_endpoint
Fixture.observation(f, workspace_id, run_id) # {:ok, decoded_observation}
Fixture.put_daemon(f, f.endpoint, %{"info" => Fixture.info(), "status" => 0,
  "containers" => %{}, "networks" => %{}})
Fixture.select(f, f.decoy_endpoint)
Fixture.commands(f) # [%{"argv" => [...], "env" => six_override_keys_only}]
Fixture.clear_commands(f)
Fixture.restore(f)
```

`put_daemon/3` shallow-merges string attributes. `info` replaces all projected
fields, `status` is an exit code, `raw_info`/`identity_raw` replace discovery/ID
JSON bytes, `delay_ms` delays replies, and container/network maps use exact names
and Docker inspect maps. Defaults have empty resources and distinct IDs.
The `context` attribute selects the context-inspect response. Environment logs
contain only the six Docker override keys, for synthetic sentinels. Restore closes
listeners and restores all changed environment keys. Context-bearing rows must
be deleted before restoring real PATH or running a committed workspace purge.

## Authored checks and pending execution

New `coding_transport_test.exs` covers actual Port argv/environment, context
precedence and grammar, pure profile/privacy correspondence, malformed/missing/
extra/wrong-type/bounded discovery fields, nonzero/overflow/timeout, no negative
Unix fallback, finite positive/independent-negative Desktop/native policy and
exact context ownership. Native policy fixtures do not qualify Linux on Darwin.

New `coding_pinning_test.exs` covers endpoint drift with matching-label decoys,
same-path ID replacement and original retry, retained clean-context verification,
foreign resource labels, missing/corrupt/foreign/inconsistent context, no effects
without committed authority, and exact restored/predispatch no-contact branches.

Root-only suggested commands, after schema integration:

```sh
mix format lib/harness_forge/execution/{command,coding,coding_transport}.ex test/harness_forge/{coding_transport,coding_pinning}_test.exs test/support/coding_docker_fixture.ex
mix test test/harness_forge/coding_transport_test.exs test/harness_forge/coding_pinning_test.exs
mix test
```

All compilation, formatting, ExUnit, canonical, diagnostic and guarded Docker
results remain pending with root at this handoff. A ran no Mix, Docker, build,
native, browser, database or model operation. No host candidate execution, paid
inference, credential extraction, remote write, commit or publication occurred.

Root's first check reported that the application compiled twelve files without
warnings; focused test execution stopped at a B-owned helper name collision
before any test ran. Under root's correction-round-one release, A added the
final exact configuration equality guard after image checks and a regression
that pauses an actual synthetic `/api/tags` health response, changes the selected
model, then requires `model_configuration_changed` with one route observation,
three pinned image checks and zero inference/resource creation. B brackets its
admission-to-identity/insert window separately. Re-execution remains root-owned
and pending; A returned to product-write hold after these two-file corrections.

## Trace inventory changes for A8

Removed: `Command.local_endpoint/1`, `Coding.transport/0`, `Coding.profile/0`,
`Coding.profile_digest/0`, `Coding.run/2`.

Added: `Command.local_endpoint/0`, private `resolve_context/1`,
`Command.docker_at/2,3,4`; `CodingTransport.observe/0`, `verify/1`, `context/3`,
`decode_context/2`, pure `supported_route/2`; `Coding.admit/1`, `profile/1`,
`profile_digest/1`, `run/3`, private `coding_command/2,3,4`, `fence/3` and
`owned_observation/1,2`. `Command.invoke/4` and `docker/1,2,3` remain. Private
Coding helper arities now carry transport explicitly. A8 must require existing
trace patterns, rather than treating a missing removed MFA as a zero-call pass.
