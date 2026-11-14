# Acceptance and testability: export recovery

**Recommend Packages export recovery.** Iteration05 observed a prior direct-build alert beside successful export; its cause is unknown ([verification](../../05/verification.md)). `PortalLive` stores only `export_path`; success adds generic flash without clearing older error (`portal_live.ex:36,432–443,1288–1292,1974–1976`). Failure uses `finish/3`, without field focus (`:736–741`); artifact errors fall through generic copy (`:1162–1169`). The goal journey checks successful files and `#export-result`, but no failed retry (`goal_claims_test.exs:128–139`). `Artifacts.export/3` rejects invalid targets and checks absence before and after staging (`artifacts.ex:62–69,104–116,245–255`).

**Unit/owner:** Web author owns Packages form, export handler, scoped result/error state and focus in `portal_live.ex`; root owns shared focus allowlist in `assets/js/app.js:115–130`. Result belongs to `{digest,target,attempt}` inside its package row. Success identifies exact digest/destination and supersedes only that package’s export error; unrelated actionable failures remain.

**Acceptance:**

- Positive: fresh contained export confirms digest/path; keyboard reaches the result; bytes match the immutable artifact.
- Negative: occupied, invalid, missing-parent and permission-denied targets show the *classified* remedy at the input, preserve entered path, focus correction, and leave bytes untouched. Failed attempts show no success.
- Edge: retry success replaces its error; package switching hides other results. Purge/restore, lock, remount and stale event clear private target/result state; quarantine remains ineligible. Preserve exact approvals and [03 command-free abstention](../../03/decision-amendment.md).

**Independent proof:** LiveView tests drive failed→corrected retries, two-package switching and reset/revocation, asserting DOM, filesystem hashes and no overwrite. Root-owned native Chrome verifies keyboard focus/next Tab and intact form at 320/390 CSS pixels and real 200% zoom, with ordinary viewport images and widths. First-time operator recovery comprehension requires separate observation; copy/clicks alone do not establish it. Goals handoff requires observed goal→rule focus with zero implicit selection/claim; notices require ownership across alert-producing actions. Neither substitutes for export retry proof. Retain 05’s clipping, no-op click, stale alert and inconclusive login; claim no human-study or WCAG result.
