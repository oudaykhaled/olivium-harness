# Planning citation resolution

The 16 original proposals remain frozen at their final-review fingerprints. Of 23 Markdown local targets, 15 do not resolve: eight in planner05 and seven in planner12. This appendix supplies the actual existing sources; it does not change the original reports or their provenance. Planner05 explicitly confirmed the cited repository files and full05/06 handoffs were read. Astra independently read relevant current code and the full original material. The reports’ repo-relative source labels identify the intended files.

| Original report | Broken target | Actual evidence |
|---|---|---|
| 05-portable-authority.md | `../../../../lib/harness_forge/decisions.ex` | [lib/harness_forge/decisions.ex](../../../../../lib/harness_forge/decisions.ex) |
| 05-portable-authority.md | `../../../../lib/harness_forge/company.ex` | [lib/harness_forge/company.ex](../../../../../lib/harness_forge/company.ex) |
| 05-portable-authority.md | `../../../../lib/harness_forge/harnesses.ex` | [lib/harness_forge/harnesses.ex](../../../../../lib/harness_forge/harnesses.ex) |
| 05-portable-authority.md | `../../../../lib/harness_forge/artifacts.ex` | [lib/harness_forge/artifacts.ex](../../../../../lib/harness_forge/artifacts.ex) |
| 05-portable-authority.md | `../../../../docs/mcp.md` | [docs/mcp.md](../../../../../docs/mcp.md) |
| 05-portable-authority.md | `../../../../lib/harness_forge/privacy/snapshot.ex` | [lib/harness_forge/privacy/snapshot.ex](../../../../../lib/harness_forge/privacy/snapshot.ex) |
| 05-portable-authority.md | `../../../../test/harness_forge/privacy_test.exs` | [test/harness_forge/privacy_test.exs](../../../../../test/harness_forge/privacy_test.exs) |
| 05-portable-authority.md | `../handoff-to-07.md` | [docs/enhancement-program/iterations/06/handoff-to-07.md](../../../../../docs/enhancement-program/iterations/06/handoff-to-07.md) |
| 12-goal-evaluation.md | `../../../../test/harness_forge/goal_claim_admission_test.exs#L62` | [test/harness_forge/goal_claim_admission_test.exs](../../../../../test/harness_forge/goal_claim_admission_test.exs#L62) |
| 12-goal-evaluation.md | `../../../../lib/harness_forge/execution/coding.ex#L761` | [lib/harness_forge/execution/coding.ex](../../../../../lib/harness_forge/execution/coding.ex#L761) |
| 12-goal-evaluation.md | `../../../../lib/harness_forge/evaluations.ex#L109` | [lib/harness_forge/evaluations.ex](../../../../../lib/harness_forge/evaluations.ex#L109) |
| 12-goal-evaluation.md | `../../../../lib/harness_forge/harnesses.ex#L148` | [lib/harness_forge/harnesses.ex](../../../../../lib/harness_forge/harnesses.ex#L148) |
| 12-goal-evaluation.md | `../../../../lib/harness_forge/execution/coding.ex#L108` | [lib/harness_forge/execution/coding.ex](../../../../../lib/harness_forge/execution/coding.ex#L108) |
| 12-goal-evaluation.md | `../../../../lib/harness_forge/models/configuration.ex#L92` | [lib/harness_forge/models/configuration.ex](../../../../../lib/harness_forge/models/configuration.ex#L92) |
| 12-goal-evaluation.md | `../../../../lib/harness_forge/evaluation/task_suite.ex#L1` | [lib/harness_forge/evaluation/task_suite.ex](../../../../../lib/harness_forge/evaluation/task_suite.ex#L1) |

The separate planner05 `../../05/handoff-to-06.md` link resolves correctly and is not listed. Its `../handoff-to-07.md` link resolves into iteration07 and is corrected above to the original iteration06 handoff. Plain source citations in other proposals are repository-relative references, not Markdown navigation claims. No live runtime behavior or test pass is established by this path validation.
