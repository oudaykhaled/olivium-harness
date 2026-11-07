# 05 proposal: explicit goal-origin rule authority

**User/job/hypothesis.** A company operator needs to turn a selected goal into a normative rule with accountable approval, even without a supporting source passage. Success is one approved goal rule built, exported and traceable to its pinned goal without fabricated citations. Admission of an unapproved or changed rule falsifies the hypothesis. Company task quality remains unmeasured; official progress is 4/50.

**Code basis.** `Company.resolve/1` pins goal hashes and validates cited claims (`company.ex:245-273`); claims require citations (`evidence.ex:288-314`); emitted rules have `goal_id: nil` (`harnesses.ex:180-195`). `Contracts` permits an explicit goal instead of evidence (`contracts.ex:299-319`). Build/export recheck inputs (`harnesses.ex:9-25,132-169`).

**ADR proposal.** Add immutable goal-rule revisions `{text, goal_id, goal_content_hash}` and separate append-only exact-revision operator decisions. Add goal-rule refs to a versioned plan payload; resolve current approved revisions within workspace and selected goal scope. Include basis and revision in snapshot and artifact. Recheck approval, goal hash and binding at build/export; withdrawn, superseded, purged or restored authority stays ineligible. Preserve cited-claim contracts and historical artifact bytes. Goal selection grants no approval; historical task identity grants no current authority. Root owns shared schema, migrations, privacy lifecycle and integration; authors may own goal-rule API and tests/UI. Risk: legacy plan compatibility and purge/restore require exact fixtures.

**Alternatives.** Conflict admission addresses contradictions but leaves uncited policy absent. Trusted route identity improves qualification but cannot authorize policy. Implicit goal-to-rule mapping reduces steps but incorrectly grants authority on selection.

**Acceptance.**

- Given a selected current goal and separately approved exact goal-rule revision, when the approved plan builds and exports, then the rule carries its pinned goal basis and no fabricated citation.
- Given missing, rejected, foreign-workspace or superseded approval, when plan approval, build or export is attempted, then admission refuses with a specific reason.
- Given a changed goal hash or purge/restore of a dependent authority, when rebuilding or exporting, then the dependent binding is ineligible; an unrelated cited-only legacy artifact remains verifiable.
