# 15 — Company operator job and value

**User/job.** A company operator inspecting a saved package needs to decide what evidence is missing before release approval. A passed static check yields `cleanup:not_started`; its summary reads like a cleanup incident. Native inspection recorded this combination ([03 UX validation](../../03/review/ux-validation.md)). [Evaluations](../../../../../lib/harness_forge/evaluations.ex) records `not_started`; [Readiness](../../../../../lib/harness_forge/readiness.ex) classifies it as incomplete; [PackageReadiness](../../../../../lib/harness_forge_web/components/package_readiness.ex) prioritizes cleanup over admission. Release still requires a qualified task.

**Choose one UI benefit:** explain a passed static evaluation as “static evidence only; runtime cleanup was not attempted; a qualified model-backed task is required.” Keep `not_started`, seven stages, refusal and next action unchanged. Complete-company reliability remains unproven. OpenCode current task identity/applicability/admission remains **Not assessed** under the accepted [amendment](../../03/decision-amendment.md).

**Success/falsification.** In a future blinded five-operator walkthrough, target ≥4/5 identifying the next qualification step within 60 seconds and zero false “cleanup failed” or “release qualified” interpretations. This is proposed, not observed; one false qualification interpretation rejects the copy. Acceptance:

- Given a persisted passed static run with cleanup `not_started`, when inspected, then summary explains no runtime cleanup was attempted and the qualified-task requirement while recorded stage values and gate refusal stay identical.
- Given a task run with `cleanup_failed`, when inspected, then its actual cleanup incident remains prominent and admission is not described as qualified.
- Given absent or unknown evaluation/cleanup metadata, when inspected, then no static-success explanation appears and existing unavailable/refusal states remain clear.

**Alternatives/trade-off.** Export recovery fixes a real filesystem retry defect but touches error lifecycle and needs no-overwrite verification. General summary/action compression may reduce reading time but risks hiding gates. Static explanation has direct native evidence and a small surface. Retain the retrospective's policy-first versus qualification-first disagreement.

**Files/effort/risk.** Likely `lib/harness_forge_web/components/package_readiness.ex` plus its focused test; ~0.5–1 implementation day including native keyboard, 320 CSS-pixel and 200% zoom checks. Guard the copy by validated evaluation kind/outcome/cleanup; never infer a successful task, change admission, erase genuine cleanup failure, or alter auth/reset/privacy/no-overwrite behavior.
