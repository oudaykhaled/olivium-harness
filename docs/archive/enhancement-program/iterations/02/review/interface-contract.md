# Iteration 02 interface freeze

Status: ready for three authors; implements the root-accepted [decision](../decision.md) and [guardrail brief](guardrail-brief.md). Elixir 1.19.5 / OTP 28, Phoenix 1.8.16, LiveView 1.2.13; no dependencies, schema or domain changes. This is an internal component contract, not a network API.

The root-accepted [v2 admission decision](admission-decision.md) supersedes this document's event-envelope portion: every Company event requires its current per-mount/reset `company_event_generation` before payload normalization or dispatch. Numeric DOM reset and ordinary refresh generations remain separate.

## Ownership

| Author | Exclusive files |
| --- | --- |
| A · Principal Elixir | `lib/harness_forge_web/components/company_panel.ex`; new `components/company/guide.ex` |
| B · Expert UI/UX | `components/company/catalog.ex`, `components/company/plan.ex`, `assets/css/app.css`, `assets/js/app.js` |
| C · Principal Elixir | `lib/harness_forge_web/live/portal_live.ex`, focused `test/harness_forge_web/company_builder_test.exs` additions/integration |

Component paths abbreviate `lib/harness_forge_web/`. Root alone owns board/state, shared configuration/router/application/migrations and native Chrome. Preserve others' edits; conductor serializes Mix. B preserves existing JS listeners and colocated hooks.

## Assigns and helpers

C keeps `company-builder` unconditionally mounted; `active` controls its existing `hidden` attribute. Existing inputs remain. Add `claim_review_count` (integer ≥0, **nil** when claims loading failed), `data_errors` (existing list of loader-name strings), `company_reset_token` (integer, initially 0), and `company_refresh_token` (server-owned integer incremented once per parent reload). The ordinary refresh token forces the child update when unchanged parent evidence would otherwise let LiveView skip it after a catalogue/plan mutation. It never changes the privacy generation or clears drafts. Count proposed, non-superseded claims from existing loaded records; A counts equivalent plans from its own list. Both counts say workspace-wide. No duplicate parent plan query.

A owns `open_sections` (MapSet of fixed names below), `profile_draft`, `repository_draft`, `project_draft` (map or nil meaning pristine), `form_error` (nil or `%{section: name, message: text}`), `guide_project_id` (saved ID or nil), and `plan_preflight` (`:none`, `:eligible`, or `{:blocked, reason}`). Existing `plan_draft`/`selected_plan` remain. On reset only profile starts expanded.

A passes these additional attrs to B: `Catalog.setup`: `profile_draft`, `repository_draft`, `project_draft`, `open_sections`, `form_error`; `Plan.builder`: `open_sections`, `form_error`, `plan_preflight`.

A supplies `Guide.section(name, title, open, target)` with required `inner_block` slot. B wraps the seven existing sections with it. Keep forms mounted inside hidden content; never conditional-render a closed form. Toggle IDs are `company-toggle-{name}`, content IDs `company-section-{name}`. Existing section IDs remain:

| Name | Section ID | Open/focus destination |
| --- | --- | --- |
| profile | company-profile-step | company-profile-name |
| repository | company-catalog-step | company-repository-identity |
| project | company-project-step | company-project-name |
| evidence | company-evidence-step | company-review-evidence |
| plan | company-plan-step | company-plan-name |
| review | company-plan-review-step | company-plan-review-step |
| build | company-build-step | company-build-step |

Non-input destinations receive `tabindex="-1"`. Toggle buttons expose `aria-expanded` and `aria-controls`.

## Events, drafts and focus

Existing event names/payloads remain. Add:

| Event | String-keyed payload | Effect |
| --- | --- | --- |
| company_section_toggle | `%{"section" => name}` | Toggle fixed section; closing returns focus to toggle. |
| company_guide_open | `%{"section" => name}` | Open and focus destination above. |
| company_guide_project_change | `%{"guide" => %{"project_id" => saved_id}}` | Change guide scope only. |
| company_profile_change | `%{"profile" => attrs}` | Capture profile draft. |
| company_repository_change | `%{"repository" => attrs}` | Capture repository draft. |
| company_project_change | `%{"project" => attrs}` | Capture project draft. |
| company_draft_discard | `%{"form" => name}` | Reset only profile/repository/project/plan draft explicitly. |

Validate fixed names and existing bounded scalar/array shapes; keep `_unused_*` transport handling and pinned original `expected_content_hash`. Do not atomize input. Capture valid submission values before domain calls. Failed saves preserve drafts; success resets only its form. Refuse edit/new/successor actions that would overwrite a dirty draft, showing explicit discard guidance; allow reselecting the same edited record without replacement. Discarding a plan draft preserves its selected immutable plan.

Failed submissions open the affected section and set `form_error`; B renders `company-{name}-error`, focusable with `tabindex="-1"`, within that form/review region. Use known reason messages; generic failures receive no invented field diagnosis. Typing never requests focus.

Server emits `company-focus` with `%{id: fixed_id}` after destination state is rendered. B adds a minimal `phx:company-focus` listener using `getElementById` and next-frame focus, allowing only the table destinations, seven toggle/error IDs, and `company-guide-project`, `evidence-panel`, `connections-panel`, `goals-panel`, `package-panel`, `evaluations-panel`, `releases-panel`. C's existing `company_navigate` message changes tab, then focuses its panel (`tabindex="-1"`). Never accept arbitrary selectors/scripts from input.

## Scope and admission

Guide scope resolves explicit `guide_project_id`, else selected plan's saved project, else the sole saved project; multiple without selection prompt a choice. Selecting a plan sets guide scope to its project. Guide changes never mutate `plan_draft` or `selected_plan`; draft project fields never establish saved completion. Show the selected exact plan's identity/lifecycle independently if guide scope differs.

The pure guide uses saved profile/project memberships and approved claims whose citations all belong to current captured revisions assigned to that project or company. Goals/milestones are optional. Loader failure is unavailable, never completion/zero. Multiple plans require explicit exact selection.

Only selection/saved-data reload may call existing `Company.build_inputs/1` for the selected approved plan, once and outside render. Clear prior preflight first; failure/unavailable never retains eligibility. Existing decide/build/export admission remains authoritative. No `Admission` module exists to introduce: reuse these functions. Proposed staleness surfaces the existing approval refusal. A proposed successor does not revoke an eligible approved predecessor.

## Reset lifetime

C increments reset token after successful restore/source purge/workspace purge and broadcasts fixed `:company_cache_reset` via `Phoenix.PubSub.broadcast_from` on the existing workspace topic. Sibling Portal handlers increment and reload. Backup, ordinary refresh/tab trips and harmless validation failure preserve drafts. Restore remains a fresh quarantined target; it does not switch/import authority into this workspace.

A compares reset token **before reading old state or reloading**. Clear loaded profile/repositories/projects/plans, all drafts/edit records/hashes, selection/preflight, built artifact/diff, search/consumer data, guide scope and notices/errors, then load fresh saved data. Failed fresh loading cannot resurrect caches. Incomplete privacy/admission failure invalidates previous preflight. Invalid auth clears cached state before redirect; existing logout epoch broadcast/revocation terminates mounted components. No browser storage or cross-session draft promise.
