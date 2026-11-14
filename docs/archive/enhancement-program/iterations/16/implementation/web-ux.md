# Iteration 16 WEB UI/UX unit A

Status: source authored and frozen for Root integration checks. This is a bounded presentation change; no local runtime, test, browser, provider or database command was run by this author.

## Implemented

- `Guide.workflow/1` now presents its existing saved-state next action before the optional native `company-guide-details` checklist. The summary `company-guide-details-toggle` and every existing task/action ID, event generation attribute and explicit project selector remain. Workspace review counts, selected exact plan and its blocked preflight, and the assessment action stay visible outside the disclosure. The guide's projected eligibility and `Guide.project/1` output are unchanged. Assigned-source count is no longer implied to be a corpus prerequisite in the guide scope line.
- The existing analysis disclosure is labelled **Manual analysis · 2–4 selected sources**. Its selected/assigned counts and exclusion warning explicitly describe this manual path. Error, pending state, locked selection, saved recommendations and edits remain in the same component.
- Plan handoff copy says current eligible exact approved claims are selectable, corpus claims need no manual source assignment, and saving creates a proposed plan requiring a separate exact decision. The empty state no longer instructs operators to assign sources for a corpus claim. `claim_in_scope?/5` is unchanged.
- Package name has `maxlength="64"`, concrete slug help at `company-plan-name-help`, and a conditional inline alert at `company-plan-name-error`. Only `%{section: "plan", field: "name", message: text}` sets the name error. The input always describes the help and additionally describes the error when present; `aria-invalid` is true only then. The generic plan form error is suppressed for this one field error, while other form errors keep their existing presentation. No browser `pattern` or silent name normalization was added, so the server can show the measured inline recovery.

## Interface and preservation

Root B's shared pure `Validation.plan_name_valid?/1` delegates to the existing 64-character slug rule and supplies the optional field error, plan-section opening and focus on `company-plan-name`. Unit A consumes that exact optional map only. The source edit adds no event, authority decision, project selection, model dispatch, or persisted state. Existing corpus v2 exact project/profile/goal eligibility remains intact even with zero manual assignments; the legacy manual path retains its 2–4 source rule.

## Author checks and handoff

I reviewed the changed source ranges and the existing section/event/validation interfaces; the bounded read audit is `tmp/enhancement-program/16/implementation/web-ux-read-audit.json`. The source files are currently untracked in this checkout, so an ordinary `git diff --check` returned no meaningful patch; Root's actual compile, format, focused tests, canonical suite and browser journey are the verification gates. No claim of runtime or accessibility qualification is made here.

Frozen pre-format SHA-256:

| File | SHA-256 |
|---|---|
| `lib/harness_forge_web/components/company/guide.ex` | `f753093412e85566672c6131f808b38f34165c4c91196f54632a64a8d43579e1` |
| `lib/harness_forge_web/components/company/analysis.ex` | `57a5b3d86a57adf298acb30981a3c2f5aadd5e457307ec63147d6d2325d7ce3a` |
| `lib/harness_forge_web/components/company/plan.ex` | `bb0cea906f28a8fcd1e592b300b928e718ee175cf35f1643b0a17d0276197c71` |

Root should verify native details keyboard operation, name help/error association and focus, field retention after invalid submit, 390px and 320px overflow, and separate plan approval in the connected WEB journey. Source-review or check findings may require a subsequent bounded revision and new freeze hash.
