# Iteration 01: provisional functionality decision

Status: **draft; not approved for implementation**. The decision maker must consume
all 16 independent planner reports before replacing this recommendation with a
final decision. This document is a scope proposal, not completed functionality or
test evidence. Decision role: `/root/i01_decision_astra`.

## Outcome under consideration

Give a local coding-agent client a bounded, read-only MCP interface to discover
company repositories and retrieve a currently eligible reviewed harness package.
The user benefit is concrete: an agent can find the existing implementation owner
and obtain the exact reviewed instructions without the operator copying portal
content into a chat. The first slice should expose useful trusted data, rather
than merely return a successful protocol handshake.

This is provisionally the strongest candidate because the program explicitly
requires HarnessForge's own MCP server, the application already has reusable
catalogue and package admission logic, and no product MCP server exists in the
inspected `lib/`, `config/`, CLI or router. It remains subject to the 16 reports.

## Evidence frozen before scoring

| Observation | Code or document evidence | Implication |
| --- | --- | --- |
| Company catalogue and lexical reuse discovery already work | `lib/harness_forge/company.ex:34`, `:47`, `:65` | Wrap these APIs; do not create a second catalogue or search engine. |
| Plan approval is exact and separate from compilation | `company.ex:111`, `:139`; `harnesses.ex:10` | MCP must not infer or grant approval. |
| Artifact reads verify stored bytes but do not alone establish present authority | `artifacts.ex:30`; `harnesses.ex:118`, `:133` | Retrieval must compose integrity verification with current eligibility, including plan bindings. |
| Current claim admission revalidates citations | `evidence.ex:344` | Do not expose all claim rows as approved guidance. |
| Workspace process takes an exclusive SQLite ownership lock | `workspaces.ex:44`; `bin/harnessforge`; README quickstart | A second stdio process cannot open a workspace already owned by the portal. This is a product limitation, not a reason to bypass the lock. |
| HTTP entry points have strict Host/Origin and operator session protection | `harness_forge_web/plugs/local_origin.ex`; `plugs/operator_session.ex`; `router.ex` | Any HTTP MCP path needs explicit authentication and origin integration; do not weaken the browser guard globally. |
| Privacy reconciliation fences workflows, restore withdraws prior authority | `privacy.ex`; `privacy/purge.ex`; `AGENTS.md` | Reads must respect readiness, quarantine and purge; no stale response cache. |
| Managed execution and real-model qualification remain unavailable | `docs/company-builder-verification.md` | MCP must not imply that package access makes runtime qualification available. |
| Baseline is recorded, not rerun by this decision role | same verification document | 370 registered, 355 passed, zero failed, 15 Docker skips; two existing Dialyzer diagnostics. New checks still required. |

Only reads were performed for this draft. No product edit, test, credential read,
private import, model call, or service startup was performed by the decision role.

## Selection rubric

Apply hard gates first. A candidate is ineligible if it requires private/paid
externals, executes generated code on the host, bypasses approval/consent/purge,
depends on unavailable runtime isolation, or yields no working user benefit.
Do not select by planner vote count; select by supported evidence and this rubric.

Score each dimension 0–5, then sum `weight × score / 5`:

| Dimension | Weight | A score of 5 means |
| --- | ---: | --- |
| Immediate company-harness usefulness | 30 | Removes an observed end-to-end user obstacle with a repeatable acceptance journey. |
| Trust and reliability | 25 | Reuses exact authority gates and covers refusal, revocation and malformed input behavior. |
| Feasibility in one bounded iteration | 20 | Fits three or fewer author lanes, no unavailable dependency, a small explicit contract. |
| Simplicity and reuse | 15 | Wraps existing domain functions with minimal new state and no duplicate policy engine. |
| Verification strength | 10 | Can be proved through a real local client/transport and synthetic fixtures. |

Provisional scoring, before planner evidence:

