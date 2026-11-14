# Coordination Plan: HarnessForge iteration06 export recovery

**Classification**: implementation
**Pattern**: composed: map-reduce + sequential + review-loop
**Total agents involved**: approximately32–34 including root/conductor; at most21 active, planning19. Actual dispatch records, not estimates, establish participation.

## Agents involved (in order of first involvement)

Capability citations refer to the existing [fleet capability map](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md). Slugs below are complete existing map identifiers; dispatch uses exact supported runtime role labels. This standalone repository requires no private atlas or build-orchestrator-v2 protocol.

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
|---|---|---|---|
|1|`staff-agent-orchestrator`|Root and fresh conductor|Map line458: phase design, bounded handoffs, active slots; root alone writes board/state/results and operates native app|
|2|`staff-tech-lead`|One new Astra decision maker; later new impediment advisor|Map line415: ADR, blast radius, estimates and technical risk|
|3|`staff-product-owner`|Original Sol01/02 planning|Map product strategy: operator jobs and falsifiable acceptance|
|4|`principal-elixir-engineer`|Original Sol03/04/09/14; sole delegated product author|Map line172: Phoenix/LiveView, Elixir contexts, Ecto/OTP; fits existing implementation without stack rewrite|
|5|`principal-qa-web-playwright`|Original Sol05/16; later independent web evidence review|Map line720: real browser behavior, keyboard locators and visual verification; root performs native operations|
|6|`principal-security-auditor`|Original Sol06/12; independent trust/privacy review|Map line350: access control, sensitive data, integrity and failure boundaries|
|7|`staff-documentation-writer`|Original Sol07/13|Map line363: information architecture, precise operator guidance and error language|
|8|`principal-frontend-perf-engineer`|Original Sol08|Map web-engineering: layout, interaction and browser evidence boundaries|
|9|`staff-qa-lead`|Original Sol10; independent regression/evidence coordinator|Map line734: meaningful gates, test accounting and limitations|
|10|`principal-qa-api-curl`|Original Sol11; optional targeted contract reviewer|Map QA API: actual negative/error contracts, useful despite no HTTP API change|
|11|`principal-code-reviewer`|Original Sol15; new independent final code review|Map line331: correctness, security, tests and maintainability|

The registry exposes exact **Principal UI/UX Engineer** and **Guardrail Agent** roles. The older map omits the former; [conductor.md](../../conductor.md) records the supported-role resolution. Conductor/root must dispatch a new actual Principal UI/UX Engineer advisory session after the16-original final-review barrier, plus new guardrail and impediment reviewers before product edits. No invented slug or additional user approval is needed. Advisory/report-only agents are not product authors. Astra dispatches no author/advisor.

## Phases

### Phase 1: Prior evidence and sixteen original proposals
- **Agent**: Root/conductor;16 new `gpt-6-sol`, `fork_turns:none` planners with distinct lenses.
- **Input**: PROGRAM/conductor/state; all five original05 retrospectives and full handoff/verification;03 accepted amendment;06 manifest and actual current code.
- **Activity**: Independent≤350-word original reports; keep original sessions active for Astra questions. Root/conductor validate provenance; preserve dissent rather than count recommendations.
- **Deliverable**: `planning/01..16-*.md`, SSD `planning-concurrency.json` and `planning-reports.json`.
- **Done when**: All16 ready and actual new list_agents observation shows every original running. Observed18:02:30.222785 UTC, zero reactivation/replacement; model provenance comes from actual spawn calls.
- **Handoff to**: New Astra final review.
- **Estimated effort**: 2.0 aggregate person-hours.

### Phase 2: Decision and root interface
- **Agent**: `staff-tech-lead`, one new `gpt-6-astra`.
- **Input**: Every finalized original proposal, all five prior original reports, current source, final-review barrier evidence.
- **Activity**: Select one bounded export-recovery benefit by evidence/value/reliability/simplicity; disposition16 reports and05 dissent; define exact positive/negative/edge acceptance and disjoint ownership. Preserve post-freeze planner11/16 corrections in decision without rewriting originals.
- **Deliverable**: [decision.md](decision.md), this coordination plan.
- **Done when**: Astra reports final-review complete; conductor releases all16 originals; root reviews concrete decision. No product author starts during planning barrier.
- **Handoff to**: Root scheduling interface; **stop before implementation author dispatch**.
- **Estimated effort**: 0.75 aggregate person-hours.

### Phase 3: Pre-edit advice and focused implementation
- **Agent**: New Guardrail Agent, new `staff-tech-lead` impediment reviewer, actual Principal UI/UX Engineer; then one Principal Elixir / OTP Engineer and root.
- **Input**: Root-reviewed ADR06, original/current source, exact ownership, source-before snapshot and root's serialized Mix window.
- **Activity**: Written guardrail/impediment/UX briefs precede product edits. Resolve local result placement, conservative failure copy, focus and private input reset. Author A owns Portal, optional small presentation helper and dedicated web tests/necessary existing assertion updates. Root owns only required shared JS/CSS and all config/router/application/migration/native/build/browser/board/state/result responsibilities. No domain/export/approval/notice-framework change. Preserve peer edits.
- **Deliverable**: One working failed→corrected export journey, exact package-owned outcome and focused lifecycle tests; implementation notes.
- **Done when**: Author checks satisfy ADR; no unresolved ownership or contract ambiguity; source ready to freeze. Two product authors total including root planned; maximum three total, never three delegates plus root.
- **Handoff to**: Independent reviewers/QA.
- **Estimated effort**: 2–4 aggregate person-hours. Split state/error/reset and rendering/focus into review units ideally≤400 net production lines each.

