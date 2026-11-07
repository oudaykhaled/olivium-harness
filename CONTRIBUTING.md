# Contributing

Use synthetic shareable fixtures and focused changes. Read
[architecture](docs/architecture.md), [contracts](docs/contracts.md) and
[status](docs/status.md). The normal suite needs no private service, account,
organization atlas or paid model.

## Build and checks

Install `.tool-versions`, run `mix deps.get`, `mix assets.setup` and
`mix assets.build`, then:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict --only warning
mix dialyzer
```

Tests use temporary workspaces, Ecto SQL Sandbox and manual Oban execution.
SQLite writes are serialized. Drain jobs explicitly rather than sleeping.
New callable behavior needs a success and meaningful refusal/failure case.
Keep optional Node/Playwright QA in `test/browser`; do not add Node to the
installed application's runtime chain.

## Extensions

- **Connector:** implement the compiled-in behaviour; declare origins, scope,
  paging, credential references and access-revocation behavior. Bound requests
  and test redirects, rate limits, partial pages, denied access and replay.
- **Model:** use the Models consent/reservation/accounting boundary for every
  call. Handle missing usage, ambiguous completion and budgets safely. Responses
  remain unapproved proposals; workers/runtimes may not bypass the ledger.
- **Runtime:** declare native capability mapping and fixed confinement. Never
  run repository/model code on the host. Qualification needs effective config,
  protected graders, limits, cancellation and verified cleanup. Worktrees/BEAM
  processes are not sandboxes.
- **Compiler/package:** preserve canonical bytes, immutable lineage and safe
  export. Version changed contracts/templates. Unsupported required controls
  must not silently become enforced capabilities.

Inputs cannot create atoms/modules, install plugins or select executable code.
Keep secrets out of logs/config and document limits. New dependencies need a
reason, lockfile update and license/inventory review. Nontrivial architecture
changes need a short decision record with context, decision, consequences and
alternatives.

## Submit a change

Describe the problem, resulting behavior, checks and unverified assumptions.
Update docs/CHANGELOG. Never submit workspace data, tokens, private sources,
backups, model weights or runtime images. Implementation alone does not establish
merged, deployed or qualified status.

Contributions intentionally submitted for inclusion are under
[Apache-2.0](LICENSE). Sign off using `git commit -s` and an identity you are
entitled to use. This certifies the
[Developer Certificate of Origin 1.1](https://developercertificate.org/); it does
not transfer copyright or grant rights to someone else's content.

There is no published issue tracker/maintainer response-time commitment yet.
Once published, use the repository workflow for ordinary changes. Follow
[SECURITY.md](SECURITY.md) for suspected vulnerabilities and the
[code of conduct](CODE_OF_CONDUCT.md) in interactions.
