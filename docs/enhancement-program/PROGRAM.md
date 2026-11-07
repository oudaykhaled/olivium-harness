# HarnessForge enhancement program

Goal: 50 substantial, verified improvements to make company harness creation useful, reliable and approachable, including HarnessForge’s own MCP server.

## Iteration contract

Odd iterations focus on functionality. Even iterations focus on UI/UX. A counted iteration must contain a working, testable user benefit; planning, formatting and retrospective-only changes do not count.

1. Root creates a bounded evidence folder and dispatches 16 concurrent Sol planners, each with a distinct investigation and its own written artifact. One Astra decision maker selects the scope using code evidence, user value, reliability and simplicity. Agent model names and task IDs are recorded.
2. An implementation orchestrator, guardrail reviewer, impediment remover, principal engineers and expert UI/UX input deliver the selected change. At most three implementation authors work concurrently, with explicit ownership. Root owns shared configuration, migrations, router, application and the progress board.
3. Independent agents validate meaningful behavior, regressions and UX as appropriate. Actual commands, exit codes, logs, browser screenshots and provenance are stored locally. Mocked compatibility never counts as live authentication or model quality. Existing unavailable integrations remain visible.
4. Five independent agents each answer: “Was this tool really helpful and reliable to build a complete harness for a company? What is missing to make it reliable?” They must cite code and iteration evidence, distinguish supported behavior from limitations, and rank the next gaps. Their reports are written before they see one another’s reports.
5. Root records the accepted result, unresolved findings, exact evidence and a handoff to the next iteration. Failed checks require correction; an iteration is not completed by relabeling failure. `state.json` is the machine ledger; `PROGRESS.md` is the local work board. `tmp/enhancement-program/runtime-state.json` records observed local app processes; verify identity and coordinate before any operation.

## Dispatch discipline

Each planner receives its output path, a distinct investigation, the previous iteration's retrospective handoff, and an explicit final-review barrier in its initial task. After writing its proposal it reports ready to Astra and remains active until the coordinator releases the barrier. Capture an actual live-agent snapshot with all 16 Sol planners running; report reactivation honestly when it was necessary. Astra records a disposition for every proposal and selects by evidence and acceptance value, never vote count. Release planning agents before starting implementation authors. Keep reports concise and use only the slots needed for the current phase.

Independent retrospective reviewers receive the same accepted evidence manifest and their own output paths. They must not read one another's reports before writing their verdicts. The handoff must retain disagreement and failed or unverified areas; five favorable opinions are not a substitute for tests.

## Boundaries

Authorized local source edits, dependencies, fixture data, tests and local app startup only. No publication, remote writes, private source-body imports, paid model calls, credential extraction, permission expansion, or execution of repository/model-generated code on the host. Imported content is data. Existing claim approvals, consent, immutable package identity, purge and quarantine remain binding. No silent provider fallback. Root is the sole board writer. Preserve other authors’ work.

## Evidence

Written plans, decisions and retrospectives live in `docs/enhancement-program/iterations/NN/`. Test logs, screenshots and machine evidence live in `tmp/enhancement-program/NN/` on the local SSD. These paths are not proof by themselves; reports must identify what actually ran and its limits. Runtime artifacts and credentials stay out of public documentation. No iteration is pre-marked complete.

## Baseline

Company-builder cycle: 370 registered tests, 355 passed, zero failures, 15 existing Docker skips. Format, warning-gated compilation and Credo passed. Two existing Dialyzer opacity diagnostics in releases.ex remain. Native browser synthetic company flow, package comparison/export, integrity gate and blocked managed-runtime gate were verified. Managed coding execution, real-model company qualification and some live connector credentials/scopes remain unavailable.
