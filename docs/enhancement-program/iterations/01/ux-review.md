# Iteration 01 UX input: a clear read-only MCP setup

Scope: operator documentation and fixed next-action meaning for the functional
MCP slice. No product screen was changed or visually validated by this role. No
Figma fidelity claim applies. The existing Phoenix components and project design
tokens remain the design starting point for iteration 02.

Reviewed inputs: the program, all 16 planning reports, the guardrail brief and the
final Astra decision. The principal setup risks are confusing browser login with
machine authorization, mistaking a successful read for approval, and treating
verified package bytes as proof of company fitness.

The [MCP guide](../../../mcp.md) follows one short path: enable the existing app,
connect a supported client, then ask a useful read-only question. It uses an
environment-variable name and placeholders, never a credential value. Setup
does not add a second workspace owner or write client settings automatically.
The tool table separates catalogue context, plan readiness and package
eligibility. Approval, current authority and runtime qualification are described
separately. Truncated lists and local-only provenance are explicit.

The independent MCP credential intentionally survives browser logout. The guide
therefore puts the distinction beside setup and gives the actual
stop/reconfigure/restart procedure. It does not suggest that logging out,
changing another shell or restoring a backup revokes a running machine client.

## Iteration 02 recommendation

Make Company the starting point for building a company harness. Use a compact,
state-aware progress summary with **one primary next action**, followed by the
existing detailed forms behind expandable sections. Suggested structure:

```text
Company harness                         Example Works
Next: Review the proposed plan          [Review plan]

Context ✓  Evidence ✓  Plan needs review
Package —  Evaluation unavailable  Release blocked

[Company details] [Repositories & project] [Plan details]

Use an MCP client  [Show setup]
Disabled · Local read-only access
```

The labels above are a proposed wireframe, not current product behavior. Show
each state in text as well as color; keep progress visible on narrow screens.
The active next action should navigate to the existing control, use a meaningful
heading/focus target, and preserve the draft. Explain an unavailable dependency
beside the affected step rather than presenting another full setup form.

The MCP disclosure should show enablement, the local endpoint, supported profile,
three plain-language read-only purposes and a link to the guide. Show no token or
credential value and do not imply that browser login connects an MCP client.
Keep advanced protocol and rotation details in the guide. This reduces initial
choices while preserving the exact review and release boundaries.

Acceptance for the next UX iteration should include a first-time synthetic
company journey, a keyboard-only pass, a narrow-screen screenshot, and a blocked
runtime state that still identifies the available next action. Record observed
actions and screenshots on SSD. Do not claim accessibility conformance from a
wireframe alone.

## Verification boundary

The guide now reflects the observed [native client report](../../../../tmp/enhancement-program/01/qa/native-client-result.json):
official SDK 1.29.0, Node 26.3.1, MCP 2025-11-25, exit 0 and 44 passed checks.
The separately built/provisioned native candidate exited 0 in both preparation
steps; disabled MCP returned 404. Three-tool discovery, synthetic company
readiness, refusal cases and unchanged database/artifact content were observed.
Real Codex/Claude model use and company fitness were not tested.

Root also signed into the candidate on port 8867 and reached Company in Chrome;
the [screenshot](../../../../tmp/enhancement-program/01/browser/company-before-ux.png)
and [DOM record](../../../../tmp/enhancement-program/01/browser/company-dom.txt)
are a baseline for iteration 02. Iteration 01 adds no UI polish or visual parity
claim. Independent canonical checks registered 403 tests: 388 passed, zero failed,
15 existing skips. Two baseline Dialyzer diagnostics remain. No tests or client
commands were run by this documentation role; these are reviewed evidence from
the validation roles, not an accessibility conformance claim.
