# Local compatibility evidence

Checked on 31 October 2026 on macOS arm64. This file records the bootstrap
combination; it does not qualify other operating systems or live integrations.

| Component | Selected version |
| --- | --- |
| Elixir | 1.19.5 |
| Erlang/OTP | 28.3.1 |
| Phoenix generator / Phoenix | 1.8.16 |
| Phoenix LiveView | 1.2.13 |
| Ecto / Ecto SQL | 3.14.2 / 3.14.0 |
| Ecto SQLite3 / Exqlite | 0.26.0 / 0.43.0 |
| Oban OSS, Lite engine | 2.24.2 |
| Req / Jason | 0.7.5 / 1.4.5 |

`mix.lock` pins the full resolved dependency set, including asset dependencies.
`.tool-versions` records the installed runtime tuple. No runtime was installed or
changed during bootstrap. The Phoenix generator archive was installed through Hex.

Phoenix 1.8 was selected because it is the current stable generator and supports
the installed toolchain. Its minimum is Elixir 1.17 and Erlang 25. A single Mix
application retains the planned context boundaries and LiveView UI.
[Phoenix installation](https://phoenix.hexdocs.pm/installation.html).

Oban's OSS Lite engine supports SQLite. There is no separate paid queue package
or external database requirement. The test configuration uses manual execution,
disabled queues/plugins and a temporary database unique to each BEAM VM.
[Oban Lite engine](https://oban.hexdocs.pm/Oban.Engines.Lite.html).

SQLite uses WAL, foreign keys and a five-second busy timeout. The foundation
tests exercise FTS5 through the packaged Exqlite driver and enqueue an Oban job;
they do not substitute the system `sqlite3` binary. Writers remain serialized at
the job queue; the workspace lifecycle must complete migrations/recovery before
starting normal job services.

## Known bootstrap limitations

- Oban 2.24.2 emits an upstream type-analysis warning in `Oban.Repo.transaction/4`
  with Elixir 1.19.5. Application compilation still succeeds with
  `mix compile --warnings-as-errors`; dependency warnings are reported separately.
- OpenCode and Ollama were absent on this host at task dispatch. Their live
  integration remains unverified; no provider calls or runtime downloads occurred.
- Docker CLI was present but its daemon was unavailable at dispatch. No
  code-running evaluation or isolation support is established by these checks.
- Linux packaging and release portability require their own native build evidence.

## Verification commands

Bootstrap results: full `mix test` completed with 8 tests and 0 failures;
the scoped generated web plus foundation suite completed with 7 tests and 0
failures. `mix compile --warnings-as-errors` and `mix assets.build` passed.
The contract suite may grow as other implementation lanes land.

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
```

SQLite-aware test modules must include `engine: Oban.Engines.Lite` when using
`Oban.Testing`; its helper configuration otherwise defaults to PostgreSQL.

The local portal binds to IPv4 loopback by default in development and production
configuration. Production startup still requires its database path and a fresh
`SECRET_KEY_BASE`; workspace/session setup is owned by the foundation lifecycle.
