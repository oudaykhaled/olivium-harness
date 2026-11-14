# Iteration 09 implementation clarification 01

Root authorized one narrow async correctness amendment during implementation. The CompanyPanel start message now includes its captured `reset_token` alongside `generation`, `request_id`, `run_id` and `input`. PortalLive must compare that token with the current `company_reset_token` **before** starting inference. Leaving Company rotates the reset token; analysis drafts/pending state clear without discarding unrelated catalogue/plan state. This rejects a queued old start delivered after tab departure and return. The async result token remains the same five-key token in the frozen implementation interface.

The original interface and pre-edit briefs remain frozen. Author B owns this correction and its late-start regression test; root owns runtime verification. This adds no inference permission, fallback, dependency, migration or fourth product author. Verification remains pending.
