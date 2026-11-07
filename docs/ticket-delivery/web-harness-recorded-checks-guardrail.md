## GUARDRAIL BRIEF — Recorded checks beside the exact harness

**Classification:** Additive authenticated preview metadata/display · read-only · existing artifact authority unchanged.

**Verdict:** PROCEED-WITH-CONDITIONS. No blocking questions.

**Guardrails that apply (ranked):**
1. [harness_delivery.ex:71–88] Read historical metadata only inside the existing authenticated, workspace-scoped, purge-fenced eligible-artifact preview path. Bind the query to the server’s workspace and the digest from the verified artifact. No client-provided workspace, broad history fallback or record lookup by unscoped ID. Keep every current artifact eligibility/integrity check and download behavior intact.
2. [evaluation/run.ex:5–10] The schema stores outcomes inside `result`, not separate kind/outcome columns. Project only approved scalar JSON fields at the database query layer plus ID/inserted_at; never load the `Run` struct, full result map or execution_context and trim afterward. Select at most ten matching rows, ordered by inserted_at descending with ID tie-breaker. Bound/validate each scalar; malformed or unknown values display unknown. Allowlisted reason labels must not expose arbitrary recorded strings, logs, graders, prompts or JSON.
3. [harness_delivery.ex:38–45; evaluation_reason.ex:23–66] Render “Previously recorded checks for this exact harness,” with dates, check kind, recorded outcome and reason; place exact run IDs in details. Keep recorded static PASS separate from recorded task/runtime BLOCKED and from present byte integrity/eligibility. State that historical records do not establish current applicability, company quality or release admission. Do not upgrade representative-task/current-release fields or derive a new end-to-end claim.
4. [AGENTS.md; requested scope] Empty history means no matching recorded checks; read failure means history unavailable, never a fabricated empty list or pass. Isolate optional history-read failure without granting otherwise-ineligible artifact access. No provider probes, runtime discovery, execution, rescheduling, private imports or additional feature work. Root remains the sole board/runtime owner; preserve disjoint service/UI ownership.

**Hard STOPs:** No full evaluation/assessment hydration, protected content, cached authorization, best-result cherry-picking, or historical-pass admission shortcut.

**Definition of done:**
- [ ] Service returns only bounded allowlisted fields for exact workspace/digest; wrong-workspace/artifact records cannot appear.
- [ ] Latest-ten ordering, malformed metadata, empty history and read failure have honest outcomes; revoked artifacts disclose no files/history.
- [ ] Root verifies the real artifact page shows recorded static PASS and task/runtime BLOCKED while current qualification remains separate; no dispatch is triggered.

**Knowledge base:** Unchanged. Exact read ranges/hashes are in `tmp/ticket-delivery/web-outcome/recorded-checks-guardrail-audit.json`. Browser ZIP/check outcomes are Root-reported, not independently rerun here.
