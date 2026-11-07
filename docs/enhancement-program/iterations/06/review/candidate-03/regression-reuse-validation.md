# Candidate03 independent regression reuse validation

**Bounded reuse APPROVED; corrected native acceptance remains pending.** Candidate03 reuses the actual candidate02 canonical **495 passes /0 failures /15 default Docker skips** and111 repeated focused passes. This assessment executed **zero new application tests and zero Docker checks**. The existing two unsuppressed Dialyzer findings remain the reused baseline; Dialyzer is not clean. No overall native/product acceptance is issued.

## Independent inventory and complete delta

Verified the exact anchors before interpreting their contents:

| Input | SHA256 |
|---|---|
|624-file source-freeze-03.json|`84fa45583c8674dcfda585ea38b6e91a1915c78dbf3ca4950a656399aa28fa48`|
|Seven QA references|`fd622058aadd14c820045b678f0747a60cbeea6714f06df8a23422dfe5360894`|
|Root02→03 reuse contract|`39aa8875e6346c21deac3da9ad23801d24f84b29784b6e90bcbb272e2e5219ad`|
|Original585-file source-freeze-02.json|`0d085726174b0e60e873aa1be5e2c7cc2d6c935805d5ab8cf492d7a749530e88`|

[Read-only audit](../../../../../../tmp/enhancement-program/06/independent-qa/candidate-03/readonly-reuse-audit.json) verifies every585 actual02 copy and624 actual03 copy, exact copied inventories without missing/extra files or symlinks, and all seven QA references. The independently derived **full**585→624 comparison has572 byte-identical common paths,13 changed common paths,39 additions and zero deletions. Exactly one changed common path is authored: `assets/css/app.css`. The other12 common changes and all39 additions are generated static/shipping files, explicitly enumerated in the [complete delta](../../../../../../tmp/enhancement-program/06/independent-qa/candidate-03/full-delta.json).

The [CSS diff](../../../../../../tmp/enhancement-program/06/independent-qa/candidate-03/css.diff) adds only `overflow-wrap: anywhere` to the existing `.artifact-row` rule. All surrounding source and the rule's other declarations remain identical. There is no selector, grid, domain, dependency, JavaScript or test change. Generated changes include prior02 bundled JS/metadata and packaged documents; they are not additional authored application changes.

The root reuse contract is independently complete: its572 declared unchanged paths exactly equal the independently derived572-path set, with no omission, extra or duplicate and matching actual copied hashes. Its12 generated-change and39 generated-addition lists also exactly match the complete inventory comparison. This assessment did not rely solely on the root's selected list.

## Exhaustive regression contracts

[Contract audit](../../../../../../tmp/enhancement-program/06/independent-qa/candidate-03/exhaustive-contract-audit.json) independently derives226 unchanged source/tooling contracts from both full inventories:

| Complete group | Verified paths |
|---|---:|
|All application library files|109|
|All test/support/browser/native files|66|
|All configuration files|5|
|All nonstatic priv files, including migrations/contracts/fixtures|26|
|All packaging files|11|
|All assets except the changed CSS|4|
|Launcher, formatter, toolchain and both Mix contracts|5|

The groups include all182 Elixir files and every file named by the actual510-case canonical reporter. All runtime/evaluation/adapter/model, approval/evidence/Company, privacy/purge/restore, operator/authentication/MCP, compiler/schema/template and command-free readiness contracts are covered by the exhaustive library/config/test sets. The application JS and changed-in02 browser smoke script are byte-identical to02. No test body, skip, timeout, selection, exclusion or suppression changed.

The CSS is outside the Elixir formatter/compile/Credo/Dialyzer inputs. Application/test/config/toolchain code remains identical, so a second application suite is not required for this isolated declaration. Its behavior must be demonstrated by freshly built assets and native reflow evidence.

## Reused actual execution and preserved history

