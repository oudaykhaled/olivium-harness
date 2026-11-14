# V2 decision — reject Company events from discarded generations

**Escalation decision: continue_with_retry**, limited to CR-3 admission correction under the accepted UX scope after reviewer escalation. Supersedes the event-envelope portion of [interface-contract.md](interface-contract.md); other ownership and authority constraints remain. Guardrail concurs. Source review only; no execution/acceptance claimed.

## Evidence and choice

`CompanyPanel.handle_event/3` authenticates/shapes payloads but does not check their generation. `capture_draft/3` runs before pinned-input/domain checks, permitting an already serialized pre-reset change to restore discarded data or a new-record submission to save it. The DOM token is not serialized. These findings supplement [security-review.md](security-review.md) and [code-review.md](code-review.md).

Choose one opaque event generation, separate from the existing integer DOM-reset token. Integer equality alone fixes same-mount ordering but can accept an old generation-zero payload after remount. Adding a second instance identifier works but adds unnecessary metadata. Preserve domain APIs.

## Exact wire and lifetime contract

- A owns socket assign `company_event_generation`: `Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)` (32 lowercase hexadecimal characters). Generate freshly on every component mount and whenever a changed parent privacy-reset token clears cache. Invalidate on authentication revocation. Never accept this assign from parent/client parameters. Ordinary refresh, save, typing, navigation and disclosure retain it.
- Keep integer `company_reset_token` and `data-company-reset-token` unchanged for reset-only DOM clearing; `company_refresh_token` remains separate. Source/workspace purge, restore and sibling reset retain their existing server pathways. The event generation is a freshness marker, not authentication or approval.
- **Every Company event** requires top-level string key `"company_event_generation"`. All nine forms contain one enabled hidden input with that exact name and rendered value, outside domain maps: `%{"company_event_generation" => generation, "profile" => attrs}`. Existing form-level change/submit serialization includes it. Do not introduce input-only change serialization that omits it.
- Every Company click, including navigation/disclosure, carries `phx-value-company_event_generation={@company_event_generation}`; e.g. `%{"company_event_generation" => generation, "section" => "profile"}`. A propagates the assign through Guide/Catalog/Plan and nested helpers. A form's hidden input does not supply click metadata automatically. No implicit generation injection/retry from the latest DOM into an already serialized event.

## Admission order

Authenticate first, before raw-payload traversal. Then require a map containing the exact root string: 32 bytes, lowercase hexadecimal, equal to the socket's current generation. Missing, nested-only, integer, malformed, oversized or different values fail, including on initial mount. **No missing-metadata fallback.** Optional paired `_unused_company_event_generation` must equal `""`; reject other values/shapes. Remove both validated metadata keys, normalize remaining browser `_unused_*` markers, then apply existing bounded event-shape validation and dispatch. Capture, lookups, navigation, preflight and domain calls occur only afterward.

Rejected envelopes retain no submitted text/IDs/hashes, perform no domain calls, log/reflect no payload, and cannot alter drafts, selection or guide scope. Only a fixed notice may change: “This Company view changed. Use the refreshed controls before retrying.” Preserve current legitimate drafts. Keep exact revision/hash and domain admission checks after this fence.

## Ownership and confirmation

A: panel admission/lifetime and Guide transport. B: Catalog/Plan/nested click/form transport; preserve existing DOM-reset callback and focus behavior. C: Portal wiring only if necessary, tests and helpers. No shared/domain/schema changes.

CR-3 tests capture raw old envelopes **before** reset, then deliver them **after** reset processing: profile/repository/project/plan changes and new-record/create submissions cannot restore canaries or write records. Cover source purge, workspace purge, restore and sibling delivery using isolated fixtures. Cover old discard/edit/select/milestone/decision/build/navigation clicks; missing/malformed metadata; and remount rejection when both numeric reset tokens equal zero. Valid current envelopes succeed; ordinary refresh retains generation and drafts; browser markers/bounds/authentication still hold. Test helpers must not silently refresh stale captured metadata.

Retain CR-1 actual installed-client focused-control/lock/ack proof: reset and later acknowledgement cannot restore canaries. Serialized-event rejection and DOM erasure require separate evidence; no destructive native-workspace tests or fallback execution.

Native test interface is QA-only: capture/replay actual serialized Company envelopes unchanged through the installed LiveView channel; identify generation from the named hidden input/click attribute. Root's disposable fixture may broadcast existing `:company_cache_reset` on its `workspace:<id>` topic through private stdin. No product test endpoint/hook or new event. Await reset patch before replay; inspect connected controls and lock acknowledgement afterward.
