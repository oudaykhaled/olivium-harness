# Use HarnessForge from an MCP client

HarnessForge’s local MCP endpoint lets an assistant find reusable company
repositories, check a reviewed plan, and inspect a built package’s current
eligibility. It is read-only. Continue approvals, building, export and evaluation
in the portal.

## 1. Enable MCP when starting the app

MCP is disabled by default. Load a separate operator-generated secret into your
shell using your normal secret manager. The secret must contain at least 32 random
bytes, encoded as 43–256 URL-safe characters. In the example below,
`HARNESSFORGE_LOCAL_MCP_BEARER` is the environment variable holding that secret;
its value is never part of the command.

```sh
HARNESSFORGE_MCP_ENABLED=true \
HARNESSFORGE_MCP_TOKEN_ENV=HARNESSFORGE_LOCAL_MCP_BEARER \
bin/harnessforge serve
```

Use this command from the source checkout or the extracted native package. Set
`HARNESSFORGE_WORKSPACE` before launch if you use a separate workspace; see the
[quickstart](quickstart.md). If the app is already running, stop that owner first
and restart it with these settings. A second process cannot open the same
workspace while the portal owns it.

**Browser sign-in and MCP access are separate.** The browser’s workspace access
code is not an MCP credential. Browser logout does not revoke the MCP bearer.
Do not place a secret in a URL, a checked-in client configuration, an exported
harness, or a screenshot.

## 2. Connect your client

Use a client that supports this exact connection profile:

| Setting | Value |
| --- | --- |
| Endpoint | `http://localhost:8865/mcp` — use your app’s port |
| Transport | Streamable HTTP with JSON POST responses |
| Protocol | MCP `2025-11-25` |
| Authentication | One `Authorization: Bearer <secret>` header, loaded from your client’s secure environment configuration |
| Available surface | Three read-only tools; no resources or prompts |

The client must receive the same secret through its supported secure setup.
HarnessForge does not configure Codex, Claude Code or other clients automatically.
Their model APIs and exported harness files are separate integrations.

The protocol uses `initialize`, then `notifications/initialized`; subsequent
requests require `MCP-Protocol-Version: 2025-11-25`. The endpoint has no session ID,
SSE stream, stdio mode or remote OAuth service. Authenticated GET and DELETE return
405. The newer `2026-07-28` protocol profile is not supported.

## 3. Ask a useful question

Start with a small tool call. IDs and digests below are placeholders.

| Tool | Example arguments | What it tells you |
| --- | --- | --- |
| `harnessforge_search_repositories` | `{"query":"authentication","limit":10}` | Matching repositories in the operator-authored capability catalogue. Catalogue entries are context, not reviewed policy. |
| `harnessforge_company_plans` | `{"limit":10}` | A bounded list of plans and their decision states. |
| `harnessforge_company_plans` | `{"plan_id":"<plan-uuid>"}` | Whether that exact plan is currently buildable, a blocker, its next action and any directly bound package digests. |
| `harnessforge_inspect_package` | `{"digest":"<64-character-lowercase-hex-digest>"}` | Verified stored bytes, current eligibility and local plan bindings. |

List limits default to 10 and cannot exceed 20. Check `truncated` and related
truncation fields before treating a result as complete. Plan lists are oldest
first and do not yet have pagination; inspect an exact known plan ID when needed.

A next action directs you back to existing portal controls. A proposed plan needs
an explicit exact-revision decision. An approved plan may still be blocked if its
inputs changed. An eligible approved predecessor can remain buildable after a
successor. Every later build or export performs its own checks.

## Understand the result

`integrity: "verified"` means the stored package bytes passed verification.
`eligible: true` means the current workspace permits its use at the time of the
read. Neither result establishes model quality, managed coding execution, or
release qualification. Package inspection reports
`qualification: "not_assessed_by_this_tool"`.

Plan bindings are local workspace provenance. Exported v1alpha1 packages do not
provide portable company-plan approval verification. The MCP tools return no
source bodies, claim/rule text, full plan snapshots or native instruction files.
They do not contact connectors, call a model, approve anything, build, export or
execute code.

## Stop access or fix a connection

To disable access, stop the owning app, unset `HARNESSFORGE_MCP_ENABLED` or set it
to a value other than `true`, then restart. To rotate the bearer, stop the app,
replace the referenced secret, update the client’s secure setup, and restart.
Changing another shell’s environment does not change a running app. Backups do
not carry this credential. Revocation prevents later reads; it cannot erase data
a client already received.

| Symptom | Next step |
| --- | --- |
| Endpoint returns 404 | Confirm the app’s port and restart it with MCP enabled. Disabled MCP has no available route. |
| Access denied | Check enablement, the environment-variable reference and the client’s bearer configuration. Signing into the browser does not fix MCP authentication. |
| Version rejected | Use the pinned `2025-11-25` profile and version header. |
| Privacy state unavailable | Finish or reconcile the pending privacy operation in the portal before retrying. |
| Plan or package blocked | Follow the returned next action in Company, Evidence or Packages; do not treat an old successful read as authority. |
| No matching repository | Check the capability terms and the company catalogue; MCP does not search remote repositories. |

## Compatibility evidence

On 1 November 2026, an independent official Node MCP SDK **1.29.0** client on
Node **26.3.1** passed **44 checks** against the separately built native candidate
at `http://127.0.0.1:8867/mcp`, using MCP **2025-11-25**; client exit status was 0.
It discovered exactly these three tools, found a synthetic repository, checked
proposed/approved/rejected plans and inspected an eligible package. Authentication,
origin, protocol and malformed-request refusal checks passed. Database content
and immutable artifact bytes were unchanged before and after the reads. Disabled
MCP returned 404. See the local [client report](../tmp/enhancement-program/01/qa/native-client-result.json)
and [native lifecycle record](../tmp/enhancement-program/01/qa/native-lifecycle.json).

This establishes the tested local SDK/transport behavior with synthetic company
data. Real Codex/Claude model-driven use, live connectors, managed execution and
other clients were not tested by this check.
