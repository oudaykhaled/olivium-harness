# Coordination Plan: chatbot across connectors

**Pattern**: bounded parallel-fan-out → root integration → independent review-loop (maximum three rounds).

**Agents involved**:
- `chat_guardrail`, `chat_model_scout`, `chat_evidence_scout`: finished read-only contract analysis.
- `chat_models`: shared inference profiles and provider regression tests.
- `chat_backend`: bounded retrieval, cited answers, connector inventory and backend tests.
- `root`: authenticated UI, consent controls, local board, package and browser checks.
- `chat_review`: independent read-only review after integration.

## Phases

### Phase 1: contracts and implementation
- **Agent**: two bounded authors plus root UI lane.
- **Input**: existing evidence, Models.infer, ledger, consent and privacy contracts.
- **Activity**: read-only ephemeral chat with local search and optional model synthesis; all six source providers, four model providers and runtime-target status.
- **Deliverable**: Chat context, compiled inference profiles, UI and automated checks.
- **Done when**: cited current sources, bounded history, exact consent, safe unavailable states; no remote writes/approval/code execution.
- **Handoff to**: root integration, then reviewer.

### Phase 2: integrated review and verification
- **Agent**: root and independent reviewer.
- **Input**: frozen author handoffs and observed checks.
- **Activity**: regression suite, privacy/revocation and no-egress tests, real local browser submission, native packaging.
- **Deliverable**: working local chat, evidence record and reviewed package.
- **Done when**: findings closed; fixture/native/live results distinguished; unavailable inference explicit.
- **Handoff to**: operator for separately authorized live API/model setup.

## Estimated effort
- Backend/model authors: 0.5–1.5 person-hours each.
- UI/integration/review/native checks: 1–2 person-hours.
- Total: 2–5 person-hours, authors in parallel.

## Risks
- Snapshot freshness: re-fetch source/revision eligibility before and after inference and before redisplay.
- Cloud egress: existing source consent does not cover questions/history; add explicit `chat_context` consent and retain `source_body`.
- Authority: no model tools, connector mutation, claim approval or coding-agent execution.
- Privacy: bounded browser-session transcript; no DB/Oban/audit transcript persistence; stale async results dropped.
- Model absent: local cited retrieval remains available and clearly labelled; no fabricated AI response.

## Escalation path
- Confirmed failure → owning author/root, smallest fix and independent review, maximum three rounds.
- External credentials/model unavailable → record exact limit; finish independent work without repeated permission requests.

Root is sole progress-board writer. Explicit file ownership; preserve other edits.
No child agents, publication, paid calls or host execution of generated code.
