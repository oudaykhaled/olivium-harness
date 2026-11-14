## GUARDRAIL BRIEF — Repair WEB delivery lock ordering

**Classification:** Delivery/currentness synchronization repair · potentially shared eligibility path · Root integrates; sole Maestro debugger diagnoses.

**Verdict:** PROCEED-WITH-CONDITIONS. No additional approval gate. Source inspection establishes nesting, not the failure’s root cause.

**Guardrails that apply (ranked):**
1. [harness_delivery.ex:79–96; purge.ex:10–18,813; store.ex:52–60] Preserve one coherent authorization point: authenticated server workspace, purge readiness, exact verified artifact bytes, current claim/plan eligibility and bounded delivery. Preserve error rollback/unavailable semantics and deny disclosure on uncertainty. Do not fix starvation by bypassing eligibility, returning cached bytes or swallowing purge errors.
2. [requirements.ex:58–85; search_completion.ex:673–684] Establish one consistent acquisition order for the reachable caller chain: workspace privacy fence before database transaction/checkout. A nested validator must reuse its caller’s established transaction/fence or acquire them through the same ordered entry boundary. Do not introduce a transaction→privacy-fence inversion or an unchecked public validation helper. Lock/transaction ownership must be explicit; do not assume nested calls are harmless merely because both use identical APIs.
3. [search_completion.ex:11–14,247–258] Preserve existing no-transaction boundaries around runtime/worker interactions. Never wait on another process requiring the held connection or privacy fence. Do not spawn a second writer, independent Repo/process or runtime to escape the lock. Pool enlargement/timeouts alone are not evidence of repaired ordering. The debugger must identify the actual wait chain before changing ownership.
4. [harnesses.ex:224–259; evidence.ex:365–399] Keep exact revision, origin, current retrieval/declaration and artifact-plan binding checks. If expensive formatting/ZIP work moves outside the critical section, it may consume only the verified immutable snapshot; preserve the existing revocation/disclosure contract with appropriate final validation. Removing the delivery transaction is acceptable only after demonstrating that the remaining fence/validation gives equivalent concurrency protection, not merely a successful sequential call.

**Hard STOPs:** No permission/consent shortcut, weaker source currentness, cached-positive fallback, second DB writer or parallel debugging.

**Definition of done:**
- [ ] Root/debugger demonstrate repeated preview/download completes without pool starvation or lingering checkout/lock holders.
- [ ] Concurrent revocation/purge, stale declarations/receipts and transaction errors disclose no unauthorized payload; exact ZIP bytes remain unchanged.
- [ ] Root records focused regression and actual WEB evidence against a new freeze. Historical browser success does not override the reported new failure.

**Knowledge base:** Unchanged. Audit contains exact inspected ranges/hashes; check23/log failures are Root-reported and were not opened. No product/tests/runtime/boards modified or executed.
