# 06 proposal — Packages export recovery

**Operator job/hypothesis.** After failed export, an operator must correct the destination and confirm which package reached which directory without damaging existing files. Success means the cases below report correctly and preserve existing bytes. Misleading success, wrong-package feedback or lost retry input falsifies it. Comprehension remains unmeasured.

**Facts.** `PortalLive` stores only `:export_path` ([36](../../../../../lib/harness_forge_web/live/portal_live.ex#L36)); success assigns submitted target and generic flash ([432](../../../../../lib/harness_forge_web/live/portal_live.ex#L432)), while failure calls `finish/3` ([441](../../../../../lib/harness_forge_web/live/portal_live.ex#L441)). The result appears after all package rows, without digest ([1974](../../../../../lib/harness_forge_web/live/portal_live.ex#L1974)). Unlike `finish/3`, success does not clear flash ([733](../../../../../lib/harness_forge_web/live/portal_live.ex#L733)); native05 observed an old alert beside success. Artifact errors, except four runtime codes, become a provider-page message ([1162](../../../../../lib/harness_forge_web/live/portal_live.ex#L1162)). `Artifacts.export/3` checks absence before and after staging ([104](../../../../../lib/harness_forge/artifacts.ex#L104)); occupied targets yield `export_conflict` ([324](../../../../../lib/harness_forge/artifacts.ex#L324)). Audit follows publication ([127](../../../../../lib/harness_forge/harnesses.ex#L127)).

**Proposed decision.** Own `PortalLive` Packages feedback and web test. Show a result beside its package, using returned path and digest. Supersede only prior export feedback. Map occupied target to “Choose a new directory”; unsafe/invalid target to an allowed absolute new directory with a safe existing parent. For I/O/unknown failure, state completion unconfirmed; inspect target before retry, then check permissions if unwritable. Preserve input after failure. Clear result/draft on privacy reset or revocation. Preserve export admission, persistence and no-overwrite behavior.

**Acceptance.**

- Given eligible A and fresh target, when export succeeds, then A’s row shows its digest and returned path, without superseded export feedback.
- Given occupied target with sentinel bytes, when A exports, then show occupied remedy, keep target and sentinel bytes, and show no success for that attempt.
- Given unsafe/relative target, when A exports, then show its remedy, preserve input and create no destination; I/O errors state unconfirmed pending inspection.
- Given A’s earlier result and a B attempt or privacy reset, when the view settles, then no A result appears for B or after reset; keyboard retry reaches the field; content fits 320/390 CSS pixels and actual 200% zoom.

**Alternative.** The UX retrospective’s Goals-to-Evidence handoff aids continuation from saved goal to rule authorship. It may help first-time operators more. Neither option has comprehension evidence; choose by observed value, not report count.
