**Scoped approval — review01’s P2 is resolved. Blocking: none in this repair.**

`SetupCaptureBounds.bounded?/1` now uses the claimed run’s server-persisted setup digest or an existing binding. All four classification sites pass the run, including reader selection, indexing, document authorization and settlement. Removing the binding therefore cannot select the legacy reader. Missing-binding setup runs also fail closed in `check/1` and page admission. The existing bounded reader still checks the current lease within its reservation transaction before body I/O; no filesystem work was moved into SQL/Purge.

The new regression uses accepted acquisition, an installed persisted worker lease and a successful prior lease check, then performs actual unrelated-source purge. It verifies that the original claimed run remains bounded, binding lookup is empty, check/page/read return cancelled, no pending-file evidence appears and no model admission occurs. This deterministically exercises the relevant post-purge state; it is not instruction-level scheduling or a traced body-I/O assertion. Existing unresolved-read tests retain allowance coverage; this new test itself creates no prior body reservation.

Root167 records 71 tests/0 failures in 8.6 seconds with stable source. Root165’s three failures remain historical evidence; Root169 was pending at dispatch and is not claimed green here. No reviewer checks were executed.

Delta SHA: `efd0ee3fab107be386afc717ce71f7b0d84d6c75d34fd07cb72ae0dccba427ba`. All 456 current pins match; semantic recheck covers only the two capture source diffs and added test, with exact ranges/hashes in the paired audit. Models compatibility changes remain under the separate review. No runtime/provider or full-ticket qualification. Frozen; ownership released.
