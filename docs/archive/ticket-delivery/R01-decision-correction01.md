# R01 correction 01: Preserve excluded memberships

This supersedes addendum01’s unconditional held-member transition. During hold cleanup, read each membership’s current status inside the page transaction. Preserve `removed` and its revision; clear its passage reference. Only `active`/`denied` become `denied`; never convert removed membership to active/denied. Use Evidence’s existing hold predicate, not another permission rule.

Keep all membership rows in corpus-ID ordering and cursor progression. For every visited corpus, including removed membership, advance semantic generation, authorization generation and lock version once per committed event/page; commit those effects with checkpoint CAS. Retries must not advance twice. Generation refresh permits unrelated current evidence; old certificates stay stale.

Test removed-before-hold and removal-between-pages: cleanup preserves exclusion, fresh unrelated use works, old certificates fail, held-source reinclusion fails. Test replay and unchanged no-hold behavior. This corrects review01’s P2 finding; prior artifacts remain frozen.
