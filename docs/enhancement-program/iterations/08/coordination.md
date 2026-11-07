# Coordination Plan: Iteration 08 package-name build recovery

**Classification**: planning
**Pattern**: composed: map-reduce + handoff + review-loop
**Total agents involved**: 19 in this completed planning phase, including root. Later phases are root handoffs and have not been dispatched.

## Agents involved (in order of first involvement)

Capability citations below refer to `/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md`. Exact original task IDs, requested models, fork settings, messages and task-file hashes are retained in `tmp/enhancement-program/08/conductor08-dispatch-receipt.json`.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
| 1 | `staff-agent-orchestrator` | Root and fresh 08 conductor | Meta-orchestration: explicit handoffs, specialty boundaries and coordination shapes |
| 2 | `staff-tech-lead` | One new Astra decision maker; two independent Sol lenses | Architecture decisions, ADR discipline, capacity and blast-radius risk |
| 3 | `staff-product-owner` | Three independent Sol journey/cognitive-load lenses | Jobs to be done, requirements and falsifiable acceptance; discovery differs from delivery |
| 4 | `staff-documentation-writer` | Two independent Sol copy/information lenses | Information architecture and stable error/recovery guidance |
| 5 | `principal-qa-web-playwright` | Two independent Sol keyboard/zoom lenses; later independent QA | Accessibility locators, real browser behavior and visual evidence |
| 6 | `principal-elixir-engineer` | Two independent Sol validation/state lenses; later bounded authors | Phoenix LiveView state and Ecto/context boundaries |
| 7 | `principal-security-auditor` | Two independent Sol privacy/authority lenses; later guardrail review | Access control, injection and integrity controls |
| 8 | `principal-qa-api-curl` | One Sol own-MCP lens; later contract QA if relevant | API contract, negative and smoke testing |
| 9 | `principal-frontend-perf-engineer` | One Sol polling/focus lens | Interaction stability and lab-versus-field evidence discipline |
| 10 | `staff-qa-lead` | One Sol test-oracle lens; later evidence/retrospective role | Test pyramid, evidence and quality-gate ownership |
| 11 | `principal-code-reviewer` | Later independent review loop | Correctness, security, performance, tests, docs and observability |

The [existing conductor contract](../../conductor.md) resolves the capability-map omission with the exact supported runtime role **Principal UI/UX Engineer** for later pre-edit advice and independent UI/UX review. Use that supported role; invent no slug or private design-system dependency. The current 17 children were exactly 16 NEW `gpt-6-sol` planners plus one NEW `gpt-6-astra`, all `fork_turns=none`. No advisory or implementation agent was dispatched in this phase.

## Phases

### Phase 1: Prior gate and complete before inputs — complete

- **Agent**: `staff-agent-orchestrator`
- **Input**: Root start; all five original 07 retrospectives, full 07 handoff, final 07 acceptance/closure and complete 08 snapshots.
- **Activity**: Full-read originals/handoff; verify root closure at 7/50, old conductor/retrospective completion and available planning slots. Verify 1002 actual copies and 22 prior fingerprints; expected current board/ledger differences are root metadata.
- **Deliverable**: `tmp/enhancement-program/08/conductor08-complete-gate-audit.json`; preserved `source-before-complete.json` and `input-manifest-complete.json`.
- **Done when**: 1002/1002 copies and 22/22 inputs verified with no product mismatch, before scope selection.
- **Handoff to**: Phase 2 (`staff-tech-lead` with 16 Sol planners).
- **Estimated effort**: 0.2 person-hours.

### Phase 2: Independent proposals, Astra decision and original barrier — complete

- **Agent**: 16 new independent Sol instances of the mapped roles; one new Astra `staff-tech-lead`.
- **Input**: Exact owned tasks under `tmp/enhancement-program/08/conductor-tasks/`, prior originals/handoff and current local code.
- **Activity**: Each original writes a frozen proposal of at most 350 words and remains running after READY. Astra full-reads/dispositions all 16 and selects one benefit without voting. Conductor captures all 16 originals simultaneously running after Astra review and before any release, then releases them and verifies completion.
- **Deliverable**: 16 distinct `planning/*.md`, [decision.md](decision.md), `conductor08-all16-ready.json`, `conductor08-final-running-barrier.json` and `conductor08-originals-completed.json`.
- **Done when**: All 16 original reports are read/dispositioned and unchanged; actual final running snapshot is retained; all 16 originals are actually completed, with no replacement/reactivation.
- **Handoff to**: Root interface, Phase 3. Stop before further dispatch.
- **Estimated effort**: 3.0 aggregate person-hours.

