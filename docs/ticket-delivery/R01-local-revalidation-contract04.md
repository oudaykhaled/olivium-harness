# R01 local connection revalidation — additive decision 04

03 remains frozen. Add explicit same-connection recovery; availability changes only. Full R01 and external history remain open.

Root adds Evidence.local_revalidation_basis(connection_id, policy_ref, ctx) and Evidence.revalidate_local_connection(connection_id, attrs, ctx), delegating to Evidence.LocalConnectionRevalidation. Require freshly validated interactive SourceUseContext, genuine operator auth and unchanged four-key caller. Background/MCP, expired sessions, foreign workspace/owner, nonlocal connections and unknown keys deny.

Exact mutation attributes: version=LocalConnectionRevalidation.v1, command_id(UUID), policy_ref={id,digest}, expected_generation(integer), expected_connection_state(digest), directory(absolute string). Config is server-derived empty map; nonempty historical config is unsupported. Basis returns policy ref/generation and connection-state digest, granting nothing. State digest covers all persisted connection fields and latest workspace privacy-barrier identity. No invented lock_version.

Require frozen policy integrity, matching owner/connection/workspace, active policy state (quarantined active eligible), and at least one valid surviving enrollment. Quarantine validation checks provenance without authorizing reads. Withdrawn/superseded policies cannot be recovery basis. Namespace tombstones and committed holds remain authoritative.

Resolve directory through LocalImport.approved_directory. Reconstruct connection using existing UUID and empty config; require directory/config digest equals recorded connection_digest and Capture.fingerprint_for_setup equals recorded root_fingerprint. Different directory/device/inode/config denies. Restored workspace recovery requires original physical root.

Use existing privacy-before-SQL synchronization. Deny pending purge; check auth, policy, state/barrier and fingerprint before mutation, repeating fingerprint after acquiring privacy lock. Inside transaction recheck auth, readiness, policy generation and entire observed connection state. CAS updates only directory/config/status=active/cursor=NULL/sync_state=not_synced/sync_complete=false/last_synced_at=NULL/updated_at. Identity/name stay unchanged. Capture independently checks physical root before reading; no future filesystem stability promise.

Atomically append connection_revalidated to existing set journal using revalidate:command_id and digest(connection_id,attrs). Matching replay returns original event plus freshly checked current availability, never repeats activation; changed payload conflicts. Another purge/withdrawal wins. No import, grant, quarantine clearance, hold change or corpus-generation reset.

Root owns new helper, Evidence facade, existing PortalLive connection review handler/form, migration event-kind allowance and tests. Policy owner alone adds journal kind and provenance-only validation helper in its existing files. UI says “Revalidate original directory”; no import enqueue, new route or wizard.

Root tests same-connection A purge/B survival; quarantined recovery then fresh capture/regrant; wrong root/config/owner/expired auth; pending/racing purge; stale generation/state; duplicate/conflicting command; replay after purge; held/withdrawn content denial. Existing rollback restrictions remain.
