# Company handoff — frozen source review 01

**Verdict:** source review complete; no product blocker identified. This is not release approval. Ticket-driven steering supersedes the historical round/retrospective schedule. No tests, application, database, browser, provider, or generated target code were executed by this reviewer.

**Blocking:** no new product finding. Root reports focused02 completed with 81 tests and two failures: the new LiveView fixtures add a milestone before selecting its goal, so form validation rejects the test input before product submission. Frozen `test/harness_forge_web/company_journey_handoff_test.exs:121–123,188–189` reflects that ordering. Root has assigned the original author to correct ordering without weakening assertions. That correction and a passing rerun remain verification prerequisites; neither has been independently inspected here.

**Non-blocking — NB1:** `test/harness_forge_web/company_journey_handoff_test.exs:142,160` checks only milestone IDs after name rejection and successful save. A regression replacing title, acceptance, evaluation method, target version, or goal/dependency selections while retaining `id` would pass these assertions. Compare the entire retained and persisted milestone against the submitted row, accounting only for documented ordering. The current product code at `company_panel.ex:1200–1207` retains these fields; this is a regression-coverage gap, not observed data loss.

**Nit:** none.

**Praise / substantive checks:**

- `validation.ex:37–75,142–157`: the public pure predicate delegates to the existing bounded slug rule. Domain payload/error semantics remain unchanged, including no trimming or case conversion. Boundary and non-string tests exercise both predicate and domain validation.
- `company_panel.ex:235–255,619–638,926–956`: authentication, generation and shape checks precede draft capture; `plan_input` precedes name validation; valid names still reach existing domain authority. Only the tagged name error is cleared by plan edits. Name rejection opens the plan section and targets the associated input. Exact plan approval remains a separate event at 701–707.
- `plan.ex:33–37,117–146`: help/error association and `aria-invalid` follow the tagged field error, without duplicated generic rendering or a client pattern blocking server recovery. Existing draft normalization retains reviewed identities/settings. Project-change clearing remains unchanged.
- `guide.ex:326–422`: next action precedes the native saved-steps disclosure; current selected-plan identity and blocked preflight stay outside it. `analysis.ex:188–285` localizes assignment counts/exclusions to the manual route. Baseline comparison confirms both v2 eligibility predicates and existing error/pending/review behavior are unchanged.

Across correctness, security, performance, tests, observability and operability: no new query, external call, dispatch, migration, dependency, logging boundary, or approval path was introduced. The additional validator is bounded and pure. Actual keyboard focus, disclosure behavior, narrow layout, connected corpus authority, and final CI/check results remain Root verification responsibilities.

**Frozen SHA-256** (paths are the manifest's seven `snapshot_files`; full paths and ranges are in the audit):

| Source | SHA-256 |
|---|---|
| company/validation.ex | f8c8ff2ef4579d5b7ff1ad12366cb4cd60610f8d6a21557e282525051a9fbd24 |
| company_panel.ex | 809e36edc9d1593459eb7896d04d16d97303cfec5bdf97c52ea0753735c88e47 |
| company/guide.ex | f753093412e85566672c6131f808b38f34165c4c91196f54632a64a8d43579e1 |
| company/analysis.ex | 57a5b3d86a57adf298acb30981a3c2f5aadd5e457307ec63147d6d2325d7ce3a |
| company/plan.ex | fae522358ee88905e18458f1f6a8be49333c44daf79bf671ca92ac0258f04604 |
| company_plan_name_validation_test.exs | e1a768e2de135120794def76261f8a3b312738da42660c51dc6b7951890fd254 |
| company_journey_handoff_test.exs | ef6af4676430e00e816d979285441f818007da22db8df33accbfa18d6b89de12 |

**Read audit:** all 4,106 candidate lines consumed, plus five baseline unified diffs. All 367 manifest entries were metadata only. Initial combined-output truncation was repaired by bounded rereads of decision, manifest and checklist material. No linked-path traversal or protected/private source content was read. Exact ranges, hashes and limitations: `tmp/ticket-delivery/reviews/company-handoff-source01-read-audit.json`.
