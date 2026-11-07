## GUARDRAIL BRIEF — Same-schema local main installation

**Classification:** Root-only local process replacement · same schema · reversible using retained release/backup.

**Verdict:** **PROCEED-WITH-CONDITIONS** after accepted native QA. Static review only; installation/preservation remain unverified. Reviewed SHA256 matches `81c446ce4f71ba95ad19c5ae26e3f2b7d5f28071c6f2a7b10cab5571ca59d8aa`.

**Guardrails that apply to THIS request (ranked):**

1. **Establish quiescence and schema equality before use.** Snapshot, backup and termination are separate observations (`tmp/enhancement-program/06/upgrade_main.py:38`, `:44`, `:61`); SQLite backup is consistent, but equality with the earlier snapshot is not established. Root must prevent concurrent interaction/jobs throughout, confirm no pending recovery/migration, and preserve/compare the backup's logical table inventory with the captured baseline. Startup can otherwise legitimately mutate jobs/audit/privacy (`lib/harness_forge/startup_gate.ex:11`). This is a blocking operational condition, not permission to suppress recovery.

2. **Bind listener identity.** Fixed PID41065 must contain the expected05 `native-corrected` release and open the expected database (`tmp/enhancement-program/06/upgrade_main.py:35`). SIGTERM precedes bounded old-PID absence; timeout starts no replacement (`:61`). Root additionally verifies old8865 listener ownership, port release and new8865 listener ownership: HTTP200 plus command/open-database checks (`:79`, `:87`) alone do not prove that response came from the new process.

3. **Preserve failures before stopping.** Preflight every output path, especially exclusive `main-server.log`, before SIGTERM (`tmp/enhancement-program/06/upgrade_main.py:71`). Backup uses exclusive0600 creation, SQLite backup/integrity check and explicit0600 mode (`:40`). Existing record/snapshots/backup block blind reruns. Failure leaves manual recovery; inspect actual PID/listener first, retain partial evidence, and never restore a backup over a running database or discard newer writes.

4. **Keep claims bounded.** Standard `start`, MCPoff and no QA expression are explicit (`tmp/enhancement-program/06/upgrade_main.py:68`). Raw ps/cookie output stays internal; final printed fields are allowlisted (`:34`, `:98`). All30 table columns/counts/serialized-row hashes and artifact path/hash inventories must match (`:15`, `:90`); these are logical comparisons, not physical SQLite-byte equality. Root corroborates accepted release/assets/source identity separately.

**Hard STOPs:** No installation before these conditions; no automatic rollback, credential output, QA probe on main, or blind retry.

**Definition of done:** Root records identified ready main, unchanged logical inventories and retained backup/failures.

**Knowledge base:** unchanged. Only this report written; no helper execution, runtime operation or database read.
