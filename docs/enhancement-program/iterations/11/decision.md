---
status: selected-for-root-acceptance
iteration: 11
date: 2026-11-02
decision-maker: /root/i11_conductor/i11_astra
---

# ADR11: Assess representative work against an exact company package

## Context

Select one functionality slice: **from an eligible built Company package, freeze an owner-authored representative task and obligation rubric, then record an immutable owner assessment against those exact inputs**. This extends authorised company history and future intent → explained recommendations → human edit/reject/exact Evidence approval → exact Company plan approval → deterministic package into representative work. A standalone questionnaire detached from that chain does not satisfy this decision.

All sixteen final original proposals were fully read after the conductor's FINAL ORIGINALS READY message and observed all-originals-running barrier. Each is bound below and in `tmp/enhancement-program/11/astra-read-receipt.json`; final conductor binder `tmp/enhancement-program/11/planning-final-originals.json` SHA256 `379a0e24bbde70d06445eed18dc5e57e967eac7569dfce5b036f3cc131c95fee` matches all16 unchanged firstREADY notes. Audits are not substitutes for originals. All five original10 retrospectives, complete10 handoff, outcome/program/AGENTS/conductor and forward accepted/result/root acceptance were fully read. All five09 originals and full09 handoff were also read; one truncated combined read was repaired by a complete separate read of09 quality. No vote or repetition count determined selection.

Actual frozen source establishes:

* `lib/harness_forge/company.ex:71–169,234–260,345–360,417–420` creates immutable plans, pins goal/catalogue/evidence identity, rechecks current eligibility and fences mutations. `company/validation.ex:79–94` permits empty milestone goal lists; it does not establish obligation completeness.
* `lib/harness_forge/harnesses.ex:8–89,122–200` binds an approved exact plan to verified package bytes and rechecks authority at export. `:204–275` emits goals/rules but fixes evaluation to `synthetic-go-v1`.
* `lib/harness_forge/evaluations.ex:1–16,63–95,173–189,790–805` owns trusted checks and applicability. `lib/harness_forge/releases.ex:144–149` resolves an actual evaluation row. Owner testimony cannot be admitted through these contracts.
* `lib/harness_forge/models/company_analysis.ex:54–66,129–154` explicitly separates exact quotation/two-source structure from semantic support. No receipt can establish omitted-obligation discovery or corroboration.
* `lib/harness_forge/privacy/snapshot.ex:7–8,270–350` has explicit workspace/immutable inventories and restore quarantine. `privacy/company.ex:7–55` resolves dependent plan families; `privacy/purge.ex:7–8,128–170,304–344` enumerates deletion. New sensitive records require lifecycle integration, not just a table.
* `lib/harness_forge_web/live/portal_live.ex:575–581,866–900` broadcasts/reset-fences portal privacy success; inspected domain `privacy/purge.ex:21–26,244–251` does not notify mounted views. Security's alternative is real and distinct.

Source citations denote the frozen `tmp/enhancement-program/11/source-before/` copies, not claimed runtime observations. Existing Elixir ~>1.17, Phoenix1.8.16, LiveView~>1.2.0 and Ecto SQLite0.26.0 from `mix.exs` suffice; no dependency/service/provider is added.

## Decision and bounded contract

### Connected task and rubric

Add a discoverable **Assess representative task** continuation from Company built-package review and Guide. Require explicit selection of an exact existing plan ID/revision hash, its durably bound and verified artifact digest, and one selected saved goal ID/content hash. Require at least one approved company-analysis recommendation in that plan for the chosen goal. Resolve everything through scoped domain reads; a supplied digest or actor label is not authorization. Display the approved guidance, original uncertainty/conflicts/resolution and source pins already available through authenticated loaders, the goal acceptance text and any relevant plan milestones. Missing milestone coverage is visible; this feature does not silently create it.

The owner writes a concrete task and reviews an explicit rubric before recording outcomes. The interface may prefill goal acceptance and approved evaluation/check text as editable **suggestions**; no new inference, inferred completeness or automatic acceptance. The frozen rubric must contain a goal-acceptance obligation and at least one mapped obligation for each selected company-analysis recommendation for that goal. Mapping proves declared accounting only. Show all other package goals as **outside this assessment**; one task never marks the whole company/package complete. Extra owner-authored obligations are permitted and labelled as such.

Persist an immutable task/rubric revision before results. A bounded combined revision is sufficient; avoid a general task-management subsystem. It binds canonical task/rubric hash, stable obligation IDs, goal and exact claim references, exact plan/package identity, captured source/context dependencies and original workspace identity. Use 1–20 mandatory obligations, task/obligation/observation text at most1000 Unicode characters and4000UTF-8 bytes each, total canonical input at most128KiB, at most100 rubric revisions and1000 assessments per workspace. Reject excess explicitly; no silent truncation/deletion. Strings remain data, escaped on output. No attachment upload, file dereference or arbitrary URL fetch.

