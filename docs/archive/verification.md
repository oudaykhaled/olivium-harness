# Local verification record

Checked 31 October 2026. This record distinguishes local observations from model qualification, live provider coverage and publication. The build board is [PROGRESS.md](PROGRESS.md).

## Observed application behavior

A real Chromium browser connected to the loopback Phoenix server and completed:

- Access-code login using the actual CSRF-protected form and encrypted session cookie.
- Synthetic document import, explicit rejection of an injected instruction, and explicit approval of the two supported claims.
- Native package build and export into a fresh directory. Exported guidance contains the approved rule and excludes the rejected credential-exfiltration instruction.
- Background static evaluation passing with runtime qualification false; matching recorded evaluations compared without a qualification claim; a model task persisting blocked; release approval rejecting a diagnostic run.
- Mobile navigation to privacy, a consistent backup into a fresh directory, and desktop/mobile rendering with no JavaScript errors or horizontal page overflow.

The browser check is `test/browser/smoke.cjs`; screenshots are local ignored files in `test/browser/results/`. It reads the access code locally without printing or recording its value.

Browser verification found and fixed a real login issue: Chromium submits `Origin: null` for the form with the original `no-referrer` policy. The current `same-origin` policy preserves same-origin form authentication and suppresses referrers to other origins. Exact local Host/Origin validation and CSRF protection remain enabled. Mobile privacy and audit navigation remain accessible.

## Independent review

The stable application paths received a separate read-only security review. Three reproduced defects were fixed and independently rechecked:

- Logout rotates the workspace session epoch, redirects connected tabs and rejects old-session reconnects.
- Export holds the shared purge fence through eligibility checking, destination-lock waits and publication. A deterministic concurrency test proves purge waits for an export already in progress and rejects exports afterward.
- Audit events retain bounded artifact, release and evaluation identifiers while dropping credentials and source bodies.

The reviewer observed 54 existing tests pass, then 31 focused regression tests pass after the fixes. The coding execution path has a separate review and final result recorded below when complete.

## Live external check

An unauthenticated, read-only GitHub request captured public metadata for `elixir-lang/elixir`: one source imported, `complete: false`, and a durable cursor for the issues stage. This proves that bounded metadata page only. Remaining GitHub pages, authenticated scopes, rate limiting and Jira live support are not inferred from it. Jira has fixture coverage and requires an operator-selected tenant/project and environment credential references for a live check.

No installed Ollama model or live model inference was available. No paid provider calls or private imports occurred. Synthetic provider tests are protocol checks and never count as model quality or pilot evidence.

## Tooling and packaging

Compilation with warnings as errors and `mix credo --strict --only warning` passed. This is the warning category gate; full strict-style compliance is not claimed.

