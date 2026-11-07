#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$project_dir"
export MIX_ENV=prod
# Isolate any build-time config side effects from the operator's real workspace.
export HARNESSFORGE_WORKSPACE="$project_dir/tmp/package-build-workspace"
overlay="$project_dir/rel/overlays"
metadata="$overlay/share/harnessforge"
rm -rf "$metadata"
mkdir -p "$overlay/bin" "$metadata" "$project_dir/tmp/packages"
cp bin/harnessforge "$overlay/bin/harnessforge"
chmod 755 "$overlay/bin/harnessforge"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md README.md GLOSSARY.md PROGRESS.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md "$metadata/"
cp -R docs "$metadata/"
cp -R packaging/licenses "$metadata/"
elixir packaging/inventory.exs "$metadata/dependencies"
mix assets.setup
mix compile --warnings-as-errors
mix assets.deploy
mix release --overwrite
release_dir="$project_dir/_build/prod/rel/harness_forge"
version=$(mix run --no-start --no-compile -e 'IO.write(Mix.Project.config()[:version])')
platform=$(elixir -e 'IO.write(Atom.to_string(elem(:os.type(), 1)) <> "-" <> to_string(:erlang.system_info(:system_architecture)))')
archive="$project_dir/tmp/packages/harnessforge-$version-$platform.tar.gz"
"$release_dir/bin/harness_forge" eval 'for app <- Application.loaded_applications() |> Enum.sort(), do: IO.puts("#{elem(app, 0)} #{elem(app, 2)}")' > "$release_dir/share/harnessforge/bundled-applications.txt"
tar -czf "$archive" -C "$release_dir" .
elixir -e 'for file <- System.argv(), do: File.write!(file <> ".sha256", Base.encode16(:crypto.hash(:sha256, File.read!(file)), case: :lower) <> "  " <> Path.basename(file) <> "\n")' "$archive"
printf 'Package: %s\n' "$archive"
