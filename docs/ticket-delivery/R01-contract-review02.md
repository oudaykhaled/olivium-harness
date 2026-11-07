# R01 scoped contract recheck

**Verdict: approve the P2 correction. Blocking: none (P1:0, P2:0).**

Correction01 explicitly supersedes the unconditional transition. Reading membership status inside the page transaction and preserving `removed` plus its revision closes the reported regression. Keeping all rows in cursor ordering avoids skipped work; atomic generation advancement with checkpoint CAS specifies replay safety. The distinction between refreshed unrelated use and stale old certificates is correct. Required tests cover removal before/between pages, reinclusion denial, replay and unchanged no-hold behavior.

**Non-blocking / Nit:** None added. **Praise:** The correction reuses the existing Evidence predicate and changes only the defective membership transition contract.

Correction SHA256: `1d39e32d0dafe0537aca56f3cf3ef81505de482853749a54ce1eadef4b8b48ee`. Paired audit SHA256: `06622ae8495078a40a6e838368d9ef51c8c2ea1934ba4e716ba1c21a7ef61b20`. Both were read in full; decision01/addendum01 and their audit hashes remain unchanged. Review01 and its audit remain immutable.

This is a scoped contract approval using the previously inspected membership implementation as context. No new product-code semantic review, implementation/test verification, runtime/browser execution or full R01 acceptance is claimed. Root must verify the specified behavior after implementation.