### Assessment and authority

Record one result per frozen obligation: `met`, `unmet`, or `unobserved`, with bounded observation text. Record task status `completed` or `interrupted`, explicit critical-violation status `none`, `present`, or `unobserved`, and explicit owner judgment `accepted` or `not_accepted`. Acceptance requires completed work, **every mandatory obligation met with nonblank observation**, explicitly no critical violation, and current exact eligibility. Merely entering a result for an unmet obligation cannot pass. Failed/interrupted/unobserved attempts remain recordable as not accepted; no optimistic success or acceptance inherited from a previous attempt.

A final submission atomically persists a separate immutable owner-assessment row and safe audit identity, after reloading the frozen rubric and validating every pin under the existing writable/privacy fence. The authenticated workspace/session establishes local access only. Persist the server local-operator marker (`Workspaces.operator/0` is the literal `local-operator`, `lib/harness_forge/workspaces.ex:20`); any optional bounded person-name attribution is explicitly operator-reported. Neither marker nor name attests an external corporate owner or prevents a false person-name assertion. Reject missing/extra/duplicate obligation IDs, unknown fields, malformed/oversize text, forged hashes and cross-workspace references. A server-minted attempt identity makes an identical retry return the same receipt without another audit; conflicting reuse refuses. An interrupted transaction leaves neither partial receipt nor success.

Corrections to task, rubric or inputs create explicitly linked successors; new results create separately attributable attempts. No update of predecessor content or reference remapping. Show captured historical judgment separately from current applicability. Current authority changes mark assessment applicability stale; historical observations can remain readable within authorised workspace scope. A stale rubric cannot accept another successful result. Restore is historical-only as described below.

Every visible result says **Owner-reported assessment; not independently verified; no runtime or release qualification**. It records an owner's observation, not a trusted `Evaluation.Run`, measured productivity, semantic truth, a signature or permission to execute. This iteration records manually observed representative work; it adds no executor, arbitrary grader, model installation or generated-code host execution.

### Privacy and compatibility

Use distinct company task/rubric and assessment persistence, with workspace indexes and immutable update/delete triggers. Add both to purge and snapshot inventories. Source purge deletes all dependent rubric/assessment bodies and descendants through the exact plan/claim/source context, including uncited influencing sources, before deleting referenced plans. Workspace purge deletes all such records. No free-text audit payloads or content-bearing tombstones; no new tombstone subsystem is needed. Unrelated assessments/policy survive selective deletion. Externally copied exports/backups remain beyond purge authority.

Backup includes committed rows under the existing manifest. Restore rekeys their workspace ownership and preserves their captured historical payloads, while marking **every restored rubric/assessment historical, requiring a new rubric and assessment**. Original-workspace provenance must not equal fresh operational authority: no restored acceptance can count as current, no old submit token can be replayed, and no old decision is reused. Choose an explicit non-authoritative restore marker or derived original/current workspace mismatch; root's interface must freeze that exact representation before implementation. Older backups lacking the new tables continue to restore/migrate. No inherited approval, model or execution authority.

New assessment views participate in existing portal auth/privacy reset generations and supported reload. Portal purge must clear their affected mounted content and late submissions. **General notification after supported domain-source purge remains deferred**; this decision does not claim immediate freshness for arbitrary external writers or solve unrelated-draft preservation. Domain submissions always revalidate persisted authority even before a view refresh.

Public compatibility is additive internal Company domain APIs and portal presentation only. Preserve existing CLI commands/JSON/errors, all three read-only MCP names/schemas/authority, `evaluate`/`runs`/`compare`, compiler/spec/provenance/manifest payloads, artifact digests, plan approval/build/export eligibility and release applicability. Old packages remain assessable only through the stated exact eligible binding; missing assessment means unassessed. No new CLI/MCP tool or assessment export summary in11. Own MCP remains useful for its existing exact readiness reads, but reports no new task authority. Its shared bearer has no independent per-client revocation; portable signer/scope/freshness/revocation remains open. Any assessment ID supplied as a trusted evaluation ID must fail release approval without mutation.

## Alternatives and consequences

