# Execution and evaluation status

HarnessForge runs no imported or generated code on the host. The only host
subprocess is a bounded Docker CLI transport with internally constructed argv.
The initial backend implements fixed, offline OpenCode version/configuration and
containment checks. It does not expose a general shell execution service.

The pinned official runtime is OpenCode **1.19.5**, image
`ghcr.io/anomalyco/opencode@sha256:f4cfe16d91efbbfca01a51c44094fba4cf82e15c7fa17de5f11f9059699b1e6e`.
The backend never pulls automatically. Install the image explicitly before
running the opt-in checks. It requires a local Unix Docker endpoint and Linux
containers. Docker Desktop is a supported development test environment; the
container boundary is not a claim of resistance to Docker/kernel vulnerabilities.

Every managed container has a unique UUID name and workspace/run labels.
Inspection verifies ownership before cancellation or deletion. The fixed profile
uses UID/GID 65534, a read-only root, no host mounts or Docker socket, no network,
all capabilities dropped, no-new-privileges, 64 PIDs, 512 MiB memory including
swap, one CPU, and a 64 MiB noexec/nosuid/nodev tmpfs. Output is limited to 64 KiB,
time to 15 seconds, and Docker log storage to one 1 MiB local log. Exceeding a
time/output bound terminates and removes the container; removal is verified.
No host credentials or environment variables are forwarded to containers.

OpenCode effective configuration uses an empty provider allowlist, no plugins or
MCP servers, no LSP/formatters, disabled updates, and denied tool permissions.
The offline smoke checks the actual debug configuration output. It proves loading
the inline configuration under this isolated profile; it does not establish
native agent/skill file discovery or real-model coding success.

`Evaluations.run(artifact_digest)` executes the packaged `synthetic-go-v1`
finite coding suite only when an explicitly selected, installed local Ollama
model and all pinned images are available. With no selected model it persists
`outcome: "blocked"`, `reason: "model_not_selected"`, and no inference dispatch.
The artifact must name the exact observed runtime version `1.19.5`;
`unqualified` remains usable for previews but cannot qualify a task run. There
is no host execution, paid-call fallback, automatic model download, or
caller-supplied success/qualification flag.

The coding profile uses a separate internal Docker bridge with
`com.docker.network.bridge.gateway_mode_ipv4=isolated`, IPv6 disabled, and no
host bridge gateway. Docker Engine 28+ is required for this bridge mode. The
agent has only this network, the synthetic candidate directory as its only
writable host mount, and the approved artifact as a read-only mount. Native
agent/skill discovery files are copied into an isolated runtime tmpfs because
OpenCode writes bootstrap files in its config directory. Before and after the
coding command, actual effective configuration is checked against the approved
artifact plus the fixed local provider and tighter evaluation permissions.
OpenCode debug output redacts provider credentials; actual authorized model
requests prove use of the per-run capability.

The proxy is the pinned public nginx 1.28.0 Alpine image
`docker.io/library/nginx@sha256:30f1c0d78e0ad60901648be663a710bdadf19e4c10ac6782c235200619158284`.
It accepts only `POST /v1/chat/completions`, forwards to one owned metered relay,
and rejects model-management and alternate paths. Native Linux uses a private
mode-0600 Unix socket mounted only in this proxy. Docker Desktop cannot mount
the host Unix socket in this environment: its trusted proxy additionally joins
the default Docker bridge and forwards only to the relay's fixed ephemeral
`host.docker.internal` port. The relay still binds strictly to host loopback;
the agent never joins the proxy's external bridge. The selected transport and
nginx template are part of the versioned environment identity. New coding attempts
use `docker-coding-isolated-v2`: one validated local endpoint, daemon ID and route
are captured after model health checks. The public identity contains an opaque
digest; the original endpoint and daemon ID remain in private run storage.
Every coding Docker read, mutation and cleanup pins that endpoint and verifies
the daemon ID. A changed default context cannot redirect cleanup. Fresh completion
and release checks assess current connection/model identities; they never retarget
the attempt. Failed discovery persists a blocked, unqualified attempt with no
fabricated environment digest and no relay, ledger preparation or candidate files.

Route admission uses a conservative finite support policy. Desktop requires exact
`Docker Desktop`/Linux metadata, a LinuxKit kernel and cgroup v2 over a local Unix
socket. Native Linux requires direct same-host rootful Engine, a root-owned default
socket, matching local/daemon OS and kernel, `/var/lib/docker`, cgroup v2 and the
specified seccomp controls without rootless/userns. The recognized native OS strings
are Ubuntu 22.04.5 LTS, Ubuntu 24.04.3 LTS and Debian GNU/Linux 12 (bookworm).
Unknown/future signatures and rootless, forwarded/VM or containerized native
setups remain unavailable. This is a support assumption for a trusted local host,
not attestation against socket forwarding or hostile socket replacement. The native
Linux route has not been qualified on this macOS host; policy fixtures cannot
establish that compatibility. See the exact [transport contract](enhancement-program/iterations/07/review/guardrail-brief.md).

Each task checks actual nonroot UID, zero effective capabilities,
no-new-privileges, resource limits, denied root/artifact writes, absence of the
Docker and relay sockets, absence of a default IPv4/IPv6 route, denied direct
Internet/private-host access, denied external DNS, unauthorized-chat rejection,
and denied model-management/alternate proxy paths. Inspected container mounts,
images, network attachments and ownership labels must match exactly. Coding
containers use UID/GID 65534, read-only roots, 128 PIDs, 1 GiB RAM including swap,
one CPU, bounded 512 MiB tmpfs, 128 KiB command output, and one 1 MiB log. The
agent tmpfs is noexec; the protected grader's tmpfs permits its compiled binaries.
Native Linux's socket proxy uses the nonroot socket owner's UID/GID.

