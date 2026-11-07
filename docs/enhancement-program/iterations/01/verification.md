# Iteration 01 verification

Status: complete. Implementation, independent validation, five independent retrospectives and the next-iteration handoff are stored. Final completion record: `tmp/enhancement-program/01/iteration-result.json`; the earlier accepted-evidence manifest is preserved as the pre-retrospective snapshot.

Delivered a first-party read-only MCP endpoint in the existing Phoenix owner process. The three tools search company capabilities, inspect exact plan readiness and inspect verified/current package eligibility. MCP is disabled by default and uses a separate operator-configured environment-referenced bearer. No v1alpha1 bytes, authority or workspace-lock semantics changed.

| Evidence | Observed result | Limit |
| --- | --- | --- |
| Planning | 16 Sol planners and one Astra decision maker; actual 16-participant concurrent review snapshot | Initial proposal work overlapped; some were reactivated for final review, explicitly recorded |
| Author focus | 86 passed, zero failed, seed0; 33 new tests | Synthetic fixtures |
| Independent canonical | 403 registered,388 passed,zero failed,15 existing Docker skips,seed0,44.910121seconds | Coverage unmeasured |
| Format, compile warnings-as-errors, CI Credo warning gate | Passed independently | Broad strict style scan is not the CI gate |
| Dialyzer | Exit2, exactly existing releases.ex47/121 opacity diagnostics | No clean type-analysis claim; four new diagnostics fixed without suppression |
| Native build and synthetic provisioning | Exit0; separate candidate directory | Existing main8865/QA8866 installations/workspaces preserved; no distributable publication claim |
| Native disabled default | MCP HTTP404 while portal login available | Explicit enablement required |
| Official MCP SDK1.29.0 / Node26.3.1 | Exit0,44 checks, pinned2025-11-25 profile | No newer protocol or model-driven Codex/Claude compatibility claim |
| Useful client journey | Exact3tools, capability match, proposed/rejected refusal, approved predecessor after successor, bound package integrity/current admission | Metadata/readiness only; no content-serving or mutation tools |
| Transport negatives | Bearer, Host/Origin, version, method, duplicate JSON, malformed IDs, batches, body limits | Peer/race/quarantine additionally covered in application tests |
| No mutation and minimization | Full DB row counts/content hashes and immutable artifact bytes unchanged; QA secret/source-body sentinel absent from responses and native log | Synthetic workspace only; clients retain received copies |
| Chrome portal coexistence | Authenticated candidate8867 and opened Company; DOM and screenshot saved | Existing long-form UI remains; this is a baseline for iteration02, no UI polish claim |

Evidence manifest with source/evidence SHA256 hashes: `tmp/enhancement-program/01/accepted-evidence.json`. Native SDK result: `tmp/enhancement-program/01/qa/native-client-result.json`. Independent full-suite result: `tmp/enhancement-program/01/regression/final/checks.json`. Browser baseline: `tmp/enhancement-program/01/browser/company-before-ux.png` and `company-dom.txt`.

Initial failures were retained. Source author tests found an unsupported SQLite DISTINCT ON query and a fixture Host-construction issue; both were corrected. Security review found a missing no-store header on an unexpected-exception path; the helper and throwing-adapter regression were fixed. Independent Dialyzer found four unreachable fallback clauses; they were removed while retaining outer safe exception boundaries. The first canonical attempt used a test workspace path too long for an existing Unix socket; the canonical short default rerun passed. The first native client attempt accidentally sent duplicate Host headers; the QA script was corrected to send a single hostile Host and the full run passed. None of these failed attempts was counted as success or hidden.

Remaining company reliability gaps include guided onboarding, selected live connector credentials/scopes, goal-origin rules and conflicts, portable approval provenance, managed coding execution and a real-model company pilot. Integrity/current admission remains separate from model quality and release qualification. Five independent retrospectives assessed these gaps; see `retro/` and `handoff-to-02.md` before iteration02 chooses its UI/UX scope.
