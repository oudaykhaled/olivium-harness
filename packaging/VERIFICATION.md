# Local packaging check record

Checked 31 October 2026 from the development checkout on macOS arm64 with Elixir
1.19.5 and Erlang/OTP 28.3.1. This records local observations, not a published
release, completed hosted CI or Linux compatibility.

| Check | Observed result |
| --- | --- |
| `packaging/build.sh` | Passed: production compilation, asset deployment/digests, `mix release`, notice/inventory staging and native archive/hash |
| `packaging/smoke.sh _build/prod/rel/harness_forge` | Passed real packaged `help`, `init`, `demo`, `status`; demo imported one synthetic source and proposed three claims |
| CLI workspace identity | `init` and `status` returned the same workspace UUID; global `runtime_qualified` remained false |
| Source inventory | 44 locked dependencies, all with declared license identifiers; available license/notice/README files retained |
| Archive | SHA-256 matched; launcher/inventory/bundled application list present; no absolute/traversal entries or workspace database/login/session files |
| Documentation links and workflow syntax | Owned local links resolved; workflow YAML parsed |
| Elixir packaging script/shell syntax | Inventory formatter and shell syntax checks passed |

The source release launcher initially passed a literal `--` to `System.argv()`;
the coordinator fixed the release branch and the successful smoke used the
corrected launcher. The smoke uses a physical temporary path because macOS's
`/var` symlink correctly fails source-import containment checks.

Output is under ignored `tmp/packages/`; the archive is about 12 MB. Rebuild after
source changes and rerun the smoke rather than treating an older archive as the
current checkout. Test/build logs are local under `tmp/packaging-*.log`.

These commands do not establish a real-model coding result, live connector
support, HTTP/browser acceptance, full strict-style compliance, clean Dialyzer
analysis or public distribution clearance. Those checks are recorded by their
own implementation owners. No provider secrets/private sources were used and
no archive was uploaded by this local packaging check.

## Five-provider native rebuild — 31 October 2026

Final canonical suite: 191 tests, zero failures, 15 existing Docker opt-in skips.
Native production rebuild and packaged help/init/demo/status plus all five
provider configuration commands passed. Archive 12,108,612 bytes; SHA-256
`0df7fbcbc4b5016e4f7e1d3b41b8c74e8a87e2cdd0a0b27421a4a6356523900d`. Archive path checks, checksum, all five adapter modules/Registry and
workspace-secret/database exclusion passed. The rebuilt binary also completed
actual Chrome all-five form checks and a public GitHub import of 30 issue/PR
snapshots plus one review-page continuation, preserving its cursor and incomplete
status. Authenticated private-service qualification remains externally blocked
as recorded in docs/archive/verification.md. This source record and an archive companion
report contain post-build observations; packaged docs are the build-time snapshot.