[Candidate02 anchors](../../../../../../tmp/enhancement-program/06/independent-qa/candidate-03/candidate02-anchor-archive.json) archive the exact existing02 report/check index/canonical/focused/accounting/Dialyzer/Docker/end-audit files before this new report. The old report remains15980 bytes/SHA256 `554cadf89edcc57f7d72d29857736e17e130836ebbfcdd117619202bd3f8a99f`; no old report or frozen input was mutated. Every stdout/stderr size/hash for all12 original02 commands matches its retained check index.

| Original02 result reused | Exact meaning for03 |
|---|---|
|Canonical510 registered,495 executed/passed,0 failed,15 default skips|495 original executions on unchanged contracts; no fresh03 execution. All17 export cases remain, with no removed/duplicate/status-regressed case.|
|Focused111 passed|Repetitions of canonical cases; do not add111 to unique counts.|
|Full/packaging format, forced warning compile, CI Credo,44-dependency inventory, app/CJS syntax exit0|Original02 static checks reused for unchanged inputs. Source inventory is not a complete native/transitive SBOM.|
|Dialyzer exit2, `call_without_opaque` at `releases.ex:47:15` and `121:15`|Exactly two unsuppressed original baseline findings, zero new/skipped/unnecessary-skipped; no new03 run and no clean claim.|
|215 verified historical Docker contracts|All215 still byte-identical in03. Original05's15 guarded executions retain their time/environment and synthetic containment/protocol bounds. No fresh03 Docker command, metadata observation, daemon-availability result or pass.|

The broader former217-file Docker claim remains withdrawn because02 changed two UI test files. Only the explicitly narrowed215-file historical runtime assessment is reused. The canonical15 default skips stay visible. Original01's canonical failure, the author's red Audit regression and native02's actual clipping failure remain evidence; no corrected result rewrites those observations. Coverage and flake rate are unmeasured.

## Post-build source classification and retained audit failure

The first read-only attempt correctly failed its full-live-equality assertion: root's corrected build had already regenerated shipping files while review proceeded. [Attempt01](../../../../../../tmp/enhancement-program/06/independent-qa/candidate-03/attempt01-command.json) and its original script/stderr are retained. Its UTC start was not separately captured and is explicitly unknown; the tool's0.144719s duration and exit1 are preserved. It was a valid source-audit mismatch, not a failed application test, and was not relabeled as a full624-live pass.

Root confirmed the build ran19:07:58–19:08:03. The subsequent [independent post-build classification](../../../../../../tmp/enhancement-program/06/independent-qa/candidate-03/postbuild-generated-classification.json) compares all624 frozen paths and the complete managed current inventory: **615 match,9 generated common paths changed,2 generated CSS assets added,0 missing,0 non-generated mismatches**. Every changed/added current hash and exact path set matches root's separate build binding. No current624-tree equality is claimed. The immutable624 copies and all non-generated source contracts remain exact.

Root's separate artifacts report43 exact asset pairs and complete126-module retained-BEAM identities across02/03. This report fingerprints those records and attributes those release assertions to root; it does not substitute metadata claims for independent native process/browser acceptance or claim raw BEAM equality. Fresh release/assets/process/workspace/database binding remains part of root's native evidence intake.

## Native boundary

[Retained native02 failure](../../../../../../tmp/enhancement-program/06/independent-qa/candidate-03/retained-native02-failure.json) fingerprints the existing observations. Actual02 recorded document width476 against320 CSS pixels, a412.6875px target/card and focused target x=-13, visibly clipping the legitimate long package name and corrective controls. That **E3 failure remains failed**. A CSS source change or reused backend suite cannot establish corrected wrapping.

Candidate03 still needs fresh settled native evidence of complete long-name/digest/path controls, error and success results, focus/next Tab and320/390/actual200% geometry on the corrected loaded asset. Queued reset/stale forms, real focused unsent-value clearing, same-workspace preservation and exact exported bytes retain their separate acceptance obligations. No Mix, application test, Docker, runtime, browser, native helper, model call, private import, product edit or external mutation occurred in this assessment. QA wrote only this new report and new owned evidence/archive files. Root alone owns final acceptance/counting.
