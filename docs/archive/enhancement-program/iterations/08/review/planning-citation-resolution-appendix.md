# Frozen08 planning citation-resolution appendix

Parent-owned append-only correction after root accepted ADR08. All16 original proposal bytes and their bad links remain unchanged. This repairs navigation, not scope or runtime evidence. No replanning or new product gate follows.

The16 originals contain **85 local Markdown link occurrences**: **45 links across seven reports** use four `../` components where their planning-folder depth requires five to reach the repository root. All canonical intended files exist and match their complete08 before copies exactly. The other40 Markdown paths resolve. Reports04 and12 use **14 repository-relative inline line ranges**, separately resolved below. Every cited line/range is in bounds; one anchor lands on whitespace and is corrected explicitly.

## Per-original audit

| Original | Markdown links | Bad depth | Inline ranges | Unchanged SHA256 |
|---|---:|---:|---:|---|
|[01-goal-journey.md](../planning/01-goal-journey.md)|5|5|0|`1afd0c53fe657dac440ab19d21548ac0b713af9592dcc6930936dcdbcddad7c7`|
|[02-recovery-copy.md](../planning/02-recovery-copy.md)|7|0|0|`78536cd5c28791041eafd4e997db5443b1ab293c7fa0e642981fad45cba45375`|
|[03-keyboard-focus.md](../planning/03-keyboard-focus.md)|7|7|0|`83413d7850c61026f026acb2a5e1e8c4597d01a681275d6112914fc81f7d93e3`|
|[04-narrow-zoom.md](../planning/04-narrow-zoom.md)|0|0|8|`62d4a5014041f825f24b26ac48b090bd722c557baa32415d091e735856fa2fc0`|
|[05-validation-contract.md](../planning/05-validation-contract.md)|8|0|0|`dae2717d5d4fd23cd430df19c472988c5ceae1e0078fecfb482d297a66b34ba4`|
|[06-notice-state.md](../planning/06-notice-state.md)|5|5|0|`004adf15cb23e5b75da5ee97de283b8e3d308e0bb878a137b66cc911ab8fbc9f`|
|[07-privacy-reset.md](../planning/07-privacy-reset.md)|7|7|0|`ab6ce34f725b4eb16fc5715d02f45e27ff92b43c9b416ffb6911e65b4550ff3b`|
|[08-authority-truth.md](../planning/08-authority-truth.md)|6|6|0|`c9572466eca8fbf286e9ba60f6c0b9b08b3b1742806e5643cefbc7b2b4dc97c6`|
|[09-mcp-inspection.md](../planning/09-mcp-inspection.md)|4|0|0|`8ffb39dfca2a4a0e374f917f3f4aca832b836e18b400aee550b37ef29e67991e`|
|[10-information-architecture.md](../planning/10-information-architecture.md)|8|0|0|`ad7c3722cace07463d0dc987324173c670cc402a2af88583b51e3673c808d811`|
|[11-cognitive-load.md](../planning/11-cognitive-load.md)|3|0|0|`f9b3a74543be9738d38909229ae30bdd5a020d554c20d9fa47502045e06af9a3`|
|[12-evidence-navigation.md](../planning/12-evidence-navigation.md)|0|0|6|`d44c0725aae348da6750d9cedde28caa6a44350d0fdea06b4bdce3540930d9fc`|
|[13-poll-stability.md](../planning/13-poll-stability.md)|4|0|0|`8f0056967604f489c3518c1304115edfc2ea4af3869773dc3d7a7d811ad654dd`|
|[14-test-oracles.md](../planning/14-test-oracles.md)|6|0|0|`fffba31fd82beef2f17be426bf409da19dc1a7664fd7eb8105d9be20254d85d2`|
|[15-boundary-minimality.md](../planning/15-boundary-minimality.md)|8|8|0|`f6e6010212ac8ef1fb3367d1f7938d3d9194a681d7f7df2bed9ad490f0fd865b`|
|[16-adversarial-choice.md](../planning/16-adversarial-choice.md)|7|7|0|`634e0895d0c2b868461d369e12cce63e31b8e29249a0ee38e7d45c91e72548f5`|

## Corrected targets for every bad-depth link

Original bad URL strings and occurrence/label pairs remain in the audit JSON and original reports. Each grouped row below resolves all matching original occurrences; corrected URLs are relative to this review folder.

| Original bad URL | Original occurrences | Correct target |
|---|---|---|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L1980`|01#1, 03#1, 07#1, 08#1, 15#1, 16#6|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1980)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L1542`|01#2, 03#2, 07#2, 08#2, 15#2, 16#7|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1542)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L1579`|01#3|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1579)|
|`../../../../test/harness_forge_web/goal_claims_test.exs#L47`|01#4|[source](../../../../../../test/harness_forge_web/goal_claims_test.exs#L47)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L1262`|01#5|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1262)|
|`../../../../test/harness_forge_web/goal_claims_test.exs#L28`|03#3, 15#6|[source](../../../../../../test/harness_forge_web/goal_claims_test.exs#L28)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L514`|03#4, 08#3|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L514)|
|`../../../../assets/js/app.js#L110`|03#5|[source](../../../../../../assets/js/app.js#L110)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L1258`|03#6, 06#4, 08#6, 15#8, 16#4|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1258)|
|`../../../../lib/harness_forge/contracts.ex#L327`|03#7|[source](../../../../../../lib/harness_forge/contracts.ex#L327)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L425`|06#1, 15#7, 16#3|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L425)|
|`../../../../lib/harness_forge/contracts.ex#L323`|06#2|[source](../../../../../../lib/harness_forge/contracts.ex#L323)|
|`../../../../priv/schemas/harness-v1alpha1.json#L20`|06#3, 16#2|[source](../../../../../../priv/schemas/harness-v1alpha1.json#L20)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L2008`|06#5, 16#5|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L2008)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L1571`|07#3|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1571)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L784`|07#4|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L784)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L935`|07#5, 08#4, 15#5|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L935)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L876`|07#6|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L876)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L1276`|07#7|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1280)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L1583`|08#5|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1583)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L60`|15#3|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L60)|
|`../../../../assets/js/app.js#L113`|15#4|[source](../../../../../../assets/js/app.js#L113)|
|`../../../../lib/harness_forge_web/live/portal_live.ex#L2005`|16#1|[source](../../../../../../lib/harness_forge_web/live/portal_live.ex#L2005)|

