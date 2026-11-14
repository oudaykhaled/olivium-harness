---
status: proposed for root acceptance
date: 2026-11-01
decision-maker: /root/i08_conductor/decision_astra
model: gpt-6-astra
phase: planning final; root acceptance pending
---

# ADR08: Recover an invalid package name at the build form

## Context

Select **one UI/UX benefit: actionable package-name build refusal and corrected retry**. The current build handler forwards `Contracts.Error` to a connector fallback, so `Bad Name` yields provider-import advice. This is source-confirmed misdirection, not a measured operator failure rate. The form hardcodes defaults, so retained draft behavior also needs explicit implementation and real browser verification. The frozen v1alpha1 name rule already exists; changing compiler admission is unnecessary.

I fully read all five original07 retrospectives and the full07 handoff before scope selection, then all16 original08 reports before deciding. [Read audit](../../../../../tmp/enhancement-program/08/decision-astra-read-audit.json) records exact fingerprints/dispositions and actual verification of **1002/1002 frozen copies, 9,206,335 bytes; 22/22 prior fingerprints; zero mismatches**. Complete08 manifest SHA `60394a3c73f3e09ae05be408575dce646dede184c2a1f854ad8ff641c947dd8f`; snapshot SHA `cf96c90943f1224b777c0b2884f729b17aca0c09d26be61fd0beca9c989e7cea`. All192 final07 canonical source inputs were independently rehashed against current files and complete08 copies, with zero mismatches. The original550 snapshot remains historical. Current board/state changes are expected root metadata, not a product mismatch.

Root07 closure is [iteration-result.json](../../../../../tmp/enhancement-program/07/iteration-result.json), SHA `9455a7ec0d448c58b900c9929afc6371647185556e2d7bfbe04acda09e8d6596`, recording **7/50 complete** and full original/handoff reading. Full07 handoff SHA `edb6f995fd72a005dce9d54ff32fb5a554372b5dbc3d8534c61cf2709a15c794`; accepted-evidence-final SHA `8e23bf2e136a079f6c2f3d48ee1feac9a6e3d0ea37ee13e6dbcb52b49ee11eb5`. Their historical 6/50/main-pending wording is superseded by root closure and final installation receipt, not an outstanding gate.

07 supports 554 canonical identities across default539/guarded15 plus one separate supplemental identity: 555 distinct observed passes, no added focused repeats. Its final canonical/guarded/supplemental bind192/192 inputs; focused37 binds190/192. Dialyzer has exactly two unsuppressed baseline Releases findings, not a clean result. Failed cancellation attempts and partial visuals remain retained. No new runtime observation was made by this decision maker.