### Phase 3: Root acceptance and pre-edit advice — pending root

- **Agent**: Root `staff-agent-orchestrator`; fresh Guardrail Agent or `principal-security-auditor`, `staff-tech-lead` impediment adviser and actual Principal UI/UX Engineer.
- **Input**: Root full-read/acceptance of final ADR, exact ownership and acceptance criteria.
- **Activity**: Review trusted name-detail classification, bounded ephemeral draft/reset and fixed safe copy. Resolve the smallest existing reset/focus seam, field association and native evidence matrix. Keep one benefit and existing authorization.
- **Deliverable**: `review/guardrail-brief.md`, `review/impediments.md`, `review/uiux-brief.md`; root-accepted implementation contract.
- **Done when**: Concrete pre-edit findings are resolved with explicit owners. Routine authorized work acquires no new permission gate.
- **Handoff to**: Phase 4 (`principal-elixir-engineer` authors and root).
- **Estimated effort**: 0.6 aggregate person-hours.

### Phase 4: Package-name recovery and serial verification — pending root

- **Agent**: Two distinct `principal-elixir-engineer` authors and root; at most three distinct product authors across the iteration, including corrections.
- **Input**: Accepted ADR/advice, disjoint ownership and root's serial execution window.
- **Activity**: A owns `lib/harness_forge_web/live/portal_live.ex` and optional new `lib/harness_forge_web/package_build.ex`; B owns new `test/harness_forge_web/package_build_test.exs`; root owns a bounded `assets/js/app.js` change only if needed. Preserve compiler/schema/domain authority and existing connector remedies. Refusal retains a bounded draft, identifies name-only errors with fixed correction, focuses the field/correction, creates no artifact/audit build event and allows an explicit valid retry. Mixed/unknown faults receive safe generic build guidance; reset/revocation/stale events cannot revive draft or focus.
- **Deliverable**: Working selected UI benefit and focused regressions; fresh source-bound root command/native evidence under `tmp/enhancement-program/08/`.
- **Done when**: ADR positive/negative/edge criteria pass through actual build/refusal/retry, keyboard focus and 320/390 CSS widths at actual 100/200% zoom; no unmeasured human claim is promoted.
- **Handoff to**: Phase 5 (`principal-code-reviewer`, independent QA and actual Principal UI/UX Engineer).
- **Estimated effort**: 2.0–4.0 aggregate person-hours.

### Phase 5: Independent review and accepted evidence — pending root

- **Agent**: `principal-code-reviewer`, independent `principal-qa-web-playwright`, actual Principal UI/UX Engineer and `staff-qa-lead`; scoped `principal-security-auditor`/`principal-qa-api-curl` if required by the accepted contract.
- **Input**: Final source, exact acceptance contract, root's real command/native evidence and retained failures.
- **Activity**: Review correctness, no-publication/privacy oracles and actual keyboard/zoom observations. Root alone runs focused/affected tests, canonical `mix test`, warning-gated compile, existing CI Credo scope and formatting. Historical 07 Docker evidence may be reused only with explicit unchanged dependency hashes and an accurate reuse label. Findings return to original owners; cap review at three rounds.
- **Deliverable**: Independent review verdicts, exact source/evidence binding and accepted manifest.
- **Done when**: Selected behavior and regressions pass, material findings are resolved and limitations are explicit. No fresh 08 Docker, company qualification or full-WCAG claim comes from reuse or pixels.
- **Handoff to**: Phase 6 (five new independent retrospective instances).
- **Estimated effort**: 1.0–2.0 aggregate person-hours.

### Phase 6: Five retrospectives and next handoff — pending root

