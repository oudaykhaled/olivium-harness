#!/bin/sh
set -eu
if [ "$#" -ne 1 ] || [ ! -x "$1/bin/harnessforge" ]; then
  echo "Usage: packaging/smoke.sh RELEASE_DIRECTORY" >&2
  exit 2
fi
release_dir=$(CDPATH= cd -- "$1" && pwd)
smoke_root=$(mktemp -d "${TMPDIR:-/tmp}/harnessforge-package-smoke.XXXXXX")
# macOS exposes TMPDIR through /var -> /private/var; imports reject symlink ancestors.
smoke_root=$(CDPATH= cd -- "$smoke_root" && pwd -P)
trap 'rm -rf "$smoke_root"' EXIT HUP INT TERM
export HARNESSFORGE_WORKSPACE="$smoke_root/workspace"
unset PHX_SERVER
"$release_dir/bin/harnessforge" help
"$release_dir/bin/harnessforge" init
"$release_dir/bin/harnessforge" demo
"$release_dir/bin/harnessforge" status
"$release_dir/bin/harnessforge" runtimes
"$release_dir/bin/harnessforge" model status
"$release_dir/bin/harnessforge" chat-connectors
"$release_dir/bin/harnessforge" chat 'What tests are required?'
"$release_dir/bin/harnessforge" company profile
"$release_dir/bin/harnessforge" company repositories
"$release_dir/bin/harnessforge" company projects
"$release_dir/bin/harnessforge" company plans

# Exercise every compiled provider through the packaged CLI without network calls.
"$release_dir/bin/harnessforge" connect github 'Package repository' synthetic/selected
"$release_dir/bin/harnessforge" connect github_projects 'Package board' https://github.com/orgs/synthetic/projects/1 HARNESSFORGE_SMOKE_PROJECTS_TOKEN
"$release_dir/bin/harnessforge" connect jira 'Package Jira' https://synthetic.atlassian.net DEMO HARNESSFORGE_SMOKE_EMAIL HARNESSFORGE_SMOKE_JIRA_TOKEN
"$release_dir/bin/harnessforge" connect slack 'Package channel' T123456 C123456 HARNESSFORGE_SMOKE_SLACK_TOKEN
"$release_dir/bin/harnessforge" connect confluence 'Package pages' https://synthetic.atlassian.net 12345 HARNESSFORGE_SMOKE_EMAIL HARNESSFORGE_SMOKE_CONFLUENCE_TOKEN

# Explicit test decisions apply only to this disposable built-in fixture.
# Do not approve the deliberately malicious third demonstration claim.
"$release_dir/bin/harness_forge" eval '
{:ok, _} = Application.ensure_all_started(:harness_forge)
{:ok, claims} = HarnessForge.Evidence.list_claims()
selected = Enum.filter(claims, &(&1["text"] in [
  "Exported Go functions require table-driven tests covering empty input and boundary values.",
  "Changes must preserve UTF-8 text and use the Go standard library unless a reviewer approves a dependency."
]))
2 = length(selected)
for claim <- selected do
  {:ok, _} = HarnessForge.Decisions.decide(claim["id"], %{
    "actor" => "disposable-package-smoke",
    "decision" => "approve",
    "expected_revision_hash" => claim["revision_hash"]
  })
end
IO.puts("Two exact synthetic fixture revisions approved for package smoke only.")
'
"$release_dir/bin/harnessforge" build package-codex 0.1.0 codex 0.156.0
"$release_dir/bin/harnessforge" build package-claude 0.1.0 claude_code 2.1.311

# Company approval is confined to the same disposable synthetic fixture.
"$release_dir/bin/harness_forge" eval '
{:ok, _} = Application.ensure_all_started(:harness_forge)
alias HarnessForge.{Company, Evidence, Harnesses}
{:ok, _} = Company.save_profile(%{"name" => "Disposable package smoke"})
{:ok, repository} = Company.create_repository(%{"identity" => "synthetic/package", "name" => "Synthetic package", "purpose" => "Public package fixture", "owner" => "synthetic-test"})
{:ok, sources} = Evidence.list_sources()
{:ok, project} = Company.create_project(%{"name" => "Package fixture", "repository_ids" => [repository["id"]], "source_ids" => Enum.map(sources, & &1["id"])})
{:ok, claims} = Evidence.approved_claims()
{:ok, plan} = Company.create_plan(%{"name" => "package-company", "package_version" => "0.1.0", "project_id" => project["id"], "repository_ids" => [repository["id"]], "claim_refs" => Enum.map(claims, &Map.take(&1, ~w(id revision_hash))), "goal_ids" => [], "template_ids" => ["reviewed-change-v1", "reuse-before-build-v1"], "runtime" => "codex", "runtime_version" => "0.156.0", "execution" => %{"max_turns" => 20, "timeout_seconds" => 300}})
{:error, :plan_not_approved} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
{:ok, _} = Company.decide_plan(plan["id"], %{"actor" => "disposable-package-smoke", "decision" => "approve", "expected_revision_hash" => plan["revision_hash"]})
{:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])
:ok = HarnessForge.Compiler.verify(artifact)
{:ok, _} = Harnesses.export(artifact["digest"], Path.join(Path.dirname(HarnessForge.Workspaces.root()), "company-export"))
IO.puts("Synthetic company plan review, scoped native build and fresh export passed.")
'

# Saving API configuration is offline. Consent is absent; no inference can run.
for smoke_provider in openai_responses anthropic; do
  case "$smoke_provider" in
    openai_responses) smoke_endpoint=https://api.openai.com/v1 ;;
    anthropic) smoke_endpoint=https://api.anthropic.com/v1 ;;
  esac
  cat > "$smoke_root/model.json" <<EOF
{"provider":"$smoke_provider","endpoint":"$smoke_endpoint","model":"synthetic-smoke-model","credential_env":"HARNESSFORGE_SMOKE_API_KEY","input_microusd_per_million":1000000,"output_microusd_per_million":1000000,"cloud_consent":null}
EOF
  "$release_dir/bin/harnessforge" model configure "$smoke_root/model.json"
  "$release_dir/bin/harnessforge" model status
done