| Candidate | Usefulness | Reliability | Feasibility | Reuse | Verification | Weighted total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Read-only company + eligible-package MCP vertical slice | 5 | 4 | 4 | 5 | 5 | 91 |
| Structured plan-readiness explanation | 4 | 5 | 5 | 5 | 5 | 94 |
| Portable complete company-plan provenance | 4 | 4 | 4 | 4 | 5 | 82 |
| Managed coding execution | 5 | 1 | 1 | 2 | 1 | 46; hard-gate fail while isolation/model unavailable |

The scores alone currently favor readiness explanation. MCP is the provisional
recommendation because it satisfies a named program requirement and opens a new
usable integration boundary; the final decision must state this priority tradeoff
explicitly, and must revise scores if planner evidence shows the MCP slice is too
large or cannot be exercised with a real client. A handshake-only MCP result does
not qualify and should lose to readiness explanation.

## Proposed smallest useful contract

1. A real local MCP launch/connect path with documented supported protocol revision.
2. A finite tool catalogue: search company capabilities, get declared consumers,
   list project/repository metadata, and list/read eligible package context. Final
   naming and count belong in the final decision; keep the catalogue small.
3. Inputs are strict string-keyed objects with unknown-key rejection, bounded IDs,
   query lengths, result counts and response bytes. No caller-supplied workspace,
   filesystem root, module, command, provider endpoint or credential reference.
4. Catalogue fields are explicitly operator-authored data. A package response
   identifies digest, runtime, review provenance and capability/qualification limits.
   Fetch full content only by exact digest and permitted manifest entry if needed;
   do not add arbitrary file access. Eligible selection and reads recheck authority.
5. No tools approve claims/plans/releases, import sources, configure models, run
   code, perform exports, or mutate provider accounts. This keeps the first surface
   useful and bounded; later mutation proposals need their own authority contract.
6. Readiness checks and the existing purge synchronization must prevent requests
   from returning revoked/quarantined content. No new durable MCP cache.

### Transport decision remains open

| Option | Benefit | Cost / limitation | Draft preference |
| --- | --- | --- | --- |
| Stdio process owning the workspace | Reuses offline CLI lifecycle; no new network authentication surface | Portal must be stopped; startup logs must never corrupt stdout; actual packaged launcher needs proof | Smallest fallback if HTTP security cannot stay bounded |
| MCP endpoint in existing Phoenix process | Works while the portal owns the workspace; no second database owner | Narrow origin handling, bounded parser, explicit local authentication and security review needed | Preferred user experience if planner evidence supports a small implementation |
| Stdio proxy to authenticated local endpoint | Familiar client launch while sharing workspace ownership | Two transports/configuration surfaces and extra failure modes | Defer unless an existing tested building block makes it smaller |

No new listener bound to remote interfaces, remote hosting, OAuth service,
workspace-lock bypass, or alternate database ownership scheme is in this slice.
The root must own router/application/configuration integration as required by
`AGENTS.md`; an author must not silently broaden its assigned files.

### Protocol evidence requiring explicit choice

