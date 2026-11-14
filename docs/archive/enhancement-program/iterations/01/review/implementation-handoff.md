# Iteration 01 implementation handoff

Owner: `/root/i01_implementation`. Source ownership and the serialized Mix window
are released to root. Both principal author tasks completed; neither spawned a
child or ran an independent Mix process. This record establishes focused source
verification, not iteration completion or external client compatibility.

## Delivered source

| Owner | Files | Behavior |
| --- | --- | --- |
| `/root/i01_implementation/protocol_author` | `lib/harness_forge/mcp/auth.ex`, `lib/harness_forge/mcp/protocol.ex`, `lib/harness_forge_web/plugs/mcp.ex` | Explicit machine authentication; pinned stateless MCP 2025-11-25 lifecycle; raw bounded parsing; safe protocol/tool errors; purge-fenced read, encode and send |
| Same | `test/harness_forge/mcp_protocol_test.exs`, `test/harness_forge_web/mcp_test.exs` | 17 tests covering lifecycle, authentication/headers/peer, malformed input, credential boundary, prepared purge, dispatch race, queued reauthentication, output limit and exception no-store |
| `/root/i01_implementation/tools_author` | `lib/harness_forge/mcp/tools.ex` | Exactly three safe read-only tools; bounded search/list/inspect projections; exact package integrity and current admission |
| Same | `test/harness_forge/mcp_tools_test.exs` | 16 tests covering synthetic company states, safe fields, capped SQL projection, maximum catalogue, binding caps, foreign IDs, verified/tampered/legacy packages and no mutations |
| Root | Runtime configuration and exact LocalOrigin wrapper integration | Dedicated `/mcp` handling before generic parser while preserving other guards |

The tool layer extends the existing `Company.search_capabilities/1`,
`Company.get_plan/1`, `Company.build_inputs/1`, `Harnesses.get/1`,
`Harnesses.eligible/1` and workspace-scoped `Store` queries. It does not change
company approval semantics, compiler identity, manifests, migrations or runtime
qualification. Catalogue rows are data. An eligible approved ancestor remains
buildable after a successor; multiple artifact bindings retain domain semantics.

The protocol accepts omitted `tools/call.arguments` as `{}` because that field is
optional in the selected protocol; explicit `null` remains invalid. This bounded
compatibility correction adds no new tool capability. Response overflow retains
the already validated request ID while returning only a fixed error.

## Actual local verification

All commands ran from the project root with `HARNESSFORGE_WORKSPACE` unset and
`MIX_ENV=test`, serially under the exclusive coordinator window. Logs and a command
manifest are under `tmp/enhancement-program/01/` on the local evidence filesystem.

| Check | Actual result | Evidence filename |
| --- | --- | --- |
| Initial combined focus | Exit 2; 85 tests, 3 failures | `implementation-focused.log` |
| Corrected combined focus | Exit 0; 85 tests, zero failures; one unused test-helper default warning subsequently removed | `implementation-focused-r2.log` |
| Pre-guardrail final focus | Exit 0; 85 tests, zero failures, 4.2 seconds, seed 0, no warnings | `implementation-focused-final.log` |
| **Final focus after independent guardrail correction** | **Exit 0; 86 tests, zero failures, 4.7 seconds, seed 0, no skips or warnings** | **`implementation-focused-guardrail.log`** |
| Whole-project format check | Exit 0 | `implementation-format-check-final.log` |
| Test-environment compile, warnings as errors | Exit 0 | `implementation-compile-final.log` |
| Existing CI Credo warning gate | Exit 0; 151 files, 2,098 modules/functions, no warning issues | `implementation-credo-warning-final.log` |
| Additional unfiltered strict style scan | Exit 14; readability/design/refactoring findings; not the repository CI gate and not claimed as passed | `implementation-credo.log` |
| **Final post-Dialyzer-correction focus** | **Exit 0; 86 tests, zero failures, 4.5 seconds, seed 0** | **`implementation-focused-dialyzer-fix.log`** |
| Post-correction format, warning-gated compile, CI Credo warning gate | All exit 0 | `implementation-format-dialyzer-fix.log`, `implementation-compile-dialyzer-fix.log`, `implementation-credo-dialyzer-fix.log` |
| Final Dialyzer | Exit 2; exactly the two existing `releases.ex:47/121` opacity diagnostics, no new MCP diagnostics | `implementation-dialyzer-final.log` |

The 86-test focus contains 33 new tests and 53 existing company/domain/privacy and
portal tests. It includes `company_test`, `company_harnesses_test`,
`company_acceptance_test`, `company_privacy_test`, `company_builder_test` and
`portal_test`. Existing portal cases cover browser authorization/origin/socket
behavior. Coverage percentage was not measured. Dialyzer remains a baseline
failure with exactly the prior two opacity diagnostics; it is not claimed passed.

## Failures and smallest corrections

1. SQLite rejects Ecto's column-specific `distinct` form. The new scalar
   superseded-plan query now uses ordinary `distinct: true`.
2. Plug intentionally rejects setting Host through `put_req_header`. Negative
   test fixtures now compose hostile/duplicate raw request headers directly; no
   product Host check was relaxed.
3. Elixir 1.19 warned about a potentially empty generated list and an unused
   private helper default. Tests now destructure the nonempty fixture list and
   remove the unused default.
4. Root's independent guardrail review identified that a rescued exception could
   use the original connection before its no-store assignment. `failure/5` now
   sets no-store itself. A test-only throwing body adapter proves fixed internal
   error output, no-store and no reflected sentinel/token. The final 86-test run
   includes this correction.
5. Independent regression subsequently found four new Dialyzer unreachable-pattern
   diagnostics. The same sole authors removed only the inferred unreachable
   `default_port` and `tool_reply` fallbacks in lane A, and `inspect_plan` and
   `readiness` fallbacks in lane B. Existing outer rescue/catch boundaries, types
   and authority remain unchanged; there are no warning suppressions. Post-fix
   focused tests and gates passed, and Dialyzer returned to exactly its two
   existing release opacity diagnostics. Both authors released ownership again.

## Root's next verification

- Run canonical `mix test` and independent source/security review. Preserve exact
  baseline skips and existing Dialyzer diagnostics in final reporting.
- Exercise the actual official SDK 1.29.0 against the distinct native candidate,
  including company search, plan readiness and exact package metadata. Do not use
  the running baseline installations or their workspaces for fixtures.
- Record actual native/client commands, versions, sanitized transcript and exit
  statuses. Unit and endpoint tests alone do not establish this interoperability.
- Finish the required five independent retrospectives and next-iteration handoff.

No remote provider call, private import, paid model call, generated-code execution,
publication, app restart or default native release replacement was performed by
this implementation coordinator or its two authors. Real model/company fitness,
managed Codex/Claude execution and newer MCP profiles remain outside this result.
The local quarantine test reproduces withdrawn authority states; the included
existing company privacy regression supplies actual backup/restore semantics.