Source anchors: [build handler](../../../../../lib/harness_forge_web/live/portal_live.ex#L425), [generic contract mapping](../../../../../lib/harness_forge_web/live/portal_live.ex#L1258), [form](../../../../../lib/harness_forge_web/live/portal_live.ex#L2008), [schema](../../../../../priv/schemas/harness-v1alpha1.json#L20), [validation](../../../../../lib/harness_forge/contracts.ex#L43), [bounded errors](../../../../../lib/harness_forge/contracts.ex#L323), [build publication ordering](../../../../../lib/harness_forge/harnesses.ex#L93), [reset](../../../../../lib/harness_forge_web/live/portal_live.ex#L784), [existing JS reset/focus](../../../../../assets/js/app.js#L29). Reuse the installed source stack: Elixir1.19.5/OTP28.3.1, Phoenix1.8.16, LiveView1.2.13 from `.tool-versions`/`mix.lock`; no dependency change.

## Decision

Keep the compiler, schema, approvals and publication path authoritative. Present a fixed package-name rule beside the field: **“Use 1–64 characters. Start with a lowercase letter; then use lowercase letters, numbers, underscores or hyphens.”** On a name-only contract refusal, identify Package name as the correction, associate the fixed message with that input, and move focus to its visible correction/input after the patch. Preserve bounded submitted name, package version, runtime target and runtime version for correction. A corrected explicit submission runs the existing build path; no automatic retry or execution occurs.

Classify only inside the build operation. Require typed `Contracts.Error` with `code == "invalid_harness"` and a nonempty list consisting solely of the validator's exact name-detail strings (`$.metadata.name: invalid format`, `outside permitted bounds`, `invalid string`, or `required`, each with the full `$.metadata.name: ` prefix). The type-error vocabulary was checked directly at `Contracts.check/4` (`: invalid ` plus the schema type); any unknown shape falls back. Never interpolate message/details, substring-match arbitrary attacker text, or relabel every `invalid_harness` as a name problem. Mixed name/other-field details and other specification faults get fixed generic package guidance: **“Check the package values and approved inputs, then try building again.”** Fixing a name does not promise that other faults disappeared. Existing `no_approved_claims`, privacy, runtime and other known build reasons retain their specific safe remedy; connector operations retain their existing advice.

Draft state is ephemeral UI state, allowlisted to the four form fields. Retain ordinary rejected strings completely up to an explicit small bound (4096 UTF-8 bytes per text field); malformed/non-string/invalid UTF-8 or oversized values get fixed generic guidance and are not stored/rendered. Do not truncate a rejected value and then compile the truncated replacement. Runtime choices remain the existing fixed allowlist. Escape values as normal HEEx attributes; no raw HTML or browser storage. Reset, purge/restore broadcasts, remount and operator revocation clear retained values and outcome; late pre-reset events/focus must not restore private data. Reuse the existing reset-generation mechanism and fixed visible-target focus pattern, extending it only for this form. Keep notice replacement local to build: repeated refusals replace the prior build refusal, valid retry removes it and uses the existing success message. No general notice framework.

The guaranteed benefit is truthful, keyboard-correctable recovery and preservation of an ordinary rejected draft through retry. Comprehension, task-completion rate and novice satisfaction remain unmeasured. No human study is a prerequisite for this technical benefit.

## Confirmation: positive, negative and edge acceptance

1. **Real refusal and retry:** With current eligible approved synthetic source evidence and otherwise valid values, submit `Bad Name` through the real LiveView build form. The exact fixed name correction is associated with `package-name`; all four ordinary entered values remain. Artifact files/rows and `harness.built` audit count are unchanged. Correct only the name to `good-name`; one explicit build succeeds through the domain, displays its full immutable digest, and removes the stale error. Existing approval/eligibility checks still run; building starts no evaluation.
2. **Boundaries:** Test lowercase single-character and 64-character names as valid; uppercase, leading digit, spaces, empty, and 65-character names as invalid under the unchanged validator. Browser required-field interception and direct server-submission behavior are distinguished. Submitted values are not silently normalized. Preserve all other form choices, including a supported nondefault runtime/profile.
3. **Classification negatives:** An actual non-name contract failure with a valid name gets generic build guidance, never name-only or provider-import guidance. Mixed details get generic build guidance. Unknown/malformed detail shapes, hostile message/detail sentinels and fake path lookalikes cannot leak or be classified as exact name faults. A genuine connector error still has its connector remedy. Missing approved claims and locked/privacy states retain their proper refusal and produce no artifact.
4. **Draft/privacy edges:** A normal invalid draft survives the response and ordinary harmless rerender without focus theft. Purge/restore/cache reset, revocation/remount and delayed old-generation input/focus cannot restore that draft or clear a newer error. Two successive failures show only the current build result. Oversized/malformed values are bounded and not echoed; rejected state is neither persisted nor audited. Existing export target/outcome and readiness selections retain their exact digest/generation semantics.
5. **Native keyboard and fit:** Root records the actual invalid submit → correction → valid retry journey using keyboard input, labelled field/error association, active-element before/after, logical next Tab and visible focus. At CSS320 and390, each at actual browser100% and200% zoom, capture complete form/correction controls, dimensions and ordinary native screenshots; no document horizontal scroll or clipped message/control. Actual zoom is read, not inferred from pixel ratio. Inspect DOM/AX associations; do not call that a speech or full-WCAG audit. Reset while the form is focused and a stale focus delivery must not steal focus or revive draft text.
6. **Regression preservation:** Existing package export, readiness, company builder, goal-claim approval, portal authentication/privacy and connector error tests pass against final source. Compare prior artifact digest identity on an unchanged valid fixture; immutable historical runs and public/private boundaries are unchanged. No new MCP authority or current qualification claim is introduced.

## Consequences

This repairs an already false recovery instruction and makes its successful retry observable without domain changes. It adds small presentation/draft/reset state whose privacy and focus lifecycle require meaningful tests. It reaches users who encounter invalid names, whereas saved-goal continuation could help more authors; that narrower reach is an accepted cost. Exact-detail mapping is coupled to validator vocabulary, so tests must bind actual validator output and default safely when it changes. No new retries, timeouts, datastore, migration, connector request or operational service is introduced. Revert the bounded UI/presenter/JS change if it fails review; no persisted schema rollback is required, and evidence/artifacts must not be deleted.

## Alternatives and preserved independent dissent

- **Deliberate Goals-to-Evidence continuation:** Strongest competing benefit. Cards currently stop after owner/title/acceptance; an explicit route can improve discoverability without implicit selection or approval. Per-card and post-save variants are distinct. It is deferred because current build feedback is demonstrably wrong and the selected retry can be directly verified. Its technical navigation benefit could ship without a human study; the unperformed4/5 comprehension target must remain unmeasured, not become an invented gate. Automatic goal preselection is not authorized by either choice.
- **Own-MCP digest handoff:** A compact disclosure could accurately carry a full digest to the existing read-only tool and guide. Deferred because it adds content and does not repair demonstrated wrong feedback; live availability/SDK compatibility cannot be inferred.
- **Terminal-Cancel focus recovery:** Conditional Cancel removal presents a credible keyboard risk. The 12 observed07 Queue-focus polls do not exercise it. Defer pending an actual transition observation; this ADR does not label the risk a confirmed failure.
- **Global operation-owned notices or generic error-map rewrite:** Wider coverage at the cost of cross-flow state and regression surface. Defer; build-local correction is sufficient. **Do nothing:** no code risk but knowingly preserves wrong provider advice.

Original07 Product, UX and Architecture each favored continuation; Trust and Quality favored name recovery. Preserve those independent judgments, never aggregate them as votes. Earlier05/06 Product outcome qualification, Architecture coherence-first, Trust portable signer/company scope/freshness/revocation authority, UX continuation/comprehension and Quality accurate recovery/notice ownership remain unanswered by this UI patch. The07 functionality proposals also disagree: Product places selected-goal coverage before approval; UX/Architecture/Quality place it before new/successor revision creation, trading incomplete drafts against admission invariants. Trust instead proposes individually revocable MCP clients. No09 scope or gate is selected here.

Company/model fitness, omitted obligations/coherence, all authenticated connectors, managed Codex/Claude, live Linux/hostile forwarding, portable recipient authority, scoped MCP-client revocation, novice/speech/full accessibility, longitudinal reliability and fresh07/current MCP SDK remain unproven. Historical01 MCP evidence is historical. Main07 PID71456/8865 with MCPoff/noQAprobe and historical01 MCP8867 are observations to preserve, never permission to operate.

## Bounded delivery, owners and pre-edit handoff

Root must full-read/accept this ADR after conductor completion before implementation dispatch. Use fresh **Guardrail Agent** (or Principal Security Auditor for the scoped security review), **Staff Tech Lead** impediment adviser and actual supported **Principal UI/UX Engineer** before product edits. Guardrail reviews trusted detail classification, bounded ephemeral draft/reset and no authority expansion; impediment advice resolves file/execution ownership and smallest workable reset/focus seam; UI/UX reviews exact copy, association, focus and native matrix. These are advisory handoffs within existing authorization, not new user permission gates. Their concrete findings go to the assigned authors; no Figma/private imports or external access is needed.

Capabilities are cited from the [fleet map](/Users/<user>/.agents/skills/fleet-capability-map/SKILL.md): `principal-elixir-engineer` owns Phoenix/LiveView/OTP; `staff-tech-lead` owns ADR/blast-radius/risk; `principal-security-auditor` owns access/input/security review; `principal-code-reviewer` owns correctness/security/tests; `principal-qa-web-playwright` owns native browser/keyboard/visual evidence; `staff-qa-lead` owns evidence/quality gates. The runtime exposes **Principal UI/UX Engineer**; [conductor contract](../../conductor.md) explicitly resolves the older map omission. Use supported role labels, not an invented slug. Standalone OSS has no private atlas dependency or build-orchestrator-v2 protocol.

At most **three distinct product authors including root**, across the entire iteration; reuse them for corrections:

| Owner | Exact source/test ownership | Blast radius / PR-sized unit |
|---|---|---|
| A — Principal Elixir / OTP Engineer | `lib/harness_forge_web/live/portal_live.ex`; new `lib/harness_forge_web/package_build.ex` only if extraction keeps presentation cohesive | Build presentation, bounded ephemeral draft and reset integration; no generic connector-map rewrite. Aim <250 net lines. |
| B — separate Principal Elixir / OTP Engineer | new `test/harness_forge_web/package_build_test.exs` | Real-domain refusal/retry, validator classification, draft/reset/privacy and no-publication oracles. Aim <200 net lines; split reviewable test cases if larger. |
| Root — existing coordinator | `assets/js/app.js` only for bounded build-form reset and generation/visible-target focus integration; root-owned temporary native evidence scripts under08 | Preserve existing focus/export/readiness behavior; aim <80 net lines. Sole board/state/runtime/shared-integration writer and sole command/native operator. |

Prefer one integrated reviewable change under400 net lines; these are estimates, not permission to weaken meaningful tests. A and B do not edit each other's files, and no fourth author substitutes after review failures. No CSS/schema/compiler/domain/router/config/migration/dependency edit is planned. If a necessary fix touches another file, root/tech lead records the exact bounded ownership amendment before editing; a substantive domain or new user-flow expansion requires re-planning. Root may omit the extracted presenter or JS change if acceptance is met more simply, documenting the final ownership.

## Root-only verification and review loop

Root owns the serial Mix/native/build/browser/DB/process window. Authors write code/tests and hand off commands; independent QA specifies and assesses checks, attributing executed observations to root. Run focused `mix test test/harness_forge_web/package_build_test.exs` plus affected export/readiness/company/goal/privacy/connector tests, then canonical `mix test`, warning-gated compile, exact existing CI Credo scope and formatting. Record actual commands, exit codes, identities/skips, final source hashes and failures; do not invent counts in advance. If Dialyzer is required by root's final gate, retain exactly baseline findings and reject new ones; never suppress or call baseline exit2 clean.

Do not rerun unrelated Docker/model suites just to call historical evidence fresh. Root may reuse07 guarded15/supplemental runtime evidence only with an explicit final unchanged dependency/source-hash comparison for the relevant domain/runtime files and tests; list exactly what was reused and why. Changed dependencies or a material runtime concern invalidate that scoped reuse and trigger the affected check. Canonical08 and new focusedUI/native08 results must be fresh. UI browser evidence comes from a separately built, source-bound candidate and disposable synthetic workspace; no inference, generated-harness host execution or main overwrite. Preserve release/asset identity and root's existing main-install preservation procedure if local installation follows acceptance.

Independent **Principal Code Reviewer** reviews the final diff and test oracles. Independent **Principal Web QA (Playwright)** and **Principal UI/UX Engineer** inspect root-recorded actual native journey, complete screenshots/DOM/zoom and failure/reset states; **Staff QA Lead** checks identity accounting and evidence limits. They do not self-certify their authored code. Findings return to the original owners; repeat only affected verification and final-source binding after corrections. Maximum three review rounds, then root/Staff Tech Lead chooses a bounded retry/re-plan with exact failing evidence; no silent scope growth or fourth author. No implementation, review, merge, deployment or verification is claimed by this planning ADR.

## All16 original proposal dispositions

Each original was fully read before selection, <=350 whitespace words, individually fingerprinted and retained unchanged. Decisions below use source evidence, user value, reliability and minimality; **no vote/count/ranking aggregation**. Model for every original: `gpt-6-sol`; decision maker: `gpt-6-astra`.

### 01 — p01_goal_journey

Original [01-goal-journey.md](planning/01-goal-journey.md); agent `/root/i08_conductor/p01_goal_journey`, Staff Product Owner; **2822 bytes / 334 words**; SHA256 `1afd0c53fe657dac440ab19d21548ac0b713af9592dcc6930936dcdbcddad7c7`.

Defer continuation. Its per-card cue addresses source-evidenced discontinuity; the unmeasured abandonment/comprehension claim remains separate. Prefer the demonstrated wrong recovery instruction now; retain blank selection and separate approval requirements for later selection.

### 02 — p02_recovery_copy

Original [02-recovery-copy.md](planning/02-recovery-copy.md); agent `/root/i08_conductor/p02_recovery_copy`, Staff Documentation Writer; **3090 bytes / 342 words**; SHA256 `78536cd5c28791041eafd4e997db5443b1ab293c7fa0e642981fad45cba45375`.

Adopt fixed name correction, bounded retained draft and operation-specific fallback. Adopt its cautious mixed-error fallback rather than implying a multi-field failure is name-only. Defer the stronger workflow-reach alternative without dismissing it.

### 03 — p03_keyboard_focus

Original [03-keyboard-focus.md](planning/03-keyboard-focus.md); agent `/root/i08_conductor/p03_keyboard_focus`, Principal Web QA (Playwright); **3079 bytes / 350 words**; SHA256 `83413d7850c61026f026acb2a5e1e8c4597d01a681275d6112914fc81f7d93e3`.

Defer saved-goal keyboard continuation; retain its heading/next-Tab and reset checks if selected later. No observed novice benefit is claimed. Its smaller confirmed-name-repair dissent is material to the chosen scope.

### 04 — p04_narrow_zoom

Original [04-narrow-zoom.md](planning/04-narrow-zoom.md); agent `/root/i08_conductor/p04_narrow_zoom`, Principal Web QA (Playwright); **2694 bytes / 332 words**; SHA256 `62d4a5014041f825f24b26ac48b090bd722c557baa32415d091e735856fa2fc0`.

Defer continuation but adopt the native 320/390 by actual 100/200% matrix for the selected correction. Long text/visible focus must be inspected. Previous run-card images are not evidence of build-form fit.

### 05 — p05_validation_contract

Original [05-validation-contract.md](planning/05-validation-contract.md); agent `/root/i08_conductor/p05_validation_contract`, Principal Elixir / OTP Engineer; **3026 bytes / 324 words**; SHA256 `dae2717d5d4fd23cd430df19c472988c5ceae1e0078fecfb482d297a66b34ba4`.

Adopt typed build-context classification and fixed copy without raw details. Resolve mixed faults conservatively: name-only detail sets receive the name correction; mixed/other sets receive bounded generic build guidance. Retain corrected retry and no-publication oracles.

### 06 — p06_notice_state

Original [06-notice-state.md](planning/06-notice-state.md); agent `/root/i08_conductor/p06_notice_state`, Principal Elixir / OTP Engineer; **2884 bytes / 349 words**; SHA256 `004adf15cb23e5b75da5ee97de283b8e3d308e0bb878a137b66cc911ab8fbc9f`.

Adopt bounded build recovery and repeated-failure/success notice replacement. Reuse current notices; defer a global operation-owned notice framework and unrelated asynchronous flash conflicts. Retain continuation as a broader reach alternative.

### 07 — p07_privacy_reset

Original [07-privacy-reset.md](planning/07-privacy-reset.md); agent `/root/i08_conductor/p07_privacy_reset`, Principal Security Auditor; **2910 bytes / 319 words**; SHA256 `ab6ce34f725b4eb16fc5715d02f45e27ff92b43c9b416ffb6911e65b4550ff3b`.

Defer its generation-bound saved-goal navigation. Adopt the privacy principle for any retained build draft: reset/revocation and late events cannot restore pre-reset values. Its name-repair dissent supports minimal scope, not a vote.

### 08 — p08_authority_truth

Original [08-authority-truth.md](planning/08-authority-truth.md); agent `/root/i08_conductor/p08_authority_truth`, Principal Security Auditor; **2944 bytes / 344 words**; SHA256 `c9572466eca8fbf286e9ba60f6c0b9b08b3b1742806e5643cefbc7b2b4dc97c6`.

Defer continuation while preserving deliberate selection, exact revision, and no-navigation-authority invariants. This repair changes no approval/eligibility authority. Its stronger workflow-reach hypothesis remains unresolved.

### 09 — p09_mcp_inspection

Original [09-mcp-inspection.md](planning/09-mcp-inspection.md); agent `/root/i08_conductor/p09_mcp_inspection`, Principal API QA (curl / HTTPie); **2829 bytes / 334 words**; SHA256 `8ffb39dfca2a4a0e374f917f3f4aca832b836e18b400aee550b37ef29e67991e`.

Defer own-MCP digest disclosure. It is a useful bounded handoff with no live request, but no demonstrated wrong result is repaired and it adds per-card content. Preserve exact digest/current eligibility/Not-assessed semantics and absence of fresh SDK qualification.

### 10 — p10_information_architecture

Original [10-information-architecture.md](planning/10-information-architecture.md); agent `/root/i08_conductor/p10_information_architecture`, Staff Documentation Writer; **3108 bytes / 346 words**; SHA256 `ad7c3722cace07463d0dc987324173c670cc402a2af88583b51e3673c808d811`.

Defer the forward cue from saved cards. Its reverse-empty-state evidence supports a real navigation asymmetry; choosing name recovery does not disprove that need. Keep no-new-panel and blank-selection design for future consideration.

### 11 — p11_cognitive_load

Original [11-cognitive-load.md](planning/11-cognitive-load.md); agent `/root/i08_conductor/p11_cognitive_load`, Staff Product Owner; **2531 bytes / 330 words**; SHA256 `f9b3a74543be9738d38909229ae30bdd5a020d554c20d9fa47502045e06af9a3`.

Defer first-time continuation. The source gap is real; the human effect remains unmeasured. Do not treat the unperformed 4/5 study as a prerequisite for future technical navigation delivery or for 07 closure/08 start.

### 12 — p12_evidence_navigation

Original [12-evidence-navigation.md](planning/12-evidence-navigation.md); agent `/root/i08_conductor/p12_evidence_navigation`, Staff Product Owner; **2583 bytes / 349 words**; SHA256 `d44c0725aae348da6750d9cedde28caa6a44350d0fdea06b4bdce3540930d9fc`.

Defer post-success continuation specifically (distinct from per-card actions). Invalid-save/unavailable-state gating is a valuable separate design constraint. This choice does not silently combine post-save and per-card variants.

### 13 — p13_poll_stability

Original [13-poll-stability.md](planning/13-poll-stability.md); agent `/root/i08_conductor/p13_poll_stability`, Principal Frontend Performance Engineer; **2480 bytes / 305 words**; SHA256 `8f0056967604f489c3518c1304115edfc2ea4af3869773dc3d7a7d811ad654dd`.

Defer terminal-Cancel focus recovery. Current conditional removal and prior missing observation establish a risk, not a demonstrated focus regression. Preserve its same-run/two-runs/no-steal oracle for a future measured investigation.

### 14 — p14_test_oracles

Original [14-test-oracles.md](planning/14-test-oracles.md); agent `/root/i08_conductor/p14_test_oracles`, Staff QA Lead; **2831 bytes / 334 words**; SHA256 `fffba31fd82beef2f17be426bf409da19dc1a7664fd7eb8105d9be20254d85d2`.

Adopt real approved-evidence invalid-name/refusal/valid-retry oracles, non-name negative case, hostile details, reset and narrow-zoom evidence. No fixture pass establishes company/model fitness or human comprehension.

### 15 — p15_boundary_minimality

Original [15-boundary-minimality.md](planning/15-boundary-minimality.md); agent `/root/i08_conductor/p15_boundary_minimality`, Staff Tech Lead; **3052 bytes / 350 words**; SHA256 `f6e6010212ac8ef1fb3367d1f7938d3d9194a681d7f7df2bed9ad490f0fd865b`.

Defer minimal no-payload saved-goal continuation. Its reuse and rollback case is strong, and name classification plus draft retention add real work. Prefer correctness of current recovery over adding another route this iteration; retain this dissent explicitly.

### 16 — p16_adversarial_choice

Original [16-adversarial-choice.md](planning/16-adversarial-choice.md); agent `/root/i08_conductor/p16_adversarial_choice`, Staff Tech Lead; **3098 bytes / 343 words**; SHA256 `634e0895d0c2b868461d369e12cce63e31b8e29249a0ee38e7d45c91e72548f5`.

Adopt the bounded recovery benefit and existing-schema help. Adopt exact artifact identity, no false qualification, reset/focus-generation requirements and <400-line PR aim. Reject generic error-map rewrite; continuation remains the stronger reach hypothesis.

## Concurrency and root interface

All16 original reports were fully read/dispositioned before READY_DECISION_BARRIER. The conductor then captured an actual direct `list_agents` response with **all16 original planners simultaneously RUNNING**, after that signal and before any release. [Barrier receipt](../../../../../tmp/enhancement-program/08/conductor08-final-running-barrier.json): **26,900 bytes**, SHA256 `cee05a2270feca79a2fe5dc984ffc7cd8e170b1c71cb2b17e829e938423c8826`; the full response, original report hashes and spawn-model metadata references are retained. Its embedded readiness snapshot preserves the earlier draft fingerprint.

All16 originals were then explicitly released and completed. [Completion receipt](../../../../../tmp/enhancement-program/08/conductor08-originals-completed.json): **11,802 bytes**, SHA256 `7a301d6f3350293077e8e09831ddb153505a2d3accd550cebdda29e657b8b94d`; each completed status is attributed to the conductor's direct post-release listing plus individual final notification. No replacement/reactivation occurred. I verified both receipt hashes, matched the16 roster identities/statuses and rehashed all16 unchanged original reports. Conductor sent explicit FINALIZE before this finalization. The exact-detail wording correction from provisional `expected string` to source-confirmed `invalid string` is included; all individual dispositions remain unchanged.

No implementation authors/advisors were dispatched by this decision maker or conductor during planning. [Final readiness](../../../../../tmp/enhancement-program/08/decision-astra-readiness.json) records the finalized ADR fingerprint and receipts. Root must now full-read and accept the ADR, then schedule the pre-edit advisory and implementation phases under the existing programme. This is completed planning, not an implemented, reviewed, merged, deployed or verified08 benefit; the official completed count remains7/50.
