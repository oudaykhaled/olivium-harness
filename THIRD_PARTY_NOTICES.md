# Third-party software

HarnessForge project code uses Apache-2.0. That does not relicense dependencies,
imported evidence, external runtimes, services or model weights.

`mix.lock` identifies the resolved Hex and Git source dependencies. Their Hex
metadata reports MIT or Apache-2.0 licensing. Run `packaging/build.sh` to produce
a machine-readable dependency inventory, per-component declared licenses and
available source license/notice/copyright files inside
`share/harnessforge/dependencies/` in the release. The inventory includes
development/build dependencies; it is deliberately broader than shipped BEAMs.
The exact included OTP applications are recorded separately.

| Component outside ordinary Hex metadata | Version / source | Terms |
| --- | --- | --- |
| Elixir | 1.19.5; installed build toolchain | Apache-2.0; bundled in native release |
| Erlang/OTP | 28.3.1; installed build toolchain | Apache-2.0 and upstream component notices; ERTS is bundled |
| Heroicons | v2.2.0; `tailwindlabs/heroicons`, exact Git ref in lock | MIT, Tailwind Labs, Inc. |
| daisyUI | v5.5.20; `saadeghi/daisyui`, exact Git ref in lock | MIT, Pouya Saadeghi; build dependency |
| topbar | 3.0.0; `assets/vendor/topbar.js` | MIT, Copyright 2024 Buu Nguyen, as stated in source |
| SQLite | Exqlite's bundled SQLite source | Public domain; Exqlite itself is MIT |
| Tailwind CSS / esbuild binaries | Versions in `config/config.exs` | MIT; build tools downloaded by wrappers, not installed-runtime prerequisites |
| Playwright | Optional `test/browser` package lock | Apache-2.0; downloaded browser binaries have their own notices; not bundled |
| Space Grotesk | `@fontsource/space-grotesk` 5.3.0 (npm packaging of the font); latin subset, normal style, self-hosted as `priv/static/fonts/space-grotesk-500.woff2`, `space-grotesk-600.woff2`, `space-grotesk-700.woff2` | SIL OFL 1.1, Florian Karsten (The Space Grotesk Project Authors); license text in `priv/static/fonts/OFL-space-grotesk.txt` |
| IBM Plex Mono | `@fontsource/ibm-plex-mono` 5.3.0 (npm packaging of the font); latin subset, normal style, self-hosted as `priv/static/fonts/ibm-plex-mono-400.woff2`, `ibm-plex-mono-500.woff2`, `ibm-plex-mono-600.woff2` | SIL OFL 1.1, IBM Corp.; license text in `priv/static/fonts/OFL-ibm-plex-mono.txt` |

Available original notices are copied without altering their contents. Some Hex
packages put copyright/license statements in README rather than a separate
LICENSE; those README files are retained with a copy of the declared license.
Phoenix Live Reload declares the same license as Phoenix in its README.

The inventory is an auditable build input inventory, **not a complete transitive
binary SBOM or a legal clearance certificate**. Before public binary
distribution, review exact ERTS/Exqlite/native library/browser transitive notices,
OS dynamic-library dependencies and any vendor additions on the target platform.
Checksums do not authenticate a maliciously replaced manifest.

## Separately installed components

OpenCode's official image is pinned by digest in the execution backend and is
installed explicitly by the operator; it is not bundled in HarnessForge's
archive. Check the pinned upstream runtime/image terms and notices before
redistributing it. Docker Engine/Desktop and provider services have their own
terms. A supported integration does not confer redistribution rights.

Ollama and selected model weights must be obtained separately. Record the exact
model/weight identity and license for your use; Apache-2.0 on HarnessForge grants
no model-weight rights. No weights or provider credentials are distributed here.