- **Agent**: Five new independent instances from `staff-product-owner`, `staff-tech-lead`, `principal-security-auditor`, `principal-qa-web-playwright` and `staff-qa-lead`.
- **Input**: Identical accepted evidence manifest and separate report paths; no peer retrospective reading before original verdicts.
- **Activity**: Assess complete-company usefulness/reliability and missing evidence; preserve disagreement. Root full-reads all five originals and handoff and alone records actual closure/count.
- **Deliverable**: Five `retro/*.md`, `handoff-to-09.md` and root's result.
- **Done when**: Original reports and handoff are accepted by root; planning alone never counts as an enhancement.
- **Handoff to**: Root's next-iteration gate; no 09 scope is selected here.
- **Estimated effort**: 1.0 aggregate person-hours.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
|1|`staff-agent-orchestrator`|0.2h|
|2|16 Sol planners + Astra `staff-tech-lead`|3.0h|
|3|Root + three advisories|0.6h|
|4|Two bounded authors + root|2.0–4.0h|
|5|Independent reviewers|1.0–2.0h|
|6|Five independent retrospectives|1.0h|
|**Total**||**7.8–10.8 aggregate person-hours**|

Planning barrier: `tmp/enhancement-program/08/conductor08-final-running-barrier.json`, SHA256 `cee05a2270feca79a2fe5dc984ffc7cd8e170b1c71cb2b17e829e938423c8826`. Original completion receipt: `tmp/enhancement-program/08/conductor08-originals-completed.json`, SHA256 `7a301d6f3350293077e8e09831ddb153505a2d3accd550cebdda29e657b8b94d`. The complete filtered live response was captured after Astra dispositioned all 16 and before any release; later actual statuses and final notifications confirmed completion.

## Risks + mitigations

- **Risk**: Proposal counts replace judgment → **Mitigation**: Individual dispositions preserve dissent; choose by current code, value, reliability and minimality. Goals-to-Evidence continuation retains broader potential reach; own-MCP handoff and terminal-Cancel focus remain separate proposals.
- **Risk**: Concurrency is overstated → **Mitigation**: Retain original IDs/model requests, actual full final running snapshot and later actual completion evidence; zero replacements/reactivations.
- **Risk**: Retained input or stale focus survives reset → **Mitigation**: Explicit bounded draft, reset/revocation/generation oracles and pre-edit security/UI advice.
- **Risk**: Validator vocabulary changes → **Mitigation**: Bind classification to actual typed validator output and default safely for mixed/unknown details; never print raw details.
- **Risk**: Scope or execution conflicts → **Mitigation**: One benefit, at most three distinct product authors, disjoint ownership and root-only commands/native/shared integration. Root records a bounded ownership amendment before any additional file.
- **Risk**: Technical fit is overstated as human comprehension → **Mitigation**: Report measured keyboard/zoom behavior and retain unperformed study limits. Company/model, connector/runtime/portable-authority, fresh MCP SDK and longitudinal gaps remain unproven.

## Escalation path

- If an API/scope conflict, runtime-authority issue or third review round stalls → escalate to root and `staff-tech-lead` with exact source finding, owner, failed evidence and smallest correction or revised contract. Preserve failed attempts and do not repeat unchanged routine authorization requests.

## How to execute

Final ADR: `decision.md`, 28,974 bytes, SHA256 `fc4781732ee173fb489ffbb30ad2e9138d7f8b80bc582de1cbce4e0696cd9b9f`. Conductor fully read its final bytes. Root must full-read/accept that ADR and this coordination plan before the next phase. This conductor stops at that interface; no advisory or author has been dispatched. Root remains sole board/state/runtime/shared-integration writer and sole Mix/build/Docker/native/browser/HTTP/DB/process operator. Preserve others' edits, standalone OSS boundaries and imported-content-as-data treatment; no private imports, paid calls, external publication or generated-harness host execution.

For each later phase, invoke the supported agent through the agents-ui Chat tab or, where applicable, CLI:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "Read the root-accepted HarnessForge 08 ADR, owned files and evidence contract; execute only your assigned phase."
```

No production work is in scope; `principal-devops-sre` is required if that scope later changes. Main 07 and historical 01 MCP are preserved observations, not authority to operate. Programme progress remains 7/50.
