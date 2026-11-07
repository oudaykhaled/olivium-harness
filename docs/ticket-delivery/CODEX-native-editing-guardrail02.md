## GUARDRAIL BRIEF — Native Codex editing without lowering exported shell policy

**Classification:** Runtime permission mapping choice; imported artifact inspected as data, never workspace instructions.

**Verdict:** PROCEED-WITH-CONDITIONS for a native approval-mediated path. Do not treat shell-enabled/never as policy-conformant execution of this artifact.

**Binding distinction:** The user forbids host execution and permits isolated local real-agent work; shell-disabled was an implementation choice, not a user prohibition. However, this exact export requests tool_permissions.bash=ask, uses approval_policy=on-request, and instructs its implementer to stop at unsupported permissions. The capability is required:false/unsupported: this permits an explicitly unqualified preview, not silent conversion of ask to allow. Its production-review rule does not create an approval gate for implementing this runner.

**Evidence:** The catalog-only refusing run offers request_user_input and view_image, with zero model/upstream calls and no editing tool. This proves the observed catalog, not successful inference. Freeform-only apply_patch and Ollama function_call limitations are supplied upstream findings, not independently reverified here.

**Smallest compatible path:** Reuse native Codex app-server command approval handling within the existing isolated runner, metered relay, cancellation and cleanup lifecycle. Enable native exec_command only when the supported native policy/controller actually intercepts the shell operations covered by ask. Merely setting on-request is insufficient proof: verify whether ordinary in-sandbox commands can run without review. Route an intercepted request through the existing authorized review mechanism, binding the exact command, working directory, run, artifact and permission scope. Reuse an already applicable exact authorization; do not create blanket auto-accept, prepopulate fake approval or request another generic permission to continue. No request is needed now to implement this path.

**Precise blocker:** If the native interface cannot mediate the requested shell-review policy, or no compatible approval response mechanism exists, this artifact's shell editing remains unsupported until that implementation exists. A previously tested native custom editing bridge is an alternative only with evidence that it avoids shell execution and preserves the same boundaries; do not invent a semantic codec, CLI fork or unverified bridge to conceal the limitation.

**Checks before task PASS:** Preserve pinned nonroot/read-only-root/container isolation, no host/socket/external network, bounded candidate writes, protected grader separation, source/currentness and metering. Denial, cancellation, deadline and absent approval must cause zero command execution. Record effective permission configuration and actual decisions alongside unchanged exported bytes. Never change target/policies/tickets or use paid fallback merely to obtain a green result.

**Knowledge base:** Unchanged. Read audit pins the public export and catalog evidence; no commands, model calls, runtime, tests, product or board changes performed.