| Alternative | Value and cost | Disposition |
|---|---|---|
| Owner task/rubric assessment | Directly connects approved guidance to declared representative-work outcomes; adds human review and sensitive immutable storage/lifecycle work. Cannot prove completeness or actual model quality. | Selected with frozen rubric, exact bindings and full lifecycle as one inseparable slice. |
| Completed supported domain-source purge invalidation (security11/purge12 and original10 security) | Closes observed stale disclosure, reaches both tabs without reload, can preserve unrelated drafts; needs selective dependency/reset/late-output coordination but no assessment schema. | Strongest alternative, deferred explicitly. Existing persisted authority checks and honest reload limit allow prioritising the missing outcome step; this is not a severity dismissal or a vote. Future criterion remains actual supported purge, two mounted tabs, unrelated draft preservation, duplicate/failed/foreign notifications and queued-result refusal. |
| Approval-time goal/recommendation/milestone coherence (02/16) | Catches declared uncovered goals before approval, preserves drafts;16 is especially small/no migration.02 adds conflict pairs, deferrals and export-scope redesign. | Deferred as a separate gate. The selected rubric provides local declared coverage for one task, not a substitute for full-plan coherence. Do not retrofit existing approvals or rewrite exports. |
| Creation-time coverage | Stronger insertion invariant but rejects incomplete authoring drafts. | Retain dissent; no new plan admission invariant in11. |
| Own-MCP connected journey (10) | Improves agent discovery with bounded read-only context, lower persistence cost. Would still report outcome unassessed without task evidence. | Defer new tool; preserve current contracts and explicitly unqualified authority. |
| No feature / isolated administrative form | Lowest change cost; leaves package-to-work gap untouched or merely collects unattached claims. | Reject for11 company-outcome requirement. |

The selected slice costs more than the purge or minimal coverage gate. Its benefit is falsifiable without privileged data: an exact package can be assessed against a previously frozen company-specific rubric, with unmet/unknown/critical outcomes refusing acceptance. Native synthetic demonstration proves this workflow only. Real authorised company/provider data is unavailable; no claim of real-world usefulness, automatic contradiction discovery, time/cost savings or enforcement follows.

## Disposition of every final original

All paths are under `docs/enhancement-program/iterations/11/planning/`; exact bytes/SHA256 are recorded in the binding appendix. Dispositions apply company-outcome value, coverage/coherence, evidence/reliability and simple bounded ownership, not proposal count.

| # / original | Explicit disposition |
|---|---|
|01 owner-outcome|Adopt connected package-to-work and100% declared-obligation requirement. Narrow to one goal with all other goals explicitly unassessed; root/domain/web ownership accepted.|
|02 coherence-completeness|Defer full worksheet/conflict-pair/deferral/export redesign: strong coherence value but larger authority blast radius and still no work outcome. Preserve approval-versus-creation tradeoff; adopt honest declared-coverage language.|
|03 task-rubric|Adopt rubric-before-results, immutable exact references and lifecycle. Strengthen success from merely assessed to every mandatory obligation met; no trusted run.|
|04 domain-contract|Adopt scoped transactional validation and immutable lineage. Combine task/rubric revision to bound schema; history survives ordinary successors but purge removes bodies and restore withdraws current applicability.|
|05 immutable-history|Adopt captured-versus-current distinction and no remapping. No MCP extension/per-client authority claim; use three defined authors, not a fourth tests author.|
|06 evaluation-truth|Adopt strict separation from fixed trusted evaluator and explicit interrupted/unobserved outcomes. No suite or grader extension.|
|07 runtime-boundary|Adopt no release/host-execution authority, failed attempts and replay checks. Missing isolation remains unavailable; no runtime work included.|
|08 portal-flow|Adopt discoverable Company continuation and linked approved evidence/goal. Prefill is editable suggestion only; freeze rubric before results. Reuse reset/auth generations without adding general domain-purge notification.|
|09 usable-outcome|Adopt Guide route, clear scope/status and narrow/zoom/focus checks. Preserve mounted link-return draft, explicit departure/discard and privacy reset contracts; avoid a general navigation redesign.|
|10 own-mcp|Defer new connected read tool: valuable access/discovery but outcome would stay unassessed. Preserve existing read-only contracts, send-time privacy and shared-bearer limits.|
|11 authority-security|Defer recommended mounted domain-purge slice for the concrete tradeoff above; accept its requirement that new receipt sensitivity, workspace scoping and lifecycle be designed together. No claim that existing reload resolves immediate disclosure.|
|12 mounted-purge|Defer domain-completion/selective-preservation event implementation; retain all its acceptance and idempotency/failure/foreign-workspace concerns for future scope. Do not smuggle this second feature into11.|
|13 public-compatibility|Adopt unchanged compiler/export/trusted evaluation meanings and receipts absent from exports. Defer proposed CLI and optional MCP additions to constrain authors/blast radius.|
|14 privacy-lifecycle|Adopt selective body deletion, quarantine and backup coverage. Reject optional exported summary/derived-export addition: changes public digest/privacy surface and is unnecessary. Existing external copies cannot be withdrawn.|
|15 test-oracle|Adopt independently authored frozen obligation oracle and persisted negative checks. New assessment UI uses existing portal purge reset; general domain mounted-canary clearing is explicitly deferred, never claimed passed.|
|16 minimal-ownership|Defer narrow approval-time structural gate despite lowest migration cost: it improves accounting before export but provides no representative-task result. Preserve historical plan semantics and two-author alternative for later selection.|

