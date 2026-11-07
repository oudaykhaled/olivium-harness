# Company value proposal: trustworthy evaluation route

**User and job.** A company operator needs to trust an evaluation's route and controls before deciding release. Metric: **zero qualified coding attempts whose recorded route differs from the route used**, across Desktop/Unix, failed discovery and drift. One mismatch or qualification after unknown discovery falsifies it. This enables, but does not prove, company fitness: the suite uses two synthetic Go tasks (`test/harness_forge/coding_evaluation_test.exs:118-122`); iteration 06 exports tested no company/model outcomes (`docs/enhancement-program/iterations/06/handoff-to-07.md`).

**Recommendation.** Give each coding attempt one validated transport snapshot for relay, proxy, verification, profile and applicability. `lib/harness_forge/execution/coding.ex:28-39` discovers repeatedly for profiles; `:128-151` discovers for relay; `:427-432` converts failure to Unix; `:446-465` and `:661-666` rediscover for proxy setup/verification. This is a source-derived risk, not an observed exploit. Keep `lib/harness_forge/readiness.ex:105-115` command-free and abstaining without current OpenCode authority.

**Trade-off.** Explicit unavailable results may reduce apparent evaluations but make decisions interpretable. Declared policy-conflict admission addresses separate coverage/coherence (`lib/harness_forge/company.ex:234-265`) and adds decision/invalidation/privacy lifecycle work. Representative company-task qualification is the eventual value test, requiring owner-approved tasks, obligations and real model/connector evidence. Prior dissent remains open (`docs/enhancement-program/iterations/05/handoff-to-06.md`; `docs/enhancement-program/iterations/06/retro/01-product.md`).

**Falsifiable acceptance.**

- Given recognized Desktop or Unix discovery, when a coding attempt starts, then its relay/proxy behavior, verified configuration and persisted profile identify that same snapshot; a second discovery cannot change that attempt.
- Given timeout, nonzero, malformed or unknown discovery, when an attempt starts, then it blocks before relay/container creation and never asserts Unix or runtime qualification.
- Given route/configuration drift after launch, when applicability is checked, then qualification is refused; cleanup still targets the attempt's original owned resources, including after interruption.

**Ownership and verification.** One execution-domain owner changes `Coding` and focused coding-evaluation tests; root coordinates shared integration and the single Mix window. Verify synthetic discovery cases, existing Docker-gated protocol cases where available, and canonical tests. Report default Docker skips and live-model/company limits separately.
