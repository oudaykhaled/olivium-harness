# Iteration 01 independent native MCP client validation

Owner: `/root/i01_api_qa`. Status: **native client acceptance passed** on
1 November 2026. Root signalled the isolated native candidate ready before any
client execution. No product files were edited by this reviewer.

The external client uses the already installed official
`@modelcontextprotocol/sdk` **1.29.0**, from
`/opt/homebrew/lib/node_modules/@modelcontextprotocol/server-memory/node_modules/@modelcontextprotocol/sdk`.
The selected protocol is **2025-11-25**, Streamable HTTP, against the isolated
native candidate at `http://127.0.0.1:8867/mcp`. The actual server identified itself
as **HarnessForge 0.1.0**; the actual client ran under **Node v26.3.1**. No
dependency installation, remote API call, model invocation or managed coding-agent
execution occurred.

## Observed result

The checked client command exited **0**, with **44 checks passed**. These are
native client/HTTP acceptance checks, not ExUnit test counts or code coverage.
The root's single Mix test window owns the canonical suite result.

- Official SDK initialization negotiated exactly the pinned version and discovered
  exactly the three frozen tools with read-only, idempotent local annotations.
- Capability search found `synthetic/mcp-identity`; whitespace search returned no
  results. The tool labelled catalogue authority as operator authored.
- Proposed and rejected plans were not buildable. The exact approved ancestor
  remained buildable after a proposed successor and exposed its exact bound
  package digest.
- Package inspection verified stored integrity, current eligibility and the exact
  local binding. It explicitly reported model qualification as unassessed and
  portable approval verification as unavailable.
- Unadvertised write tools, excessive limits, unknown plan/package IDs and an
  extra authority-bearing argument failed. Missing/wrong/duplicate bearer gave
  HTTP 401; hostile single Host, hostile Origin and duplicate Origins gave 403;
  absent/unsupported protocol headers gave 400; authenticated GET/DELETE gave 405;
  duplicate JSON keys, batch and null request ID gave 400; excessive raw bytes
  gave 413. Responses retained `Cache-Control: no-store`.
- The checked curl tools/list request returned HTTP 200 and exited 0.
  `time_starttransfer=0.001199s`, `time_total=0.001211s`, below the explicit
  two-second local smoke budget. One observation is not a p99/load benchmark.
- Existing `/login` remained HTTP 200 while the MCP endpoint was active.
- All **30 database tables** retained identical row counts and content hashes.
  This included 13 audit rows, 1 claim decision, 2 plan decisions, 3 plans,
  1 binding, 1 source connection, 0 evaluation/model-request/release rows.
  All **10 artifact files / 23,634 bytes** retained their exact content hashes.
  The first attempt's initial state also equals the final state.
- Recorded responses excluded the machine bearer, source-body sentinel, claim
  text and workspace path. The native server log excluded the bearer and source
  sentinel. No credentials were printed or passed as command arguments.

The first attempt passed 28 checks and then stopped because this reviewer's
request helper added a hostile Host alongside its default valid Host. That
constructed a different request than the intended single-host negative case.
The QA helper was corrected; the complete 44-check run then passed. The first
attempt and its initial state were preserved rather than erased; no product
change or relaxed assertion was used to obtain the pass.

Authoritative SSD evidence:

- `tmp/enhancement-program/01/qa/native-client-result.json`: complete sanitized
  SDK/raw exchange, versions, actual timestamps, command, exit status and checks.
- `tmp/enhancement-program/01/qa/before-state.json` and `after-state.json`: complete
  database counts/content hashes and immutable artifact byte/hash inventory.
- `tmp/enhancement-program/01/qa/native-client-attempt-1.json` and
  `before-state-attempt-1.json`: preserved QA-helper failure and initial state.
- `tmp/enhancement-program/01/qa/validation-summary.json`: compact machine-readable
  verdict, state counts and artifact inventory totals for retrospective handoff.

Reproduction artifacts:

- `tmp/enhancement-program/01/qa/provision-fixture.exs`: trusted application APIs
  provision one synthetic repository, an exact approved ancestor with one built
  package, its proposed successor and a rejected plan. It refuses a workspace
  outside the exact iteration-only path and refuses an already populated company
  catalogue. Root runs it only while the disposable workspace has no HTTP owner.
- `tmp/enhancement-program/01/qa/native-client.mjs`: official SDK initialization,
  exact three-tool discovery, capability search, proposed/approved/rejected plan
  observations, approved-ancestor semantics, bound-package inspection, forbidden
  tool/argument/unknown-ID failures and raw HTTP authentication, Host/Origin,
  protocol, method and parser negatives. It also runs a checked curl tools/list
  smoke with `time_starttransfer`, `time_total` and a two-second local smoke budget.
  Full database row counts/content hashes and immutable artifact bytes are
  compared before and after reads. Output and server-log checks reject the QA
  credential and synthetic source-body sentinel. Credential headers exist only
  in memory; the bearer is read from a private fixture file, never command args.

Root fixture invocation, after assembling the candidate (root provisioned the
actual fixture before the native server acquired its workspace):

```sh
HARNESSFORGE_WORKSPACE="$PWD/tmp/enhancement-program/01/mcp-workspace" \
HARNESSFORGE_QA_EXPECT_WORKSPACE="$PWD/tmp/enhancement-program/01/mcp-workspace" \
HARNESSFORGE_QA_MANIFEST_FILE="$PWD/tmp/enhancement-program/01/qa/fixture.json" \
HARNESSFORGE_QA_SCRIPT="$PWD/tmp/enhancement-program/01/qa/provision-fixture.exs" \
RELEASE_DISTRIBUTION=none \
tmp/enhancement-program/01/native-candidate/bin/harness_forge eval \
'Code.eval_file(System.fetch_env!("HARNESSFORGE_QA_SCRIPT"))'
```

Set `HARNESSFORGE_QA_SCRIPT` to the absolute provisioning script path. Root owns
candidate startup and a separately generated MCP bearer. Never use the browser
access code, a running real workspace or either existing application's process.
After startup, the client command takes only paths to private fixture metadata
and the generated bearer:

```sh
QA_MCP_TOKEN_FILE=<private fixture file> \
QA_MCP_FIXTURE_FILE="$PWD/tmp/enhancement-program/01/qa/fixture.json" \
QA_MCP_LOG_FILE=<candidate native log> \
node tmp/enhancement-program/01/qa/native-client.mjs
```

The command exit status, package/version, sanitized exchange, state comparisons
and exact check count are recorded in the evidence above. Non-loopback peer
simulation, process-environment credential rotation, privacy race ordering and
restored-workspace quarantine additionally require the dedicated HTTP/domain test
lane; an external loopback client alone cannot prove those internal conditions.
Canonical test-suite counts belong to the root's single Mix test window.