## Confirmation: required acceptance, executed only by root

1. **Independent positive oracle and native journey.** Before product output, freeze a public synthetic emergency-release corpus (multiple authorised historical/document sources plus future goal), task and at least three mandatory obligations: review, rollback readiness and communication, with explicit expected observations/critical violation. Ordinary configured synthetic-provider analysis → inspect uncertainty/conflict → reject original and save human correction/resolution → exact Evidence successor approval → separate exact plan approval → two deterministic builds and byte-checked target export → select that exact package → edit/freeze rubric → record complete observations and explicit owner acceptance → reopen identical receipt. The oracle is not derived from implementation counts. No generated harness execution; label synthetic owner observations. Edited guidance reaches export; rejected text and full source bodies do not.
2. **Semantic limits and coverage.** Native display shows goal acceptance, linked selected recommendation obligations, uncertainty, current pins, other goals outside scope and unsupported runtime controls. Missing goal row or a selected-goal recommendation mapping refuses rubric freeze. Text mapping is not semantic coverage; a deliberately wrong but structurally valid observation demonstrates that owner testimony remains unverified rather than pretending to auto-grade it.
3. **Negative outcomes.** Missing/extra/duplicate obligation, unmet obligation, blank observation, unobserved critical status, actual critical violation or interrupted task cannot produce accepted success. Record not-accepted attempt and reopen it. Native exercise at least missing-obligation and critical-violation refusal plus accepted completion; inspect persisted rows/audits, not only disabled buttons. Failed validation inserts no receipt/audit. Injected transaction failure leaves no partial result; identical retry produces one receipt/audit and conflicting replay refuses.
4. **Identity/mutation matrix.** Independently substitute task/rubric hash, obligation ID, plan ID/hash, package digest, goal ID/hash, claim reference and foreign-workspace reference. Revalidate at submit, not just form open. Direct saved goal/profile/project mutation, cited and uncited source recapture/revocation, plan/claim supersession and stale mounted event must refuse current acceptance without rewriting predecessor bytes. At least native uncited drift and rubric successor are required; remaining direct mutations require domain integration evidence. New eligible package/rubric successor needs a fresh assessment; no automatic repin/inference/approval.
5. **Authority isolation.** Missing/revoked operator session and forged server attempt/session tokens refuse; caller fields cannot replace the server local-operator marker. Operator-entered person names remain unverified, not a forged-person-name detection claim. Assessment mutations leave claim/plan decisions, artifacts, model requests/budgets, trusted evaluations and release rows unchanged except the explicit assessment/audit writes. Passing an assessment ID or forged owner-success object through release/evaluation APIs fails. Existing CLI/MCP contract regression checks stay green; no new SDK compatibility claim without actual execution.
6. **Privacy/history.** Selective supported purge removes affected rubric/result/observation canaries including uncited context and successors, preserves unrelated data and external export bytes; repeat purge is harmless. Workspace purge removes all new rows. Portal-initiated purge resets two mounted assessment views and old tokens; supported domain purge is verified in persisted/API state and after reload, with immediate mounted freshness explicitly unclaimed. Backup/restore verifies included rows, fresh workspace scoping, historical-only status, no replay/current acceptance, old-backup compatibility and new successor requirement. Raw historical payload bytes remain attributable; permitted outer workspace/quarantine changes are documented.
7. **Usability/recovery.** Real keyboard path and visible focus from built package/Guide; obligation text/status/actions fit320/390CSSpx at100/200% actual zoom. Evidence-link new-tab return retains mounted unsaved work; explicit departure has deliberate discard/save outcome, remount reloads frozen rubric and no invented success. Session/privacy reset discards sensitive state; queued events do not revive it. No claim of full WCAG/speech or novice comprehension.
8. **Regression/evidence.** Root runs focused domain/web/privacy/compatibility checks, canonical `mix test`, formatting, warning-gated compile and appropriate existing static gates. Report exact counts/skips and retain failed attempts. Existing two Dialyzer diagnostics remain explicit unless genuinely fixed within scope. Independent code/security/QA/UI review examines the same frozen packet and actual native evidence. Plans, tests or favourable opinions alone do not count as completed11.

