# Iteration 16 Company handoff tests — author C

Status: authored and frozen for Root execution; no runtime, database, browser, provider, or test command was run by this author.

The two new public synthetic test modules cover the selected handoff without changing product authority:

- `company_plan_name_validation_test.exs` exercises the exact 64-character lowercase slug boundary, 65-character rejection, spaces, uppercase, punctuation, blank and non-string values. It checks that `Validation.plan/1` still returns `{:error, :invalid_input}` and retains its successful payload shape. The assertions use examples and boundary values, not a copied regex.
- `company_journey_handoff_test.exs` checks a clearly labeled pure `Guide.project/1` projection fixture for v2 claim eligibility with zero manual assignments and rejection after a project hash change. This does **not** establish `Evidence.approved_claims/0` authority or real corpus provenance; Root's connected browser journey is the authority check. A separate saved WEB guide test checks corpus next action ahead of native optional steps and manual alternative wording.
- The persisted WEB plan case uses a real local synthetic source, saved goal, approved exact claim, profile, repository and project. A spaced name must produce an associated inline alert and name focus, preserve all submitted project/repository/claim/goal/preset/runtime/execution/milestone choices, and persist no plan. Correcting only the name must create a proposed plan with the same exact inputs. A separate plan decision changes it to approved; the approved claim alone does not.
- Project switching clears dependent plan choices. A captured old event generation cannot restore the prior project or save a plan after reset.

The tests intentionally leave actual corpus retrieval, exact v2 manifest validation, export bytes, task evaluation, focus by keyboard, and responsive layout to Root's specified connected verification. Their assertions do not convert a scripted fixture or pure projection into semantic/model/novice qualification.

Root should run focused ExUnit on these two exact paths after all authors freeze, then the contract's broader gates. Any failure needs an observed command and output before a test or product correction. No execution result is claimed here. The companion read audit records exact consumed ranges, a repaired display truncation, and current dependency hashes; hash records alone do not establish full semantic consumption or effective model identity.