The protected grader uses the pinned public Go 1.25.3 Alpine image
`docker.io/library/golang@sha256:aee43c3ccbf24fdffb7295693b6e33b21e01baec1b2a55acc351fde345e9ec34`.
It runs with `--network none` and read-only candidate/protected mounts. Before
compiling any candidate code, a separately compiled trusted Go AST validator
accepts only one expected pure utility function, package `utility`, and the
`strings` import for the reverse-words task. It rejects initializers, package
variables, directives, printing, unsafe/runtime/reflect/system access, extra
functions and goroutines. This restriction is deliberate for the finite suite;
it is not an arbitrary-repository evaluator. Protected tests run separately
from the coding agent, then a protected probe returns actual function values.
The Elixir evaluator compares those values against expectations outside the
candidate process. Exit zero or a model message alone never establishes a pass.

Every relay call, including retries and auxiliary model requests, uses the same
workspace/run model ledger. The relay snapshots the chosen model and approved
artifact source IDs, permits no cloud provider, enforces the declared turn count
(up to the profile's 100-turn ceiling), and applies the declared lifetime up to
300 seconds. The suite uses the remaining execution deadline for model and
grading stages. The shared default ledger is tighter still: 10 requests and
100,000 reserved tokens. Unknown usage, failed cleanup, failed objective checks,
a changed model configuration, or a mismatched runtime prevents qualification.

Two explicitly selected diagnostic modes are available:

- `kind: :static_integrity` verifies the stored immutable artifact and current
  approved evidence. A pass has `runtime_qualified: false`.
- `kind: :runtime_smoke` performs real containment, version and effective inline
  configuration checks in the pinned container. A pass still has
  `runtime_qualified: false`.

Neither mode can satisfy release promotion. Applicable task evaluation must have
`kind: "task"`, `outcome: "passed"`, `runtime_qualified: true`, and verified
`cleanup_status: "complete"`, with exact immutable runtime/config/environment,
scope, suite, fixture, grader, capability, policy and model identities. Current
task fixture/grader digests cover the actual packaged prompts, seeds, protected
checks, AST validator, grader commands and objective expectations. A changed
model endpoint or configuration also invalidates applicability.
Callers cannot submit outcomes, exit codes, image references or qualification.

`Evaluations.cancel/1` accepts a persisted workspace-owned run ID. Cancellation
intent survives failed teardown and retry. Restart enumerates persisted unfinished
or failed-cleanup rows; coding recovery uses their original private context even
when the current default connection changed. Static and unsupported managed tasks
make no Docker calls. Offline smoke retains its separate backend contract.
An unfinished legacy coding attempt without provable original authority stays
unresolved; completed legacy history remains readable without a guessed cleanup
obligation. Newly missing or corrupt dispatched contexts fail closed.

All v2 contexts remain until targeted source/workspace purge. Purge rechecks original
ownership and absence, including previously cleaned v2 attempts, and retains the
context-bearing row through file-removal failures. An unavailable original daemon
therefore blocks purge for retry even after earlier successful cleanup. No unrelated
run or current-daemon sweep proves that cleanup. Restore clears execution context
and leaves results quarantined/unqualified without contacting the original daemon.
The additive nullable column does not rewrite historical rows, and rollback refuses
any nonnull context. Private backups remain unencrypted and contain the identifying
local endpoint path; public run, UI, CLI, MCP and package projections exclude it.

The ordinary offline checks are `mix test`. Actual Docker checks are opt-in:

```sh
docker pull ghcr.io/anomalyco/opencode:1.19.5
docker pull nginx:1.28.0-alpine
docker pull golang:1.25.3-alpine
HARNESSFORGE_DOCKER_TESTS=1 mix test test/harness_forge/execution_test.exs test/harness_forge/coding_evaluation_test.exs
```

The real smoke checks inspect applied resource constraints and test nonroot UID,
zero effective capabilities, no-new-privileges, denied root writes, no Docker
socket and loopback-only networking. Cancellation and output flooding also run
against actual containers. These checks use trusted fixed synthetic probes and
are distinct from coding-task qualification.

Implementation references: [Docker run options](https://docs.docker.com/reference/cli/docker/container/run/),
[OpenCode CLI](https://opencode.ai/docs/cli/), and
[OpenCode configuration precedence and provider allowlist](https://opencode.ai/docs/config/).

The real coding integration test uses a controlled synthetic Ollama-compatible
provider, actual pinned OpenCode/Docker execution, and actual protected Go
checks. It establishes protocol and isolation integration, not the quality of a
real selected language model. No real local model is configured in this build
environment. Finite task passes never establish a productivity claim.

The route decision trades a small fixed trusted proxy for portable model access:
using host networking for the agent would remove the required isolation, while a
host socket alone is unavailable in Docker Desktop. See Docker's
[isolated bridge gateway mode](https://docs.docker.com/engine/network/port-publishing/#gateway-modes)
for the host-gateway restriction. The wider threat model still trusts the local
Docker daemon, host operator, and configured loopback model service; a local
address is not proof that an operator-controlled service computes locally.
