# Native package candidate

Build with the pinned `.tool-versions` on the target operating system and
architecture. `mix release` includes BEAM/ERTS and prebuilt browser assets; users
of the archive do not need Mix, Node, Elixir or a separate Erlang installation.
Native libraries must remain compatible with the build target. A macOS archive
does not run on Linux, and Linux archives are not universally portable.
[Mix release documentation](https://mix.hexdocs.pm/1.19.5/Mix.Tasks.Release.html).

```sh
mix deps.get
packaging/build.sh
```

The script uses `MIX_ENV=prod`, installs the pinned asset wrappers if necessary,
builds/digests assets, assembles the default `harness_forge` release and includes:

- `bin/harnessforge`: user launcher, alongside Mix's `bin/harness_forge` manager;
- `LICENSE`, `NOTICE`, project documentation and dependency license materials;
- lockfile/toolchain identity, source inventory and bundled OTP application list;
- a native `.tar.gz` and SHA-256 file under ignored `tmp/packages/`.

`rel/overlays/bin/harnessforge` is refreshed from the source launcher during this
build. [Mix's default overlay mechanism](https://mix.hexdocs.pm/1.19.5/Mix.Tasks.Release.html#module-overlays)
includes the staged metadata in the release. Direct `mix release` is useful for
development, but use the packaging script for a candidate containing notices and
inventory. The script never uploads or publishes anything.

Extract into a fresh private installation directory, then:

```sh
export HARNESSFORGE_WORKSPACE="/absolute/path/to/a-private-workspace"
./bin/harnessforge help
./bin/harnessforge demo
./bin/harnessforge serve
```

Use [the quickstart](../docs/quickstart.md) for local login. Release configuration
is resolved at boot. The launcher sets `PHX_SERVER=true` for `serve`. Optional
provider credential values are resolved from configured environment references;
none are embedded in an archive. The local single-owner startup barrier completes
database/recovery preparation before exposing jobs/the portal. No remote
deployment or shared-database migration is part of this package.

## Verification and limits

`packaging/smoke.sh RELEASE_DIRECTORY` runs help/init/demo/status plus all five
provider configuration commands (no network requests) using a newly
created synthetic temporary workspace, then removes that workspace. It never
prints its access token. It also exercises company inventory, explicit synthetic
plan review, scoped native compilation, integrity verification and fresh export.
Runtime model/Docker qualification and HTTP browser
verification remain separate checks.

The Linux workflow builds on Ubuntu 24.04 with pinned toolchain/action refs,
checks formatting/compile/tests and runs a Credo warning gate. A separate
Dialyzer job runs on manual workflow dispatch; type analysis has not been
qualified as a merge gate. It builds
and smoke-checks a native archive without paid secrets or private sources. A
workflow definition is not evidence that hosted CI has run. Cold Dialyzer builds
are slow; PLTs are cached by toolchain, OS and lockfile hash.

Source/compiler artifacts are content reproducible; native release archives may
contain timestamps, an automatically generated release cookie and platform build
metadata. No byte-for-byte archive reproducibility or authenticated provenance
is claimed. The package script records the bundled application versions and
checksums; [third-party review limits](../THIRD_PARTY_NOTICES.md) apply before
public redistribution. Signing/publication/hosting are outside this local build.
