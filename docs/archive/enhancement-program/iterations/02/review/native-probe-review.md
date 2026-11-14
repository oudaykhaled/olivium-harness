# Native probe read-only preflight

Scope: static review of `tmp/enhancement-program/02/browser/native_probe.exs` against the installed Phoenix LiveView/telemetry source. No Mix, application, browser or probe was run; no source was changed. Root was notified before native execution.

## Concrete finding corrected

The original `status` branch checked `profile["name"]`; `Company.get_profile/0` returns a DTO whose company name is under `profile["payload"]["name"]` (`company.ex:19`, `evidence/store.ex:29`). That produced a false-negative `profile_has_reset_canary` even if the canary had persisted. Root corrected the harness to `get_in(profile, ["payload", "name"]) || ""`; the correction was observed during this review. Boolean-only status output avoids printing the name or other form data.

## Telemetry and ordering

Installed `deps/phoenix_live_view/lib/phoenix_live_view/utils.ex:350` emits `[:phoenix, :live_view, :mount, :stop]` with the mounted `metadata.socket`. Installed telemetry invokes handlers in the publishing process. Therefore the callback's `self()` identifies the LiveView channel, and filtering `socket.view == HarnessForgeWeb.PortalLive` plus `connected?/1` excludes disconnected HTTP renders. The registry retains only PIDs and filters dead processes; suspension refuses anything except exactly one live Portal.

The harness checks the configured workspace root equals expanded `tmp/ui02` and `PORT` equals `8868`. These are launch-configuration guards, not an independent measurement of the listening socket. Start the dedicated process with those settings and attach the browser only after the ready marker; an already mounted Portal predating telemetry attachment will not be discovered. If launched through Mix, application startup must not precede those guards unintentionally.

The fixed `:company_cache_reset` atom matches `PortalLive.handle_info/2`. `:sys.suspend` completes before the harness sends that atom and emits its ready marker. A real CUA form submission performed after that marker and before resume is the intended old-DOM serialized request, with reset queued ahead of that submission. Other messages may already be queued; the harness reports only their count and never their contents. Do not describe this as an empty mailbox or a test of every possible race.

Manual resume and EOF attempt to resume every registered live Portal with a five-second timeout and catch exits. The 45-second watchdog supplies bounded automatic recovery. A test that hits that timeout must report automatic resume, not manual queued-order evidence.

## Additional corrections verified before native execution

1. **Overlapping watchdogs prevented.** A manual resume does not cancel that cycle's watchdog, so the original harness could resume a later suspension early. Root added QA-only process state permitting at most one suspension per launch. The second request is refused, eliminating the later-episode overlap. This correction was read back from the harness.
2. **LiveView debug logs suppressed.** Installed LiveView `logger.ex:70–87` uses `inspect(session)` for connected mount logging, and `lv_handle_event_start/4` logs filtered event parameters; `filter_parameters` alone does not protect that session inspection. Root added `Logger.configure(level: :warning)` before `Application.ensure_all_started/1`, telemetry attachment and browser mount. This correction was read back. The probe's own output remains booleans/counts/fixed markers and does not log credentials, session, PID state or serialized form payloads.

No unresolved blocker was found in this bounded static review after those corrections. The native probe exercises the **real reset handler and real client event queue** through an actual CUA-serialized form. It does **not** perform a successful privacy purge or restore; their success-to-reset wiring is covered separately by the focused LiveView tests, including the backup/quarantined-restore test at `company_builder_test.exs:754`. This review did not run those tests or the native probe. A passing DOM reset, stale-submit refusal and application acceptance still require root's actual actions and recorded results.
