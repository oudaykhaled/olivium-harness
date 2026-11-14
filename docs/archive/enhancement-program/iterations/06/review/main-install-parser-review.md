## GUARDRAIL BRIEF — Migration filename parser correction

**Verdict: STATIC GO under the existing root installation conditions.** No additional correction is required for this bounded parser fix.

Full-file diff confirms exactly one change at `tmp/enhancement-program/06/upgrade_main.py:55`: exclude filenames whose prefix before the first underscore is nonnumeric. This skips `.formatter.exs` without altering numeric migration conversion. The following nonempty expected-set, exact applied-version equality and zero pending-work checks remain unchanged (`:56`).

Actual SHA256 values match:

- Corrected helper: `bcb48b0e3138e557cd94eb31222c0849e1a4d267b511518836d09bf57020571a`.
- Preserved predecessor: `ff2d11cf510d2500dcf6df7eac5bd00acd1fc8736d60b2046fd8a2a6add6a6cb`.

`tmp/enhancement-program/06/main-install-attempt01.json:4` records failure before snapshot/backup/shutdown, identified old main still running and all six outputs absent. Those are root observations, not this reviewer's runtime verification. Preserve that failed attempt. Root must complete the planned read-only numeric-version comparison and current identity/output preflight before retry; all prior backup, listener, preservation and recovery conditions still apply.

Only this new report was written. Earlier reports/helpers remain untouched. No helper/runtime/SQL/Mix/browser execution, database reads or product edits occurred.
