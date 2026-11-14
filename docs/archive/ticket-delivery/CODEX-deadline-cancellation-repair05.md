# Deadline cancellation repair 05

**Status:** Authored; Root verification pending. This is a product boundary repair, not a fixture-only classification. No checks, model calls or runtime actions were executed by this author.

## Evidence and decision

[Diagnosis 04](CODEX-deadline-fixture-debug04.md) records a passing 102-test check and a later 72-test check with one failure on identical deadline-path source. It identifies a credible mechanism, without a captured failing-client PID: the absolute timer can kill a collector while its SQL-bearing dispatch guard owns a shared database connection, invalidating that connection before the caller reconciles usage.

`HTTP.request_responses` previously created its killable task before calling `current_identity`; `request_metadata` created another killable task before source/currentness guards. Move each authority callback into the original admission/settlement caller, before creating a network task. Strip `:dispatch_guard` from transport options. The collector then performs only a pure monotonic cutoff check and bounded Req I/O. This also removes nested identity/SQL work from the outer Responses collector. Runtime, identity, Ledger and existing authoring HTTP defaults remain unchanged.

After the guard returns, check the same deadline before spawning; check it again in the network actor before dispatch. An admission guard that completes after the cutoff returns `model_deadline_exceeded` and sends no HTTP. Existing no-hard-database-contention-SLO limitations remain: the product does not kill an in-progress SQL guard to manufacture a shorter wall-clock result. No SQL/privacy fence spans network I/O.

Network readers retain their existing absolute deadline, expiry timer, byte limits, zero retries and continuous-drip cutoff. Runtime retains reservation ownership, conservative uncertain accounting, valid usage reconciliation and post-response currentness/cancellation checks. This repair does not catch an exited database client and retry settlement.

## Regression and verification handoff

The new test exercises both metadata and Responses entry points. It reserves Ledger capacity, opens a real SQL transaction in the guard, and holds it across a 50 ms transport cutoff using a controlled 100 ms gate. It then requires zero HTTP egress, successful uncertain reconciliation, the full 384-token reservation, another query on the same connection, and proof that the guard ran in the caller. On the former implementation the timer could kill that SQL client; Root can use the frozen pre-repair provider to obtain a red result without altering the regression.

Existing cumulative 500 ms / 900 ms assertions, continuous-drip bounds, remaining-lifetime bounds, during-metadata and during-inference revocation, and reported-usage-before-publication-denial assertions are preserved. Root must run the new regression and existing deadline/native/authoring suites, inspect the original failure mechanism, and review the source before qualification. Exact file pins and unchanged supporting boundaries are in `protocol/implementation-ready03.json`.
