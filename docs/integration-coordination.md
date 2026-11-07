# Coordination Plan: All five read-only integrations

**Pattern**: composed: parallel-fan-out → root integration → review-loop (maximum three rounds).

**Agents involved** (in order):
- `integration_contract_scan` — read-only contract inventory.
- `integrations_guardrail` — request-scoped trust boundaries.
- `slack_adapter`, `projects_adapter`, `confluence_adapter` — three independent provider authors.
- `root` — shared integration, sole progress-board writer, final QA/package.
- `integrations_review` — independent read-only correctness/security review.

## Phases

### Phase 1: Freeze contracts
- **Agent**: `integration_contract_scan`, then `integrations_guardrail`.
- **Input**: User's five-service scope, project AGENTS.md, existing connectors/contracts.
- **Activity**: Identify registration, credentials, scope enforcement and test boundaries.
- **Deliverable**: Agent handoff briefs, reflected in this plan and PROGRESS.md.
- **Done when**: Root accepts bounded source selections and file ownership.
- **Handoff to**: Phase 2 (three provider agents).

### Phase 2: Implement adapters in parallel
- **Agent**: `slack_adapter`, `projects_adapter`, `confluence_adapter`.
- **Input**: Frozen string-keyed page/document contracts and per-provider selections.
- **Activity**: Each owns only its connectors/<provider>.ex, corresponding connector_test.exs and provider documentation; no shared files or child agents.
- **Deliverable**: Slack messages/replies; Projects v2 fields/views/items; Confluence current pages. Exact paths/results/limits in explicit final handoff.
- **Done when**: Provider Evidence.connect/sync positive/adversarial fixtures pass; scope/pagination/errors are bounded; documents preserve provenance.
- **Handoff to**: Phase 3 (`root`).

### Phase 3: Integrate and review
- **Agent**: `root` authors; `integrations_review` independently reads/verifies.
- **Input**: Three provider handoffs and unchanged GitHub/Jira baseline.
- **Activity**: Integrate fixed GraphQL query transport, registry/second scope boundary, provider-specific portal fields, CLI, docs and cross-provider tests. Resolve reviewer findings with smallest fixes.
- **Deliverable**: lib/harness_forge/connectors/registry.ex, shared Common/Evidence/CLI/portal changes, connector_boundaries_test.exs, integration_surfaces_test.exs, docs/integrations.md.
- **Done when**: No unresolved confirmed correctness/security findings; canonical suite, formatter, warning-free compile and Credo warning gate pass.
- **Handoff to**: Phase 4 (`root`).

### Phase 4: Native/browser qualification
- **Agent**: `root`.
- **Input**: Reviewed integrated tree.
- **Activity**: Build/package, smoke CLI, restart owned loopback portal, test real browser setup and authorized public GitHub page; record external API blockers separately.
- **Deliverable**: Current native archive plus docs/verification.md, packaging/VERIFICATION.md and PROGRESS.md.
- **Done when**: Native/browser checks observed; all five automated results explicit; authenticated live unavailability never reported as pass.
- **Handoff to**: Operator for missing API credentials/resource selections and unavailable Atlassian tenant.

## Estimated effort
- Contract inventory/guardrails: 0.25 person-hours.
- Provider lanes: 0.5–1 person-hour each, parallel.
- Shared integration/review: 1 person-hour.
- Native/browser qualification: 0.5 person-hours.
- Total: 3.25–4.75 person-hours of delegated/root work; wall time benefits from parallel lanes.

## Risks
- Provider schema drift: validate official published API schema; retain fixture/live distinction.
- Partial pagination or wrong scope: validate twice, fail page atomically, explicit request budgets.
- Secrets: environment references only; no browser-cookie extraction or credential minting.
- External availability: finish implementation independently; report missing credentials and unavailable tenant honestly.

## Escalation path
- Confirmed implementation failure → original author/root, then independent re-review, maximum three rounds.
- Missing API credential/resource scope or unreachable tenant → operator; no repeated request for an unchanged blocker.
- Workers are not alone: preserve others' edits. Root alone writes PROGRESS.md. Routine authorized local fixes need no new approval. No remote writes, publication, paid calls or broad private imports.
