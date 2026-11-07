# Recorded checks: bounded static review

**Blocking:** None. Approve the scoped metadata/display implementation at freeze04 (`bf5390de2cf20b1ab93f607addb5731e8e18c98c14a456f87420ac469b22f94f`). This is source approval, not release or full-ticket approval.

**Non-blocking:** None identified within the reviewed changes. Root’s final “Task check” label correctly avoids implying that a stored task result establishes company representativeness.

**Nit:** None.

**Praise / evidence:**
- `evaluations.ex:17–91` restricts the query to the server workspace and exact digest, orders newest first with an ID tie-breaker, and limits results to ten. SQL projects allowlisted scalar fields; it does not hydrate full result/context records or dispatch checks. Invalid values become unknown; query failure remains unavailable.
- `harness_delivery.ex:34–57` adds history inside the existing eligible-artifact preview path. Download behavior, purge checks, eligibility, and current qualification authority are unchanged.
- `harness_live.ex:105–201,278–322` validates display values, uses fixed reason labels and escaped HEEx output, distinguishes unavailable/unknown/empty history, and explicitly disclaims current qualification. Three recent checks remain visible; older records and identifiers use native disclosures. Download precedes the history card.
- The six service and two UI additions cover exact scope, ten-row bounds, malformed metadata/privacy canaries, unavailable storage, revoked eligibility, invalid references, and historical-versus-current display. Static inspection found no introduced blocker. The source03→04 delta is only the task label and test-call formatting.

All five current files match their freeze04 copies and manifest pins. Review coverage and hashes are in the companion audit; this does not attest to all 383 manifest entries. No tests, runtime, browser, provider calls, or generated artifacts were executed. Root reported check14’s 27 passes on freeze03 and a formatting pass before check16; check16’s current-source result was pending at review time. Browser/ZIP evidence was not re-reviewed. Existing applicability, representative-task, and release-qualification limits remain explicit.
