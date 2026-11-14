# Coordination Plan: Codex, Claude Code and model API integrations

**Pattern**: composed parallel-fan-out → root integration → independent review-loop (maximum three rounds).

**Agents involved**:
- `coding_connectors_guardrail`: request-scoped runtime and API briefs, finished.
- `codex_adapter`: Codex renderer/tests/doc only.
- `claude_adapter`: Claude Code renderer/tests/doc only.
- `cloud_model_connectors`: OpenAI Responses/Anthropic adapters, configuration, dispatch, ledger classification and tests/docs.
- `root`: shared registry/compiler/Harnesses/evaluations, UI/CLI, local board, isolated CLI checks, native packaging.
- Independent reviewer: read-only cross-boundary review after handoffs.

## Phases

### Phase 1: Contract and provider authors
- **Agent**: three bounded implementation lanes above.
- **Input**: existing RuntimeAdapter and Models contracts, AGENTS.md, current official API/native documentation.
- **Activity**: deterministic native packages; explicit source-scoped cloud APIs with no paid live calls.
- **Deliverable**: adapters/codex.ex, adapters/claude_code.ex; models/openai_responses.ex and models/anthropic.ex; per-lane tests/docs and precise handoffs.
- **Done when**: owned tests pass, unsafe/unsupported settings fail closed, evidence/consent authority preserved.
- **Handoff to**: Phase 2 (`root`).

### Phase 2: Shared application integration
- **Agent**: `root`, sole progress-board writer.
- **Input**: frozen native paths/identities and model configuration interface.
- **Activity**: target dispatch plus manifest identity; target-aware evaluation guards; provider/target setup in UI/CLI; cross-provider tests and actual installed CLI/offline native-format checks.
- **Deliverable**: selectable native exports and API configuration, real test/probe logs, updated local board.
- **Done when**: all interfaces usable, old OpenCode/source connectors remain passing, no unsupported target can inherit OpenCode qualification.
- **Handoff to**: Phase 3 (independent reviewer, then root).

### Phase 3: Review and native qualification
- **Agent**: independent reviewer (read only), root fixes/verification.
- **Input**: integrated frozen tree and actual test outputs.
- **Activity**: review artifact identity, native escaping, consent/ledger/usage; final suite, compiler/formatter/lint and native app/browser checks.
- **Deliverable**: review closure, current native package, evidence record with precise observed limits.
- **Done when**: confirmed findings resolved; tests observed; live authenticated model calls and model-backed coding remain explicit when unavailable.
- **Handoff to**: operator for separately configured API/model authorization and future managed-target qualification.

## Estimated effort
- Provider lanes: 0.5–1 person-hour each, parallel.
- Shared integration and isolated CLI checks: 1–2 person-hours.
- Review/package/QA: 0.5–1 person-hour.
- Total: 3–6 person-hours; wall time benefits from parallel authors.

## Risks
- Native format drift: pin installed versions and current official references, perform genuine consumption checks where supported.
- Unsupported execution target: fail closed, never run host-generated code or stamp OpenCode identity.
- API accounting: conservative cache/reasoning token handling and unknown-outcome reservations.
- Secret/egress authority: environment references, fixed origins, exact provider/source/category consent; no browser/CLI credential borrowing or paid calls.

## Escalation path
- Confirmed code/test failure → owning author/root, smallest fix, independent re-review, maximum three rounds.
- Missing model/API authorization/isolation → operator-facing explicit limit while completing independent work; no repeated approval requests.
- Workers are not alone; preserve others' edits, no child agents, root owns shared files/board. Never repurpose HOME/home/CODEX_HOME variables. No publication or remote mutations.