### Phase 4: Independent review and native evidence
- **Agent**: New Principal Code Reviewer, Principal Security Auditor, Staff QA Lead or appropriate backend QA, Principal Web QA (Playwright), Principal UI/UX Engineer; root operates native candidate.
- **Input**: Frozen source, ADR acceptance matrix, author evidence, before snapshot and source/build/runtime identity.
- **Activity**: Independent code/security/UX review; root-scheduled single Mix window for focused/canonical/static checks. Record exact commands/exits, baseline Dialyzer two opacity diagnostics and distinct test accounting. Reuse existing no-overwrite, approval/privacy/quarantine/MCP/readiness regression coverage with explicit scope. Root-native occupied→fresh retry, A/B identity, prior build failure, unsafe path, focused unsent reset, stale submission, lock/remount, keyboard and320/390/real200% checks; compare file hashes. Do not claim errno diagnosis from broad I/O. Verify ordinary viewport images, asset/source provenance and observed limitations. Same author corrects findings; freeze corrected candidate before renewed verdict.
- **Deliverable**: `review/guardrail-brief.md`, `review/impediments.md`, `review/ux-design.md`, `review/code-review.md`, `review/security-review.md`, `review/regression-validation.md`, `review/web-validation.md`, `review/ux-validation.md`; SSD exact logs/hashes/native manifest; root accepted evidence.
- **Done when**: Selected behavior and regressions pass on accepted bytes, material findings resolved and failed/inconclusive attempts retained. Unknown completion is honestly presented; no speech/comprehension/WCAG/company qualification claim.
- **Handoff to**: Root-controlled five independent retrospectives only after acceptance evidence exists.
- **Estimated effort**: 2–4 aggregate person-hours plus root native scheduling.

### Phase 5: Independent retrospective and closure
- **Agent**: Five new independent product, UX, architecture, trust/privacy and quality instances, scheduled by conductor/root after implementation verification.
- **Input**: Identical frozen accepted evidence manifest and separate sole report paths.
- **Activity**: Each answers the exact original question, “Was this tool really helpfull and reliable to build a complete harness for a company? and what is missing to make it reliable?” before seeing peer reports; cite evidence and preserve dissent. Conductor reads all originals after completion. No retrospective is dispatched by this decision maker.
- **Deliverable**: Five original reports; conductor handoff; root acceptance/state update.
- **Done when**: Root has read/accepted all five and verified a working user benefit. Planning/docs-only work does not count.
- **Handoff to**: Root closure only; next iteration is not selected or dispatched here.
- **Estimated effort**: 1 aggregate person-hour.

## Effort summary

| Phase | Agent | Effort |
|---|---|---|
|1|16 original Sol planners/conductor|2h|
|2|Astra Staff Tech Lead|0.75h|
|3|One principal author, root, pre-edit advisors|2–4h|
|4|Independent reviews/QA and root-native evidence|2–4h|
|5|Five fresh retrospective instances|1h|
|**Total**|All phases|**7.75–11.75 aggregate person-hours**|

These are task-effort estimates, not elapsed-time or success promises. The limited two-author plan follows Portal's single-file coupling; extra parallel product editors would increase merge and lifecycle risk.

## Risks + mitigations

- **Risk**: Generic I/O/audit failure misrepresented as no export → **Mitigation**: fixed completion-unconfirmed copy and destination inspection; audit follows publication, no guessed errno or unsafe automatic retry.
- **Risk**: Old result/draft appears for another package or after reset → **Mitigation**: full-digest active state, generation checked before export, keyed DOM clearing, actual A/B/reset/stale-event tests.
- **Risk**: Export success conceals unrelated failure → **Mitigation**: local export outcome, no blanket flash clearing, direct Package build prefix only; defer broader notice ownership.
- **Risk**: Focus fix accepts arbitrary selectors or breaks keyboard → **Mitigation**: fixed-purpose validated targets and actual active-element/next-Tab checks; root owns shared JS.
- **Risk**: Styling work expands beyond selected task → **Mitigation**: measure changed Packages surface first, root-owned bounded CSS only if necessary for acceptance.
- **Risk**: Old QA or skipped tests become claimed fresh passes → **Mitigation**: exact source/release hashes, explicit reuse versus new execution and preserved accounting/failures.
- **Risk**: UI observation becomes authority or qualification → **Mitigation**: unchanged Harnesses admission, separate exact claim/plan decisions, consent/purge/quarantine and03 command-free abstention; MCP stays read-only and unavailable execution remains visible.

## Escalation path

New persistence/domain contracts, export preflight, broad notice rewrite, dependency changes, inability to clear focused private input, or unsafe native evidence techniques go to root and Staff Tech Lead with exact file/observation, minimum correction and alternatives. After at most three review rounds, stop broadening and request one bounded retry/replan decision. Routine authorized local fixes need no repeated user approval. Keep independent work moving while a real blocker is pending; do not repeat unchanged requests.

## How to execute

Use actual supported collaboration roles and the current runtime registry. Root alone writes board/state/results and controls shared files, single Mix scheduling, source freeze, runtime identity, native build/browser and final acceptance. Conductor releases planners before authors and manages the active-slot cap. Never overwrite a running release; verify identity/workspace and coordinate before operations. Preserve historical evidence, peer edits and03 abstention. No publication, external messages, private imports, paid calls, credentials, permission expansion or generated-code host execution. This document stops at the root scheduling interface; no author, retrospective or future-cycle dispatch is performed by Astra.

The coordination template's alternative CLI invocation is documented below, not executed here. Use the actual supported collaboration dispatch for this run; the CLI form requires an existing applicable agent file and does not override phase ownership or authorization.

```sh
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md "<the input for this phase>"
```
