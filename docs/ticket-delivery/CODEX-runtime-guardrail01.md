## GUARDRAIL BRIEF — Execute the exported Codex harness through existing isolation

**Classification:** Additive runtime adapter/evaluation backend · Root execution after safe R01 checkpoint · no new runner engine.

**Verdict:** PROCEED-WITH-CONDITIONS. The observed Codex blocker is missing implementation, not demonstrated missing credentials.

**Guardrails that apply (ranked):**
1. [coding.ex:116–224,535–562,638–677; evaluations.ex:405–427,584–586] Extend the existing Coding/CodingTransport/Relay lifecycle with explicit target-specific admission, configuration, image/version and command handling. Current code reads opencode.json, starts an OpenCode image and admits only OpenCode tasks. Preserve sibling OpenCode behavior; never merely relabel registry availability or bypass the non-OpenCode guard. Pin/verify the Codex CLI image and effective configuration before execution; a renderer’s listed CLI version is not runtime qualification.
2. [coding.ex:3–8; docker.ex:162–174] Execute generated/model/target code only inside verified confinement: nonroot, bounded resources/output/time, read-only root, approved read-only artifact mounts, disposable writable candidate, no host home/socket/network or arbitrary command/image inputs. Keep protected grading isolated from candidate access. Bind actual exported bytes/digest and any necessary runtime overlay separately; no silent harness substitution or installation/execution on the host.
3. [runtime.ex:16–114; configuration.ex:73–110; relay_plug.ex:17–25] Existing authorization covers bounded isolated local real-agent work; reuse the selected local Ollama route and durable Ledger. Paid/cloud execution is not authorized; no login/credential harvesting or automatic fallback. Actual configured model/service/images were not inspected: model=nil is only the code default. Root must verify selected local model, supported Docker transport and pinned images without turning a missing backend into a credential request. Relay currently accepts chat-completions only: verify Codex’s required protocol and add a bounded compatible adapter through the same metered authority, never direct unmetered provider access.
4. [runtime.ex:53–98,118–144; coding.ex:188–223,1068–1085] Preserve exact eligibility, R01 use holds, source grants/consent, final-send and post-response currentness, reservation/reconciliation, cancellation and cleanup. No provider I/O under SQL/privacy fences. Uncertain usage, failed cleanup or changed configuration prevents PASS/qualification.
5. [User scope] First prove actual isolated agent output and tests. Then compare harness/no-harness runs with the same task, fixture, model, environment, limits and grading; record outputs, failures, usage and elapsed time. One success proves neither improvement nor company fitness; release admission remains separate. PIXEL_TAINTED screenshots remain restricted: use permitted capture or state the exact limitation, never reset/bypass it.

**Definition of done:**
- [ ] Root demonstrates WEB-triggered exact Codex artifact execution, observed output/test results, cancellation/revocation and verified cleanup.
- [ ] Paired evidence supports only measured benefit; existing OpenCode checks remain valid.

**Knowledge base:** Unchanged. Exact source ranges/hashes audited; no runtime/provider/configuration inspection, tests or product changes performed.