Dialyzer was actually run. The unreachable coding branch and URI construction findings were corrected. The subsequent run reports two `call_without_opaque` diagnostics at `Ecto.Multi.run/3` in release approval and assignment. Their inferred embedded MapSet matches the [upstream Elixir/OTP 28 issue](https://github.com/elixir-lang/elixir/issues/14576); this attribution is an inference from the diagnostic and reproducer. Dialyzer exits 2 and is **not clean**. There is no warning suppression. The workflow leaves this analysis as a manually triggered job while ordinary build/test gates remain active.

Native production assembly, archive checksums, notice inventory and real packaged CLI commands passed on macOS arm64. See [packaging/VERIFICATION.md](../../packaging/VERIFICATION.md). Rebuild the archive after final source integration. A configured Linux workflow is not an observed Linux CI run.

All four GitHub Actions commit pins were checked against their public repositories. An invalid setup-beam SHA was replaced with the actual v1 commit `54075bcc5e249e4758d363f27d099f55d843f124` before handoff.

## Final integration

- Ordinary suite: `mix test` — **129 tests, zero failures, 15 skipped**. The skips are opt-in Docker cases, exercised separately below.
- Docker-enabled offline execution/evaluation suite — **14 tests, zero failures**; real containment, version/config loading, cancellation, flooding and cleanup/recovery.
- Independently run Docker-enabled coding suite — **13 tests, zero failures**, 165.3 seconds. This covers actual pinned OpenCode edits of both synthetic Go tasks through a controlled HTTP/SSE provider, protected objective checks, seven AST attacks, forged initializer rejection, cancellation before and during execution, a one-second timeout, one-request ledger cap, cancelled-pending recovery and offline startup behavior. This is a protocol/runtime check, not a real-model pilot.
- Compiler warnings-as-errors, formatter and Credo warning category gate passed. Full strict-style compliance is not claimed. Final Dialyzer result is the two documented opacity diagnostics above; it exits 2.
- Final privacy/admission regressions: **14 tests, zero failures**; independently reviewed with no remaining finding. Purge waits for active evaluations before making a durable fence. New evaluation admission shares that fence through its pending-row insert. Startup cancels stale current-workspace executing jobs before evaluation/privacy recovery so uncertain work is not replayed and recovery can finish.
- Final portal refresh/comparison regression: **11 tests, zero failures**; terminal results remain unchanged by cancellation.
- Real browser workflow passed, including evaluation comparison and mobile backup. No model, private data or paid provider was used.
- Native macOS arm64 release assembled and packaged CLI smoke passed. The final archive is rebuilt from the integrated tree; logs are under ignored `tmp/packaging-final-*.log`.

The coding reviewer closed grader-forgery, cancellation/admission and execution-limit findings. Completed clean evaluation history allows authoring startup without Docker; unresolved cleanup still blocks readiness. Exact owned abandoned debug resources were removed after label inspection.

No commit, merge, upload, public release or hosted deployment has occurred.

The rebuilt **native release server** also passed the complete browser workflow on loopback port 8865, including login, review, build/export, queued evaluation/comparison, rejected diagnostic release and mobile backup. Log: `tmp/browser-native-release.log`. The running process uses the packaged release. Final archive SHA-256: `8e76a807d80d9e5a06b83f9494dadead552d2244cccb342e8037ebcd773ce41c`; 12,051,839 bytes. The archive excludes workspace secrets/databases and includes the protected AST grader. Packaged documentation records its build-time verification snapshot; these final runtime observations are in the source verification record.

## All-five integration expansion — 31 October 2026

Implemented GitHub Projects v2, Slack channels/replies and Confluence current
pages, alongside GitHub repositories and Jira projects. Each has provider-specific
portal setup, CLI commands, credential references, durable cursors and a second
selected-source import boundary. Transport remains read-only: fixed GETs or
compiled-in Projects GraphQL query POSTs, with mutations/redirects rejected.

Observed before final package build:

- Full `mix test`: **187 tests, zero failures, 15 existing Docker opt-in skips**.
- Slack: **19 tests**; Confluence: **13 tests**; Projects: **20 tests**.
- New shared-boundary and portal/CLI tests cover all five setup paths, credential-free queued jobs, rejected raw-token config, fixed GraphQL origin/query policy, 4 MiB transport bounds and forged-source rejection.
- Independent reviewer ran **38 focused tests**, then **34 Projects/GitHub/Jira tests**, both with zero failures.
- Fourteen captured Projects query shapes validated against GitHub's current official published schema; SHA-256 `ee690896ae7d9126765c6a660174b40c9d1974b70db36af8559117b9c4a7b7a6`.
- Review found a pre-existing GitHub database-ID cap that rejected real current issue IDs. Added bounded positive 64-bit database IDs, preserving smaller issue-number bounds, and updated actual Evidence fixtures to use realistic 6.1-billion IDs/review fragments.
- Formatter, warning-free compilation and Credo warning gate passed.
- Dialyzer rerun reports exactly the same two documented Ecto/MapSet opacity diagnostics in releases.ex; **no new connector findings**, exit 2. Log: `tmp/integrations-dialyzer.log`.

API fixture results do not qualify authenticated live integrations. GitHub public
metadata passed previously; all five authenticated checks still need API credential
references and individual selected resource IDs. Browser sign-in alone does not
supply those. Jira and Confluence tenant pages remain unavailable. No private
content or token was extracted from a browser, no external content was mutated,
and no source claim was automatically approved.

Independent integration review closed with **zero open findings**. The Projects
malformed nested field-value response could propagate a raw non-map value; it now
returns a sanitized structured error. String/list/integer regression fixtures
prove no leakage, evidence commit or cursor advance. Reviewer independently ran
the final sentinel regression (1 test, zero failures), in addition to its earlier
38- and 34-test packs. All 14 fixed GraphQL query shapes were independently
validated against GitHub's published schema.

### GitHub real pagination compatibility follow-up

The first native live issues page correctly failed closed on GitHub's current
numeric repository Link path and opaque after cursor. The corrected adapter
verifies the selected repository ID, retains the cursor through PR reviews and
reconstructs requests to the configured repository. Legacy cursors reverify
metadata without losing their page/watermark. Foreign IDs/origins, altered
filters, duplicate/malformed/repeated links reject atomically. See
[GitHub pagination details](../github-repository-pagination.md). Numeric review URL
aliases remain unsupported rather than being accepted without live evidence.

Final `mix test`: **191 tests, zero failures, 15 existing Docker skips**.
Independent round-2 review: **21 tests, zero failures**, no remaining findings.
Format, compiler warnings-as-errors and Credo warning gate pass. Native rebuild
and actual page retry are recorded below after observation.

### Final native observations

The corrected native macOS arm64 release is running on loopback port 8865.
Actual Chrome login passed after restart. All five provider-specific forms were
selected and verified visible; no horizontal overflow or JavaScript errors were
observed. Packaged CLI `help/init/demo/status` and configuration commands for
**all five providers** passed using a disposable synthetic workspace; no remote
requests are made by those setup commands.

Through the real portal and durable background job, the existing public GitHub
connection recovered its legacy cursor, reverified repository ID `1234714`, and
imported **30 public issue/PR snapshots**. The workspace now has 32 sources:
31 public GitHub snapshots including earlier repository metadata, plus the
synthetic handbook. No proposals/approvals were created by sync. One subsequent
real public PR-review page completed and advanced pending reviews from 21 to 20;
the next issue page remains 2 and its opaque after cursor stays intact. The
connection is active, `sync_state=incomplete`, `sync_complete=false`. The full
repository scan is not claimed complete.

Screenshot: ignored `tmp/integrations-native-final-2026-10-31.jpg`. Runtime logs:
`tmp/integrations-native-server.log`; read-only cursor observations:
`tmp/integrations-live-github-result.json`. Final code suite: **191 tests, zero
failures, 15 existing Docker opt-in skips**; no connector tests skipped.

Native archive: `tmp/packages/harnessforge-0.1.0-darwin-aarch64-apple-darwin24.6.0.tar.gz`, 12,108,612 bytes. SHA-256:
`0df7fbcbc4b5016e4f7e1d3b41b8c74e8a87e2cdd0a0b27421a4a6356523900d`. Checksum, safe archive paths, exclusion of workspace databases/login
secrets and presence of all five provider modules plus Registry passed. Build
and packaged CLI smoke logs: `tmp/integrations-package-build.log` and
`tmp/integrations-package-smoke.log`. Packaged documentation is its build-time
snapshot; final runtime observations are recorded here and in the companion
verification report next to the archive.

Authenticated GitHub/Projects/Slack/Jira/Confluence verification remains blocked
by absent operator API credentials and selected live resource IDs; the Jira and
Confluence tenant is also unavailable. Browser login is not API authentication.
This does not block the completed adapters, automated conformance, UI/CLI setup,
public GitHub check or local package. No private import, remote mutation,
publication or paid inference occurred.

Final post-pagination Dialyzer rerun still reports exactly the two pre-existing
release Ecto/MapSet opacity diagnostics, with zero new connector diagnostics.
Exit 2 remains explicit. The native server's observed owner is PID 5404; its
console log is in the ignored runtime log above. All worker lanes and independent
reviews are finished; no implementation work remains pending in a child agent.

## Codex and Claude connectors — 31 October 2026

This follow-up supersedes the earlier suite/package/server observations above.
Codex CLI and Claude Code native exports plus OpenAI Responses and Anthropic
Messages APIs are implemented and independently reviewed. Final canonical suite:
**245 tests, zero failures, 15 existing Docker-only skips**. Formatter, compiler
warnings-as-errors and Credo warning gate pass. Dialyzer retains exactly the two
existing release opacity diagnostics and no new connector diagnostics.

Real pinned native CLIs passed isolated discovery/configuration checks without
credentials or model calls. Actual Chrome built/exported both new targets and
recorded passing static checks plus blocked managed tasks. Packaged CLI builds
and both API configuration paths passed. Current loopback server owner is PID
43484. Full commands, limits, artifact identities and evidence locations are in
[the coding connector verification record](coding-connectors-verification.md).
Authenticated inference and Codex/Claude managed execution remain unqualified.

## Chatbot across connectors — 31 October 2026

The new [Chat screen and CLI](../chat.md) provide current evidence lookup across
all six source types and optional cited answers through all four model providers.
Final canonical suite: **285 tests, zero failures, 15 existing Docker-only skips**.
The formatter/compiler/Credo warning gate passes; two existing release Dialyzer
diagnostics remain. Independent review approved with no open findings after log
redaction and batched revalidation fixes. Native Chrome submission/citations,
clear and unavailable-model states passed. See [chat verification](chat-verification.md)
for exact tests, scope, evidence locations and live-model limitations.