## Line precision and source meaning

- Original07 privacy proposal points at PortalLive1276, which is blank. Its intended generic provider-import fallback is [connector_error/1 at1280](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1280), with fixed text at1281. The same report’s path also needs the fifth parent component.
- PortalLive1583 is the goal-option loop; the exact ID/content-hash value is [1584](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1584). PortalLive2005 is the build-panel context; the [name field/default is2009–2013](../../../../../../lib/harness_forge_web/live/portal_live.ex#L2009). PortalLive2042 starts the built-packages context; the [artifact article starts2048](../../../../../../lib/harness_forge_web/live/portal_live.ex#L2048). These contextual anchors do not invalidate their surrounding source observations.
- Build425–446 invokes the existing domain and forwards errors to `error_message/1`;1262 routes generic typed errors to connector advice;1280–1281 contains the misleading fallback. Schema20–24 and Contracts43/323 establish the existing validation boundary. These remain source observations; successful retry, draft preservation and focus are planned acceptance, not executed evidence.
- Goal cards1980–1984 lack a continuation action; the separate1542 form has blank selection1579. Existing navigation/focus514 and app.js110–129 are reusable seams, not evidence that the proposed continuation already exists.
- Evaluation poll22–26/532–551 and conditional Cancel2196–2211 support a risk hypothesis. Original07 UI review63–67 explicitly retains the unexercised focused-Cancel-removal limit. MCP guide54 and tools248 preserve read-only current inspection and qualification abstention; no SDK qualification is inferred.

## Inline line-range citations

| Original literal | Report | Correct source anchor |
|---|---|---|
|`lib/harness_forge_web/live/portal_live.ex:1952-1984`|04|[lib/harness_forge_web/live/portal_live.ex:1952–1984](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1952)|
|`:1542-1602`|04|[lib/harness_forge_web/live/portal_live.ex:1542–1602](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1542)|
|`test/harness_forge_web/goal_claims_test.exs:28-52`|04|[test/harness_forge_web/goal_claims_test.exs:28–52](../../../../../../test/harness_forge_web/goal_claims_test.exs#L28)|
|`docs/enhancement-program/iterations/07/verification.md:28-37`|04|[docs/enhancement-program/iterations/07/verification.md:28–37](../../07/verification.md#L28)|
|`portal_live.ex:514-519`|04|[lib/harness_forge_web/live/portal_live.ex:514–519](../../../../../../lib/harness_forge_web/live/portal_live.ex#L514)|
|`assets/js/app.js:110-129`|04|[assets/js/app.js:110–129](../../../../../../assets/js/app.js#L110)|
|`portal_live.ex:425-441,1258-1281`|04|[lib/harness_forge_web/live/portal_live.ex:425–441](../../../../../../lib/harness_forge_web/live/portal_live.ex#L425)|
|`portal_live.ex:425-441,1258-1281`|04|[lib/harness_forge_web/live/portal_live.ex:1258–1281](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1258)|
|`lib/harness_forge_web/live/portal_live.ex:421`|12|[lib/harness_forge_web/live/portal_live.ex:421–423](../../../../../../lib/harness_forge_web/live/portal_live.ex#L421)|
|`:1542–1603`|12|[lib/harness_forge_web/live/portal_live.ex:1542–1603](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1542)|
|`:935–961`|12|[lib/harness_forge_web/live/portal_live.ex:935–961](../../../../../../lib/harness_forge_web/live/portal_live.ex#L935)|
|`:1572–1591`|12|[lib/harness_forge_web/live/portal_live.ex:1572–1591](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1572)|
|`test/harness_forge_web/goal_claims_test.exs:27–54`|12|[test/harness_forge_web/goal_claims_test.exs:27–54](../../../../../../test/harness_forge_web/goal_claims_test.exs#L27)|
|`portal_live.ex:1262–1280`|12|[lib/harness_forge_web/live/portal_live.ex:1262–1280](../../../../../../lib/harness_forge_web/live/portal_live.ex#L1262)|

No product/source/test or original-plan rewrite occurred. The complete machine audit records all85 original Markdown URLs, all14 inline ranges,16 original fingerprints and ten exact current/before target bindings. [Audit](../../../../../../tmp/enhancement-program/08/conductor08-citation-resolution-audit.json): SHA256 `79cbc89f9986dd2f3849798dee5df675524aa99c614d83e66d748784e5c6ce2c`.

Terminology clarification: “Original07 privacy proposal” above means numbered proposal07 (`07-privacy-reset.md`) within iteration08, not an iteration07 retrospective. Its original link/line bytes are retained.