Official documentation read on 1 November 2026 describes `2026-07-28` as modern:
per-request version metadata and `server/discover`, with no initialization
handshake. It describes `2025-11-25` and earlier as legacy handshake versions.
Sources: [versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
and [transport overview](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports).

The implementation must name the selected profile and validate it against an
available client. A deliberate `2025-11-25` compatibility baseline can be a useful
bounded delivery, but cannot claim current-protocol compliance or compatibility
with untested clients. Do not mix modern metadata rules with legacy initialization
semantics accidentally. Avoid adding dual-era complexity without demonstrated need.

## Acceptance evidence required before counting this iteration

- A synthetic company with at least two repositories, declared dependency and an
  approved exact plan produces a verified package through existing domain APIs.
- A real client process/HTTP exchange discovers tools, searches a capability,
  resolves its consumer and retrieves the eligible exact package context.
- Proposed/rejected/stale plan or claim content cannot appear as approved package
  context; withdrawal/purge/restore quarantine after an earlier successful read
  causes the next read to fail or exclude the result.
- Unknown methods/tools, malformed arguments, foreign IDs, path-like input,
  oversized requests/responses and unsupported versions fail without crashing.
- Stdio proves clean stdout and ownership refusal; HTTP instead proves unauthenticated
  rejection, hostile Host/Origin rejection and unaffected browser security tests.
- Independent review verifies there is no approval, export, model call, remote
  query or execution reachable through the finite tool dispatch.
- Root records actual command, exit status, client version, exact supported MCP
  profile and sanitized transcript in `tmp/enhancement-program/01/`. Run focused
  tests, `mix test`, warning-gated compile and format. Existing skips/diagnostics
  stay distinct from new failures. No live model-quality inference from fixtures.
- Five independent retrospectives answer the program's company-usefulness and
  reliability questions and hand ranked gaps to iteration 02 before completion.

## Decision completion checklist

- [ ] All 16 planner paths present and read; no absent report inferred.
- [ ] Each report has an explicit accepted, deferred or rejected disposition with reason.
- [ ] Final weighted scores and hard-gate results reflect their evidence.
- [ ] Transport and protocol profile selected with a real validation route.
- [ ] Guardrail and impediment roles have concrete scope and blocking conditions.
- [ ] Root receives final scope, ownership, acceptance checks and next-iteration handoff.

# Coordination Plan: Iteration 01 trusted company-context MCP (provisional)

**Classification**: implementation
**Pattern**: composed: map-reduce + sequential + review-loop
**Total agents involved**: 6 execution specialties below; the program's 16 planners,
Astra decision role, root, required guardrail/impediment/UX roles and five retros
are coordinated by root and are not dispatched by this document.

## Agents involved (in order of first involvement)

| # | Agent | Role in this plan | Why this agent (cite the capability map) |
| --- | --- | --- | --- |
| 1 | `staff-tech-lead` | Freeze contract and resolve impediments | Fleet Capability Map: architecture/ADR/RFC capability index; technical risk and cross-repo planning specialty. |
| 2 | `principal-security-auditor` | Guardrail review of new agent access surface | Capability index: security/OWASP/secrets; security review required for new endpoints. |
| 3 | `principal-elixir-engineer` | Protocol and domain adapter implementation | Capability index: Elixir/Phoenix; OTP supervision, Phoenix and Ecto specialty. |
| 4 | `principal-qa-api-curl` | Independent transport acceptance | Capability index: API contract testing; curl/HTTPie smoke and contract testing specialty. |
| 5 | `principal-code-reviewer` | Review loop and authority-boundary verification | Capability index: code review/PR; correctness, security, tests and observability quality bar. |
| 6 | `staff-documentation-writer` | Exact local setup and compatibility limits | Capability index: documentation/README/ADR; runbooks and information architecture specialty. |

Capability source: [Fleet Capability Map](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md).
The map names the Elixir role `principal-elixir-engineer`; root should map it to
the available Principal Elixir / OTP Engineer role without inventing a new agent.
No production work is proposed, so deployment staffing is outside this scope.

## Phases

### Phase 1: Decide and bound access
- **Agent**: `staff-tech-lead`
- **Input**: All 16 plans, this draft, root guardrail and expert UX input.
- **Activity**: Finalize transport, version, finite tools, response fields and ownership; resolve security comments before coding.
- **Deliverable**: `docs/enhancement-program/iterations/01/decision.md` and guardrail verdict.
- **Done when**: All 16 reports have dispositions and no authority or protocol blocker remains.
- **Handoff to**: Phase 2, `principal-elixir-engineer`.
- **Estimated effort**: 1–2 person-hours, including `principal-security-auditor` consultation.

### Phase 2: Implement the useful read path
- **Agent**: `principal-elixir-engineer`
- **Input**: Frozen contract and explicit module ownership from root.
- **Activity**: Implement bounded transport/dispatch and reuse existing company/package admission functions; root integrates shared entry points. At most three author lanes.
- **Deliverable**: Product changes plus focused regression tests; file list recorded by root.
- **Done when**: Synthetic search-to-eligible-package journey passes locally with transport evidence.
- **Handoff to**: Phase 3, `principal-qa-api-curl` and `principal-code-reviewer`.
- **Estimated effort**: 5–9 person-hours.

### Phase 3: Independent verification and review loop
- **Agent**: `principal-qa-api-curl`
- **Input**: Implemented diff, supported profile, synthetic setup and negative-case matrix.
- **Activity**: Exercise the real transport; `principal-code-reviewer` independently checks authority and boundedness; author fixes verified findings. Security reviewer checks any new HTTP access path.
- **Deliverable**: `tmp/enhancement-program/01/` sanitized command/transcript evidence and written review verdicts.
- **Done when**: Required acceptance and regression checks pass; explicit approve verdict with no unresolved blocking finding.
- **Handoff to**: Phase 4, `staff-documentation-writer`, then root's five independent retros.
- **Estimated effort**: 3–5 person-hours.

### Phase 4: Document observed behavior and hand off
- **Agent**: `staff-documentation-writer`
- **Input**: Verified commands, client/profile versions, limitation and review records.
- **Activity**: Publish local setup instructions within the repository and clearly separate supported operations from unavailable qualification.
- **Deliverable**: `docs/mcp.md` and iteration verification/handoff references, paths finalized by root.
- **Done when**: Instructions reproduce the actual tested local journey and all five retrospective inputs are available to root.
- **Handoff to**: Root for completion ledger and iteration 02 UI/UX scope.
- **Estimated effort**: 1–2 person-hours.

## Effort summary

| Phase | Agent | Effort |
| --- | --- | --- |
| 1 | `staff-tech-lead` + `principal-security-auditor` | 1–2 h |
| 2 | `principal-elixir-engineer` | 5–9 h |
| 3 | `principal-qa-api-curl` + `principal-code-reviewer` | 3–5 h |
| 4 | `staff-documentation-writer` | 1–2 h |
| **Total** | | **10–18 h**, rough human-equivalent execution estimate; excludes root-managed planning/retros |

## Risks + mitigations

- **Risk**: MCP work expands into a generic remote control API → **Mitigation**: finite read-only operations and explicit forbidden capabilities; reject generic dispatch.
- **Risk**: Previously eligible content escapes after revocation → **Mitigation**: fresh eligibility admission under the existing privacy fence and revocation-after-read tests.
- **Risk**: Transport works in unit tests but fails in the native app → **Mitigation**: real launcher or real HTTP client acceptance; preserve exact profile/client evidence.
- **Risk**: Offline stdio feels broken while portal runs → **Mitigation**: either choose same-process HTTP or explicitly prove/document ownership refusal; never bypass the lock.
- **Risk**: Current MCP rules differ from familiar legacy rules → **Mitigation**: pin one supported version and verify against its official specification and real client.

## Escalation path

- If protocol/client or local authentication design cannot be bounded → escalate to `staff-tech-lead` with the failing exchange, required profile and two transport alternatives; return to scope selection rather than count a stub.
- If review remains blocked after three author/reviewer rounds → escalate to `staff-tech-lead` with diff, failure evidence and remaining finding; root records the unresolved state.

## How to execute

Root should use the program's already authorized agent mechanism and preserve its
model requirements. For manual execution, select the named role in agents-ui, or:

```bash
./bin/Codex -p --append-system-prompt-file ~/.Codex/agents/<slug>.md \
  "Read the finalized iteration 01 decision and assigned ownership; produce the named phase artifact. Preserve AGENTS.md and other authors' edits."
```

This draft does not dispatch agents and does not authorize implementation before
the 16-report decision gate.
