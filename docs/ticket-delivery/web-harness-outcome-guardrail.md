## GUARDRAIL BRIEF — Authenticated harness preview and ZIP outcome

**Classification:** Local Phoenix WEB/routes + read-only artifact delivery · additive · Root integration; no new authority or execution capability.

**Verdict:** PROCEED-WITH-CONDITIONS. No blocking questions.

**Guardrails that apply to THIS request (ranked):**
1. [router.ex:4–38; purge.ex:10–18,813; harnesses.ex:224–259] Authenticate BOTH preview and download under the existing operator session; resolve workspace exclusively from server context. On every page load/file event/download, use the existing purge fence, explicitly require `Purge.ready()`, read the selected artifact, and recheck current eligibility before disclosing bytes. Synchronization alone does not assert purge readiness. A digest, cached UI or previous successful read grants no authority. Fail closed on revoked/missing/unavailable inputs; no cached-body fallback.
2. [artifacts.ex:140–179; compiler.ex:33–45] Reuse `Harnesses.get/1`: its artifact read already performs Compiler.verify, requested-digest equality, safe-path and exact stored-payload verification. Preserve that checked result for both text and ZIP, never regenerate different files or read user-supplied paths. Link “Your harness” only to the digest actually returned by successful build; GET never builds, approves or executes anything.
3. [artifacts.ex:17,219–243] ZIP only verified `artifact["files"]` entries, using validated contained relative names and binary contents in memory. Do not include artifact store metadata, workspace files or credentials. Bound total bytes/entries before archive allocation; no disk export/shell invocation or user-controlled root/target. Set application/zip, safe digest-derived attachment filename and no-store; avoid an HTML-only accept gate rejecting legitimate download clients while preserving authentication/security headers.
4. [router.ex:35–38; AGENTS.md] Render filenames and generated text as escaped text, never raw HTML, executable Markdown or active downloads selected by arbitrary filesystem paths. Use bounded readable previews with explicit truncation when needed; ZIP preserves exact complete stored bytes. Avoid exposing internal paths or sensitive error payloads. Live pages must clear displayed bodies when existing session/privacy invalidation fires; subsequent events reauthorize.
5. [compiler.ex:2–9; AGENTS.md] Beside the files, distinguish generated artifact/current byte integrity and eligible exact decisions from representative-task success, semantic usefulness and release qualification. Show unavailable/unobserved honestly; synthetic/scripted workflow mechanics establish no real-model or end-to-end task benefit. Keep the default Company journey and prominent successful-build outcome focused on the user's files.

**Hard STOPs:** No paid inference, private imports, publishing, source/approval bypass, host target execution or automatic build on preview/download.

**Definition of done:**
- [ ] Actual build → preview → download path works; extracted ZIP names/bytes equal the verified artifact map.
- [ ] Unauthenticated, wrong-workspace, invalid/tampered/missing artifact and revoked/purge-unavailable cases disclose no payload; render hostile text safely.
- [ ] Root records focused checks and real browser evidence, with qualification limits visible.

**Knowledge base:** Unchanged. Exact ranges/hashes: `tmp/ticket-delivery/A02-browser/outcome-guardrail-audit.json`. No product/tests/runtime/boards modified or executed by this task.
