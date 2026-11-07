## GUARDRAIL BRIEF — Main-install operational correction

**Classification:** Root-only same-schema local replacement; static correction review.

**Verdict:** **PROCEED-WITH-CONDITIONS** after accepted native QA; HOLD old-main termination until the remaining cleanup condition below is established. No new user approval is required.

Reviewed helper SHA256 matches `04bda665db26d99b747ca9893b7e99a4c53f0ad5ce934084ea96d96d2cd7058b`; preserved original matches `81c446ce4f71ba95ad19c5ae26e3f2b7d5f28071c6f2a7b10cab5571ca59d8aa`.

**Guardrails/checks:**

1. **Remaining material condition:** `tmp/enhancement-program/06/upgrade_main.py:50` counts only running/pending evaluation outcomes. Restart also reconciles terminal outcomes whose cleanup status is `pending` or `cleanup_failed` (`lib/harness_forge/evaluations.ex:207`, `:212`, `:219`). Add that predicate to the existing preflight, or root must separately record zero matching cleanup rows before termination. Do not suppress recovery or reinterpret resulting table changes as preservation.
2. Corrections address earlier findings: all six outputs preflight before stop (`tmp/enhancement-program/06/upgrade_main.py:13`); exact old/new listener ownership and free-port transition (`:39`, `:65`, `:102`, `:128`); consistent0600 backup compared against baseline logical tables (`:71`, `:80`); explicit source/workspace labels and release-migration equality (`:31`, `:55`). Standard start/MCPoff and internal command output remain intact.
3. Root must retain no-interaction scheduling, accepted source/release provenance, partial failures and manual recovery discipline. Pending-count checks are observed windows; before/after all30 logical-table and artifact equality (`tmp/enhancement-program/06/upgrade_main.py:129`) establishes bounded preservation, not future quiescence or physical database-byte equality.

**Definition of done:** Cleanup precondition satisfied; actual root installation verifies identified ready main and unchanged inventories.

**Knowledge base:** unchanged. Previous reports untouched; only this report written. No helper/SQL/runtime/Mix/test/browser execution or database reads.

**Final static check:** SHA256 `9cdca13cda8367f3c41d1f7ecb7558c7eba2dee250a3243ce6551f05d188dbc3` matches. Line50 now includes pending/failed cleanup, closing the identified gap. Static GO under remaining conditions; root acceptance/installation still follows verified QA. Nothing executed.
