# MCP server: first useful contract

**Priority: P1.** The program explicitly calls for HarnessForge’s own MCP server, but today a coding assistant can only consume generated harness files; there is no way to ask the running workspace whether a company plan is approved and buildable. A user must switch to the portal to find a plan ID, then infer readiness from several records. The first slice should answer that question inside the assistant, without granting it approval or execution authority.

## Proposal

Add an opt-in MCP endpoint to the **existing running Phoenix process** at `POST /mcp`, using the app’s loopback listener. A second `mix` process would contend for the workspace’s exclusive SQLite lock (`lib/harness_forge/workspaces.ex:40-52`), while the current endpoint is already supervised in `lib/harness_forge/application.ex:18-24` and binds `127.0.0.1` in `config/runtime.exs:31-34`. Require a bearer value matching the existing workspace access token, constant-time compared; never include that token in responses, logs, URLs or generated client config. Reject non-loopback requests even if deployment config changes the bind address. Expose no browser session or CSRF bypass. Document a manual local client setup that reads the token through the operator’s own secure configuration, without printing it.

Implement the current [MCP 2026-07-28 protocol](https://blog.modelcontextprotocol.io/posts/2026-07-28/) over Streamable HTTP: JSON-RPC 2.0, `server/discover`, `tools/list`, and `tools/call`, with the revision metadata required for each request. Advertise **only tools**; no resources, prompts, subscriptions, sampling, client roots, or mutation tools in this slice. Keep tool order and output deterministic. Unsupported versions and methods return protocol errors, not invented success. Record the exact supported version so compatibility with older clients is explicit.

## Minimal tools

1. `harnessforge_list_plans` takes `{}` and returns at most 100 entries: `id`, `name`, `revision_hash`, `status`, `superseded`. It projects `Company.list_plans/0` (`lib/harness_forge/company.ex:104-108`) rather than returning the full plan snapshot. Include an explicit truncation flag if the cap is reached.
2. `harnessforge_inspect_plan` takes `{plan_id: UUID}` and returns the same identity fields plus `buildable: boolean` and a stable `blocker_code` when false. Query `Company.get_plan/1` and `Company.build_inputs/1` (`lib/harness_forge/company.ex:99-101,139-170`); the latter already checks exact approval, revision, and current eligibility. Do not return claim text, citations, source bodies, secrets, full snapshots, or build inputs. “Buildable” is a current preflight observation, not a reservation or guarantee that a later build will succeed. Require `Privacy.Purge.ready/0` before either read, so an incomplete purge is not exposed (`lib/harness_forge/privacy/purge.ex:10-18`).

Both results use string-keyed JSON. Map known domain errors to stable, user-readable blocker codes; suppress internal exceptions and filesystem paths. No MCP tool may call `decide_plan`, `build_plan`, export, sync, inference, or shell execution. The existing plan DTO reports decision status and supersession (`lib/harness_forge/company.ex:349-361`); the tool explicitly projects only safe fields.

## Acceptance and negative tests

- A real MCP client connects to the local running server, discovers exactly these two tools, lists a synthetic proposed and approved plan, and sees the approved eligible plan report `buildable: true`; a proposed plan reports `plan_not_approved`.
- An approved plan whose cited evidence becomes ineligible reports `buildable: false` with the existing eligibility reason. A superseded or stale revision cannot be presented as ready.
- Missing/wrong bearer token, non-loopback peer, malformed JSON-RPC, unsupported revision, unknown tool, invalid UUID, and incomplete purge fail closed with no sensitive response content. No request mutates audit or plan tables. Test output contains no source body, token, or local path.
- Run protocol conformance against a current MCP client plus `mix test`; fixture tests establish local behavior only, not broad client compatibility.

## Risks

The 2026 protocol is newer than some installed clients; an older client will need a later compatibility slice. An access token passed through a client’s plain-text config can leak, so setup documentation should avoid embedding it. The preflight can race with later evidence changes; the response must say “currently buildable,” and actual builds must retain their existing rechecks (`lib/harness_forge/harnesses.ex:12-29`).