## Ownership, delivery units and retained limits

Maximum **three distinct product authors total, including root and every correction**: (A) principal Elixir author owns new Company assessment domain/schema modules and focused domain tests; (B) principal Phoenix/Elixir author owns Company assessment component, Company/Guide integration and focused web tests; (C) root owns migrations, privacy/snapshot integration, shared portal/config files, public-contract regression integration and all native execution/board/state. Root assigns exact paths before edits; collaborators preserve other changes. Guardrail, impediment, UI/UX and independent reviewers remain read-only advisers and do not become extra correction authors.

Stage reviewable units ideally≤400netLoC: domain contract/validation; persistence+privacy lifecycle; portal continuation; focused oracles/regression fixes. Split same-author units as necessary; do not fake a400-line total estimate. The lifecycle and UI are completion requirements, not optional later tickets. No new router/service/dependency required. Schema addition is additive; rollback disables entry points and retains new rows safely, never drops assessment history to simplify rollback. Root must verify migration/old-workspace preservation before controlled installation; current main85067/8865 and historical01MCP stay untouched during this planning task.

All09 dissent remains: outcomes-first versus coherence/completeness; owner-task evidence versus creation-time/exact-approval-time goal/milestone coverage; portable signer/scope/freshness/revocation and per-client own-MCP authority; Guide discovery versus stale recovery; direct goal/profile/project and full boundary/scope matrices; historical weaker helper/planner draft-byte gaps. This iteration closes only the tested subset, not those whole matrices. Qualified current source recognition from10 remains intact. Real-company/model quality, all live connectors, managed Codex/Claude, Linux, full accessibility, exhaustive log confidentiality, novice and longitudinal outcomes remain unqualified. No private imports, paid inference, publication, permissions expansion or generated-harness host execution.

## Final-original byte bindings

| Original | Bytes | SHA256 |
|---|---:|---|
| 01-owner-outcome.md | 2981 | `172dfe04e3332529cee6e1f5420f1c1f114748c98c6a1b462320bd1dd393f825` |
| 02-coherence-completeness.md | 2626 | `24224f9e806b04a83791f59f3a0f5efda1a8c6b165783d3c7cf4f472e377dd4d` |
| 03-task-rubric.md | 2557 | `ceeea0ad6d2ace128738e511c13d1e3bf95c5a86854f119a467a9cfaeb588e2c` |
| 04-domain-contract.md | 3025 | `1471e64dc14be92a8f83816d167ed787d954e2530d9375fc6929a7d6e49c9402` |
| 05-immutable-history.md | 2975 | `dab58202f887a9ca7ab392408c5490a6cbce31152a0ae273b7304133e8eedaa8` |
| 06-evaluation-truth.md | 2891 | `4674b615d3138d40e242bedc0c32317c0a24a10d078b2a9af2f7ed6f075cc201` |
| 07-runtime-boundary.md | 2978 | `161bbf5b608d2950a4df77393429e30713a54c927f7c1f696b3e1343b433ab23` |
| 08-portal-flow.md | 3010 | `4cff56c86f9b3ade0d3cd54360673fa46f964d1463909f8858491dd03be3536b` |
| 09-usable-outcome.md | 2697 | `f2a307581d9efd8c522f282453b14656d2767e3db268a516d7f53d9cb91859fd` |
| 10-own-mcp.md | 2837 | `c5b2835c99b5355eab5026b7e09ff777972953e820e7e36fd59df2283d97c41c` |
| 11-authority-security.md | 3109 | `902cff3b1a447a9736e6da10041f412c3e01d768dd1a6ea7c33137e36da5c1a5` |
| 12-mounted-purge.md | 2763 | `136c231b37d10f2d2a9543aef2ba11e2473bad05ae36f7961e05013b5dcb9de9` |
| 13-public-compatibility.md | 2689 | `1103c098c7b6e944ca8b35637e56dde3aed979b375275db61bee259888045f31` |
| 14-privacy-lifecycle.md | 2867 | `1fdfbc3312a3f8fd47afb10aa5604a0aa64e31d8e05abd7c76bfd4db42d2cccf` |
| 15-test-oracle.md | 2867 | `d7d5389faceb2bf04b9275ccb114ad17f72776d6ac9f197a5723155a64545ff2` |
| 16-minimal-ownership.md | 2751 | `319bb701c84308d5f6eda4adc6d1a0cee1db891f40c207fc14a82a689d410cf7` |
