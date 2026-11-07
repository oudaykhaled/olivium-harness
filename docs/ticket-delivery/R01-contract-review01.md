# R01 independent contract review

**Verdict: changes_requested — one P2 Blocking clarification; no P1 findings.** Review covers proposed decision01 plus frozen addendum01, not implemented behavior.

**Blocking · P2 — preserve removed memberships during cleanup.** Addendum01 line5 says held members become `denied`. Existing `Corpora.invalidate_source_page/3` selects every membership for the source, including `removed` (`corpora.ex:126–132`); membership removal is represented by that retained row (`:200–214`). The addendum’s new currentness predicate intentionally excludes removed memberships but includes denied ones. Therefore a corpus that removed the source before the hold passes the pending check, then unexpectedly becomes blocked when cleanup converts its removed row to denied. Unrelated evidence becomes unavailable merely because cleanup advances.

Smallest correction: specify that cleanup transitions only active/already-denied memberships to denied, preserves removed status, clears references as appropriate, and retains generation advancement. Test removed-before-hold and removal-between-pages cases: current unrelated corpus use remains available, old generation certificates stay stale, and re-including held content cannot restore authority. This is a contract correction, not a new policy framework.

**Non-blocking / Nit:** None added.

**Praise:** The addendum supplies authenticated status/resume, checkpoint CAS and replay semantics, same-identity recapture denial, restored hold preservation and refusal to downgrade nonempty restriction tables. Decision01 explicitly retains independent Models/Harnesses authority and final admission/publication rechecks; legacy citations and cached graph scope are included. These are necessary implementation obligations, not existing coverage claims.

**Pins/limits.** Decision01 SHA256 `5ba65dc23c09f81df307537009ccda3bcc7099c15fe79e90ca37db50775149db`; addendum01 SHA256 `b41e95639eeb5569784d189c21a7b6769c57c276240048d008a4e804b00b298d`; paired addendum audit SHA256 `3081149b40e95c52fbf934ad0b5f4d73bf3e1762096e703d5f000b1cb426e295`. Full contract/guardrail/reuse reports and paired decision audits were consumed. Focused code ranges and hashes are in the audit; no whole-source semantic review or cross-consumer implementation verification is claimed. No product/test/runtime/browser/network/provider work occurred. A04 remains sealed; R01 remains a proposed, partial deny-only prerequisite with no storage-erasure/history/general-grant acceptance.
