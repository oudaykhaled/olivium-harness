# A03-01 Home continuation contract 03

Decision: ACCEPT a six-file, read-only continuation slice. Existing owner-scoped services suffice; no mandatory backend prerequisite is missing. This is a proposed implementation contract, not runtime acceptance. Guardrail02 conditions apply. No persistence, authority inference, new consent, schema, API framework or protected pixels.

## Identity and routing

Fresh Home: zero rows preserves existing guidance; one row offers “Resume saved setup”, explicitly described as the only saved record; multiple rows offers “Choose saved setup” leading to existing `/setup`. Never select the list head. List is bounded to 20; describe displayed counts as bounded.

Use `/?setup=<UUID>` as an optional exact address. Preserve existing `setup=company|connections|goals` tab links and `company_review` precedence. UUID selects Company Home and passes `home_setup_id`; absent selector clears it. Invalid nonlegacy values yield invalid-selector state, never fallback to another record. Exact lookup works outside the list page. SetupLive’s existing Return to Home link includes only its successfully loaded saved UUID; otherwise `/`. This preserves identity across reload/restart, not a current-workspace preference. Destination always reloads authoritative saved step/version; query never grants authority.

## Flat seam and reads

Portal passes `home_setup_id` (nil/validated UUID), `home_setup_invalid` (boolean), and existing workspace/session/reset context. CompanyPanel produces a string-keyed `home_resume` map:

`state` = empty|choose|selected|unavailable|invalid; `origin` = none|sole|explicit; `id`, `version`, `step`, `updated_at`, `reference_status`, `run_id`, `run_version`, `run_phase`, `failure_code`, `requests_reserved`, `pending_requests`, `uncertain_requests`, `tokens_accounted`, `cost_microusd_accounted`, `predecessor_uncertain_requests`, `history_partial`, `error_code` (nullable scalars).

Use SetupSessions.list(%{}, caller), get(%{"id" => id}, caller), SetupRuns.get(id, caller), with existing workspace/owner authorization callback and generation/reset binding. Copy only listed metadata; map reference_status from its status scalar, run_id from run_ref.id. Discard full payload immediately: no draft, selection, config, prepared disclosure, prompt or raw error rendering/logging. No run means null run fields, not a completed run. Preserve unknown accounting as unknown; predecessor uncertainty is the returned page sum, explicitly partial when history_cursor exists; never invent historical totals.

Require SetupRuns response.id == selected id and response.session_version == setup.version. Any failure/mismatch clears the entire summary to unavailable; no mixed snapshots, silent retries or fallback selection. Refresh redoes reads. Clear on privacy/reset/revocation and rotate existing event generation on selector change. Session/version equality proves observation consistency, never future eligibility.

## Selector, events and priority

Guide remains pure and renders exactly one primary. Priority: existing global unavailability; saved-setup invalid/read failure (Refresh saved setup); existing explicitly selected-plan guidance including preflight recovery; selected setup; multiple-row chooser; existing zero-row guidance. Selected summary shows exact identity/version/step, reference status and run recovery/accounting. References stale/unavailable or run blocked/expired/cancelled use “Review saved setup recovery”; otherwise “Resume saved setup”. Describe cancelled/expired as requiring explicit recovery in SetupLive. Readiness and completion flags remain unchanged.

Keep `company_setup_open` with generation-only payload for chooser. Add `company_setup_resume` and `company_setup_refresh`, also generation-only: server resolves cached identity, never accepts client id/step/version. Resume reauthorizes get before sending `{:company_inspect_setup, id}`; Portal repeats auth/workspace and assessment-dirty guards, reauthorizes get and constructs `/setup/:id/:saved_step`. Company draft guards apply before navigation; refresh cannot discard local drafts. Invalid/stale envelopes have existing refusal precedence. Unauthorized redirects login; invalid/not_found/unavailable remain distinct internal codes but disclose no foreign metadata. Refresh leaves an invalid URL invalid; chooser provides recovery. Disconnected controls remain disabled. No command/capture/grant/retry/new-run calls.

## Ownership and acceptance

Engineer A: company_panel.ex + company/guide.ex. Engineer B: portal_live.ex + setup_live.ex. Root: company_home_next_action_test.exs + setup_entry_test.exs, integration and all execution. No overlapping edits, new modules or router changes.

Tests prove zero/one/multiple, exact non-newest/off-page selection, legacy query compatibility, invalid/foreign/deleted IDs, restart/remount identity, saved-step authority, mismatched versions, nil run, cancelled/expired plus unknown/predecessor usage, redaction and privacy clearing, selected-plan precedence, Company/assessment dirty refusal, stale generation, disconnected controls, exactly one primary and unchanged command/model/approval counts. Root runs focused tests then canonical suite and the authorized real returning journey. Fixture evidence alone cannot close A03-01.
