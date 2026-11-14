#!/usr/bin/env bash
# bench/e2e-cli.sh — end-to-end scenario suite through the real launcher bin/harnessforge.
#
# Usage:
#   HARNESSFORGE_WORKSPACE=/abs/fresh-workspace BENCH_OUT=/abs/out E2E_EXPORT_ROOT=/abs/fresh-exports bash bench/e2e-cli.sh
# Environment:
#   HARNESSFORGE_WORKSPACE  (required) fresh workspace directory owned by the CLI calls of this run
#   BENCH_OUT               evidence directory (default docs/benchmarks/<today>/e2e relative to the repository)
#   E2E_EXPORT_ROOT         fresh directory for exports/backups (default <BENCH_OUT>/../tmp-exports)
#   E2E_RESTORE_TARGET      fresh directory for the restored workspace of C10
#                           (default <E2E_EXPORT_ROOT>/cli-restored-workspace)
# Every launcher call runs "mix run -e HarnessForge.CLI.main" and therefore boots the BEAM (about 5 s), which is
# included in each scenario's duration_ms. Raw stdout/stderr of every command is appended to BENCH_OUT/cli.log and
# the scenario records are written to BENCH_OUT/cli-results.json. Exit status 1 if any scenario failed.
# C18, C19 and C21 run the exported hook scripts and the replay gate (bench/value/replay/gate.py) on the host, on the
# synthetic fixture only, with stub executables in place of every project tool and synthetic tool-call text; nothing
# from a real repository and nothing a model wrote runs. They need python3 and perl. C24 (lean-ai) runs the exported
# locator and rewrite hooks the same way, on synthetic prompts and commands, with a synthetic learned bundle.
# C25-C30 generate the Claude Code skills and subagents from a synthetic repository with history; C28 runs the replay
# gate on the host again, with synthetic test-runner calls that carry agent_type. C31 generates from two shallow clones
# of that repository (10 commits, and all but the first commit after 200 one-file commits are added). C32 generates a
# synthetic Node repository whose test script is a direct `node --test` call, with decoy scripts and a CI job in a
# subdirectory, and runs the exported guard on the host on synthetic command text. Nothing from the fixtures runs.
set -u
project=$(cd "$(dirname "$0")/.." && pwd)
cd "$project" || exit 2
: "${HARNESSFORGE_WORKSPACE:?HARNESSFORGE_WORKSPACE is required}"
export HARNESSFORGE_WORKSPACE
unset PHX_SERVER
today=$(date -u +%Y-%m-%d)
BENCH_OUT=${BENCH_OUT:-$project/docs/benchmarks/$today/e2e}
E2E_EXPORT_ROOT=${E2E_EXPORT_ROOT:-$BENCH_OUT/../tmp-exports}
E2E_RESTORE_TARGET=${E2E_RESTORE_TARGET:-$E2E_EXPORT_ROOT/cli-restored-workspace}
mkdir -p "$BENCH_OUT" "$E2E_EXPORT_ROOT"
LOG=$BENCH_OUT/cli.log
RESULTS=$BENCH_OUT/cli-results.json
RECORDS=$(mktemp "${TMPDIR:-/tmp}/e2e-cli-records.XXXXXX")
OUT=$(mktemp "${TMPDIR:-/tmp}/e2e-cli-stdout.XXXXXX")
ERR=$(mktemp "${TMPDIR:-/tmp}/e2e-cli-stderr.XXXXXX")
trap 'rm -f "$RECORDS" "$OUT" "$ERR"' EXIT
: > "$LOG"
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
now_ms() { perl -MTime::HiRes=time -e 'printf("%.0f\n", time*1000)'; }
suite_t0=$(now_ms)

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# Scenario bookkeeping ---------------------------------------------------------------------------------------
scenario_id=""; scenario_title=""; scenario_t0=0; scenario_cmds=(); scenario_error=""; scenario_detail="{}"
begin() { scenario_id=$1; scenario_title=$2; scenario_t0=$(now_ms); scenario_cmds=(); scenario_error=""; scenario_detail="{}"; log "[$scenario_id] start: $scenario_title"; }
fail() { [ -z "$scenario_error" ] && scenario_error=$1; log "[$scenario_id] assertion failed: $1"; }
finish() {
  local ms=$(( $(now_ms) - scenario_t0 )) result=pass
  [ -n "$scenario_error" ] && result=fail
  node -e '
    const [id, title, result, ms, error, detail, ...cmds] = process.argv.slice(1);
    const rec = {id, title, result, duration_ms: Number(ms), error: error ? error.slice(0, 300) : null,
      command: cmds.join(" && "), commands: cmds, details: JSON.parse(detail || "{}")};
    process.stdout.write(JSON.stringify(rec) + "\n");
  ' "$scenario_id" "$scenario_title" "$result" "$ms" "$scenario_error" "$scenario_detail" ${scenario_cmds[@]+"${scenario_cmds[@]}"} >> "$RECORDS"
  log "[$scenario_id] $(echo "$result" | tr a-z A-Z) in ${ms} ms${scenario_error:+ — $scenario_error}"
}

# hf CMD... : runs the launcher, logs the command and raw output, keeps stdout in $OUT and the JSON in $JSON.
# Returns the launcher's exit status. Workspace override via HF_WS (used only for the restored workspace).
JSON=""
hf() {
  local ws=${HF_WS:-$HARNESSFORGE_WORKSPACE} cmd t0 t1 status
  cmd="HARNESSFORGE_WORKSPACE=$ws bin/harnessforge $*"
  scenario_cmds+=("$cmd")
  t0=$(now_ms)
  HARNESSFORGE_WORKSPACE=$ws bin/harnessforge "$@" > "$OUT" 2> "$ERR"
  status=$?
  t1=$(now_ms)
  {
    printf -- '----- %s [%s] $ %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$scenario_id" "$cmd"
    printf -- '----- exit %s after %s ms; stdout:\n' "$status" "$((t1 - t0))"
    cat "$OUT"
    printf -- '----- stderr:\n'
    cat "$ERR"
  } >> "$LOG"
  JSON=$(grep '^{' "$OUT" | tail -1)
  [ -z "$JSON" ] && JSON=$(grep '^{' "$ERR" | tail -1)
  return $status
}
# jq-like extraction with node: jx 'expr' where d is the parsed JSON of the last command.
jx() { node -e 'const d = JSON.parse(process.argv[1]); const v = (function(d){ return eval(process.argv[2]); })(d); process.stdout.write(v === undefined ? "" : (typeof v === "string" ? v : JSON.stringify(v)));' "$JSON" "$1" 2>/dev/null; }
ok() { [ -n "$JSON" ] && [ "$(jx 'd.ok')" = "true" ]; }

# ---- C01 init -------------------------------------------------------------------------------------------------
begin C01 "init prints a workspace id"
if hf init && ok; then
  wsid=$(jx 'd.result.workspace_id')
  [ -n "$wsid" ] || fail "workspace_id missing: $JSON"
  scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({workspace_id: process.argv[1], root: process.argv[2]}))' "$wsid" "$(jx 'd.result.root')")
else fail "init failed: $(head -c 300 "$ERR") $JSON"; fi
finish

# ---- C02 status -----------------------------------------------------------------------------------------------
begin C02 "status reports elixir 1.19.5 and runtime_qualified false"
if hf status && ok; then
  [ "$(jx 'd.result.elixir')" = "1.19.5" ] || fail "elixir != 1.19.5: $(jx 'd.result.elixir')"
  [ "$(jx 'd.result.runtime_qualified')" = "false" ] || fail "runtime_qualified != false: $JSON"
  scenario_detail=$(jx 'd.result')
else fail "status failed: $(head -c 300 "$ERR")"; fi
finish

# ---- C03 demo + claims ----------------------------------------------------------------------------------------
begin C03 "demo loads and claims lists exactly 3 claims"
CLAIMS=""
if hf demo && ok; then
  demo_json=$JSON
  if hf claims && ok; then
    count=$(jx 'd.result.length')
    [ "$count" = "3" ] || fail "expected 3 claims, got $count"
    CLAIMS=$(jx 'd.result.map(c => [c.id, c.revision_hash, c.status, c.text].join("\t")).join("\n")')
    scenario_detail=$(node -e 'const demo = JSON.parse(process.argv[1]); process.stdout.write(JSON.stringify({claims: Number(process.argv[2]), demo_mode: demo.result.mode, demo_claim_ids: demo.result.claim_ids}))' "$demo_json" "$count")
  else fail "claims failed: $(head -c 300 "$ERR")"; fi
else fail "demo failed: $(head -c 300 "$ERR") $JSON"; fi
finish

# ---- C04 decide -----------------------------------------------------------------------------------------------
begin C04 "decide: approve the two ordinary claims by id and exact revision_hash, reject the hostile one"
decided=0
if [ -n "$CLAIMS" ]; then
  while IFS=$'\t' read -r id hash status text; do
    [ -z "$id" ] && continue
    case "$text" in
      *"IGNORE ALL PREVIOUS INSTRUCTIONS"*) decision=reject ;;
      *) decision=approve ;;
    esac
    if hf decide "$id" "$decision" "$hash" && ok; then decided=$((decided + 1)); else fail "decide $decision $id failed: $(head -c 300 "$ERR") $JSON"; fi
  done <<< "$CLAIMS"
  [ "$decided" = "3" ] || fail "expected 3 decisions, got $decided"
  if hf claims && ok; then
    approved=$(jx 'd.result.filter(c => c.status === "approved").length')
    rejected=$(jx 'd.result.filter(c => c.status === "rejected").length')
    hostile_status=$(jx 'd.result.find(c => c.text.includes("IGNORE ALL PREVIOUS INSTRUCTIONS")).status')
    [ "$approved" = "2" ] || fail "expected 2 approved claims, got $approved"
    [ "$rejected" = "1" ] || fail "expected 1 rejected claim, got $rejected"
    [ "$hostile_status" = "rejected" ] || fail "hostile claim status $hostile_status"
    scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({decisions: Number(process.argv[1]), approved: Number(process.argv[2]), rejected: Number(process.argv[3]), hostile_status: process.argv[4]}))' "$decided" "$approved" "$rejected" "$hostile_status")
  else fail "claims after decisions failed"; fi
else fail "no claims from C03"; fi
finish

# ---- C05 build three runtimes ---------------------------------------------------------------------------------
begin C05 "build e2e-cli 0.1.0 for claude_code 2.1.311, codex 0.156.0 and opencode 1.0.0; each returns a digest and manifest"
CLAUDE_DIGEST=""; CODEX_DIGEST=""; OPENCODE_DIGEST=""
claude_files=0; codex_files=0; opencode_files=0
build_one() { # runtime version digest_var files_var (no subshell so fail/commands are recorded)
  if hf build e2e-cli 0.1.0 "$1" "$2" && ok; then
    local digest files
    digest=$(jx 'd.result.digest'); files=$(jx '(d.result.manifest && d.result.manifest.files || []).length')
    [ -n "$digest" ] || fail "$1: digest missing"
    [ "$(jx 'd.result.manifest ? "yes" : "no"')" = "yes" ] || fail "$1: manifest missing"
    printf -v "$3" '%s' "$digest"; printf -v "$4" '%s' "${files:-0}"
  else fail "build $1 $2 failed: $(head -c 300 "$ERR") $JSON"; fi
}
build_one claude_code 2.1.311 CLAUDE_DIGEST claude_files
build_one codex 0.156.0 CODEX_DIGEST codex_files
build_one opencode 1.0.0 OPENCODE_DIGEST opencode_files
scenario_detail=$(node -e 'const [a,b,c,d,e,f] = process.argv.slice(1); process.stdout.write(JSON.stringify({claude_code: {version: "2.1.311", digest: a, manifest_files: Number(b)}, codex: {version: "0.156.0", digest: c, manifest_files: Number(d)}, opencode: {version: "1.0.0", digest: e, manifest_files: Number(f), note: "opencode accepts unqualified or any 1.x version (lib/harness_forge/adapters/opencode.ex)"}}))' "$CLAUDE_DIGEST" "${claude_files:-0}" "$CODEX_DIGEST" "${codex_files:-0}" "$OPENCODE_DIGEST" "${opencode_files:-0}")
finish

# ---- C06 rebuild claude_code ----------------------------------------------------------------------------------
begin C06 "rebuilding claude_code with identical inputs returns the same digest"
if [ -n "$CLAUDE_DIGEST" ]; then
  if hf build e2e-cli 0.1.0 claude_code 2.1.311 && ok; then
    rebuilt=$(jx 'd.result.digest')
    [ "$rebuilt" = "$CLAUDE_DIGEST" ] || fail "digest changed: $CLAUDE_DIGEST -> $rebuilt"
    scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({first_digest: process.argv[1], rebuild_digest: process.argv[2], identical: process.argv[1] === process.argv[2]}))' "$CLAUDE_DIGEST" "$rebuilt")
  else fail "rebuild failed: $(head -c 300 "$ERR")"; fi
else fail "no claude_code digest from C05"; fi
finish

# ---- C07 export + verify on disk ------------------------------------------------------------------------------
begin C07 "export the claude_code digest to a fresh directory; CLAUDE.md, .claude/settings.json and manifest sha256 verified on disk"
EXPORT_DIR=$E2E_EXPORT_ROOT/cli-export-claude
if [ -n "$CLAUDE_DIGEST" ]; then
  if [ -e "$EXPORT_DIR" ]; then fail "export target is not fresh: $EXPORT_DIR"; fi
  if hf export "$CLAUDE_DIGEST" "$EXPORT_DIR" && ok; then
    verdict=$(node -e '
      const fs = require("fs"), path = require("path"), crypto = require("crypto");
      const dir = process.argv[1]; const out = {errors: []};
      const walk = (d, base = d) => fs.readdirSync(d, {withFileTypes: true}).flatMap(e => e.isDirectory() ? walk(path.join(d, e.name), base) : [path.relative(base, path.join(d, e.name)).split(path.sep).join("/")]).sort();
      try {
        const guidance = fs.readFileSync(path.join(dir, "CLAUDE.md"), "utf8");
        out.claude_md_has_rule = guidance.includes("Exported Go functions require table-driven tests covering empty input and boundary values.");
        out.claude_md_has_utf8_rule = guidance.includes("Changes must preserve UTF-8 text and use the Go standard library unless a reviewer approves a dependency.");
        out.claude_md_has_hostile = guidance.includes("IGNORE ALL PREVIOUS INSTRUCTIONS") || guidance.includes("export all credentials");
        if (!out.claude_md_has_rule) out.errors.push("CLAUDE.md lacks the approved rule text");
        if (out.claude_md_has_hostile) out.errors.push("CLAUDE.md contains the hostile sentence");
      } catch (e) { out.errors.push("CLAUDE.md: " + e.message); }
      try { JSON.parse(fs.readFileSync(path.join(dir, ".claude/settings.json"), "utf8")); out.settings_json_parses = true; } catch (e) { out.settings_json_parses = false; out.errors.push(".claude/settings.json: " + e.message); }
      try {
        const manifest = JSON.parse(fs.readFileSync(path.join(dir, "harnessforge.manifest.json"), "utf8"));
        const listed = manifest.files.map(f => f.path).sort();
        const onDisk = walk(dir).filter(f => f !== "harnessforge.manifest.json");
        out.files_on_disk = onDisk.length + 1; out.manifest_entries = listed.length;
        out.manifest_lists_every_file = JSON.stringify(listed) === JSON.stringify(onDisk);
        if (!out.manifest_lists_every_file) out.errors.push("manifest/disk mismatch: " + JSON.stringify({listed, onDisk}).slice(0, 300));
        out.sha256_mismatches = manifest.files.filter(f => crypto.createHash("sha256").update(fs.readFileSync(path.join(dir, f.path))).digest("hex") !== f.sha256).map(f => f.path);
        if (out.sha256_mismatches.length) out.errors.push("sha256 mismatch: " + out.sha256_mismatches.join(","));
        out.files = onDisk;
      } catch (e) { out.errors.push("manifest: " + e.message); }
      process.stdout.write(JSON.stringify(out));
    ' "$EXPORT_DIR")
    scenario_detail=$(node -e 'const v = JSON.parse(process.argv[1]); v.target = process.argv[2]; process.stdout.write(JSON.stringify(v))' "$verdict" "$EXPORT_DIR")
    errors=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).errors.join("; "))' "$verdict")
    [ -z "$errors" ] || fail "$errors"
  else fail "export failed: $(head -c 300 "$ERR") $JSON"; fi
else fail "no claude_code digest from C05"; fi
finish

# ---- C08 evaluate static_integrity + runs ---------------------------------------------------------------------
begin C08 "evaluate DIGEST static_integrity passes and runs lists it"
if [ -n "$CLAUDE_DIGEST" ]; then
  if hf evaluate "$CLAUDE_DIGEST" static_integrity && ok; then
    run_id=$(jx 'd.result.id'); outcome=$(jx 'd.result.outcome')
    attempts=0
    while [ "$outcome" != "passed" ] && [ "$outcome" != "failed" ] && [ "$outcome" != "blocked" ] && [ $attempts -lt 4 ]; do
      attempts=$((attempts + 1))
      if hf runs && ok; then outcome=$(node -e 'const d = JSON.parse(process.argv[1]); const r = d.result.find(r => r.id === process.argv[2]); process.stdout.write(r ? String(r.outcome) : "")' "$JSON" "$run_id"); fi
    done
    [ "$outcome" = "passed" ] || fail "static_integrity outcome $outcome (run $run_id)"
    if hf runs && ok; then
      listed=$(node -e 'const d = JSON.parse(process.argv[1]); const r = d.result.find(r => r.id === process.argv[2]); process.stdout.write(JSON.stringify(r ? {listed: true, kind: r.kind, outcome: r.outcome, runtime_qualified: r.runtime_qualified, artifact_digest: r.artifact_digest} : {listed: false}))' "$JSON" "$run_id")
      [ "$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).listed))' "$listed")" = "true" ] || fail "runs does not list $run_id"
      [ "$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).kind))' "$listed")" = "static_integrity" ] || fail "listed run kind mismatch: $listed"
      scenario_detail=$(node -e 'const l = JSON.parse(process.argv[1]); l.run_id = process.argv[2]; l.runs_polls_after_evaluate = Number(process.argv[3]); process.stdout.write(JSON.stringify(l))' "$listed" "$run_id" "$attempts")
    else fail "runs failed"; fi
  else fail "evaluate failed: $(head -c 300 "$ERR") $JSON"; fi
else fail "no claude_code digest from C05"; fi
finish

# ---- C09 diff -------------------------------------------------------------------------------------------------
begin C09 "diff between the claude_code and codex digests reports differences"
if [ -n "$CLAUDE_DIGEST" ] && [ -n "$CODEX_DIGEST" ]; then
  if hf diff "$CLAUDE_DIGEST" "$CODEX_DIGEST" && ok; then
    summary=$(jx '({files_added: d.result.files.added, files_removed: d.result.files.removed, files_changed: d.result.files.changed, rules_added: d.result.rules.added.length, rules_removed: d.result.rules.removed.length, rules_changed: d.result.rules.changed.length})')
    total=$(jx 'd.result.files.added.length + d.result.files.removed.length + d.result.files.changed.length')
    [ "${total:-0}" -gt 0 ] || fail "diff reports no file differences: $JSON"
    scenario_detail=$(node -e 'const s = JSON.parse(process.argv[1]); s.file_differences = Number(process.argv[2]); process.stdout.write(JSON.stringify(s))' "$summary" "$total")
  else fail "diff failed: $(head -c 300 "$ERR") $JSON"; fi
else fail "missing digests from C05"; fi
finish

# ---- C10 backup, restore, status on the restored workspace ----------------------------------------------------
begin C10 "backup to a fresh directory, restore into a fresh workspace directory, status against the restored workspace"
BACKUP_DIR=$E2E_EXPORT_ROOT/cli-backup
if [ -e "$BACKUP_DIR" ] || [ -e "$E2E_RESTORE_TARGET" ]; then fail "backup or restore target is not fresh"; fi
if hf backup "$BACKUP_DIR" && ok; then
  backup_json=$JSON
  [ -f "$BACKUP_DIR/manifest.json" ] || fail "backup lacks manifest.json"
  [ -f "$BACKUP_DIR/data.sqlite3" ] || fail "backup lacks data.sqlite3"
  if hf restore "$BACKUP_DIR" "$E2E_RESTORE_TARGET" && ok; then
    restore_json=$JSON
    restored_id=$(jx 'd.result.workspace_id')
    if HF_WS=$E2E_RESTORE_TARGET hf status && ok; then
      status_id=$(jx 'd.result.workspace_id')
      [ -n "$status_id" ] || fail "status on restored workspace has no workspace_id"
      scenario_detail=$(node -e 'const b = JSON.parse(process.argv[1]).result, r = JSON.parse(process.argv[2]).result, s = JSON.parse(process.argv[3]).result; process.stdout.write(JSON.stringify({backup: b, restore: r, restored_status: s, restored_workspace_id_matches_status: r.workspace_id === s.workspace_id, source_workspace_id_differs: b.workspace_id !== r.workspace_id}))' "$backup_json" "$restore_json" "$JSON")
    else fail "status on restored workspace failed: $(head -c 300 "$ERR") $JSON"; fi
  else fail "restore failed: $(head -c 300 "$ERR") $JSON"; fi
else fail "backup failed: $(head -c 300 "$ERR") $JSON"; fi
finish

# ---- C11 inventory --------------------------------------------------------------------------------------------
begin C11 "inventory returns counts"
if hf inventory && ok; then
  tables=$(jx 'Object.keys(d.result.records).length')
  [ "${tables:-0}" -gt 0 ] || fail "inventory has no record counts"
  scenario_detail=$(jx '({workspace_id: d.result.workspace_id, record_tables: Object.keys(d.result.records).length, records: d.result.records, files: d.result.files, retention: d.result.retention})')
else fail "inventory failed: $(head -c 300 "$ERR") $JSON"; fi
finish

# ---- repository analysis and generation -----------------------------------------------------------------------
# The fixture is synthetic, written here, and only read by the analyzer. Its .env holds a planted marker that must
# never reach output. Its commands are detected and written, never run.
FIXTURE_REPO=$E2E_EXPORT_ROOT/fixture-repo
FIXTURE_SECRET=SYNTHETIC-e2e-secret-value-do-not-print-7f3a
FIXTURE_AUTHOR="Synthetic Author"
FIXTURE_EMAIL=synthetic-author@example.invalid
fixture_git() { # day args...
  local stamp day=$1
  shift
  stamp=$(printf '2026-01-%02dT12:00:00Z' "$day")
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME="$FIXTURE_AUTHOR" GIT_AUTHOR_EMAIL="$FIXTURE_EMAIL" GIT_AUTHOR_DATE="$stamp" \
    GIT_COMMITTER_NAME="$FIXTURE_AUTHOR" GIT_COMMITTER_EMAIL="$FIXTURE_EMAIL" GIT_COMMITTER_DATE="$stamp" \
    git -C "$FIXTURE_REPO" "$@"
}
build_fixture() {
  local index source tests
  mkdir -p "$FIXTURE_REPO/src" "$FIXTURE_REPO/test" "$FIXTURE_REPO/.github/workflows"
  fixture_git 1 init --quiet --initial-branch=main
  cat > "$FIXTURE_REPO/package.json" <<'JSON'
{
  "name": "acme-routes",
  "version": "1.0.0",
  "scripts": { "test": "mocha test/", "lint": "eslint .", "format": "prettier --write ." },
  "devDependencies": { "mocha": "^11.0.0", "eslint": "^9.0.0", "prettier": "^3.0.0" }
}
JSON
  printf '{ "name": "acme-routes", "lockfileVersion": 3, "packages": {} }\n' > "$FIXTURE_REPO/package-lock.json"
  printf 'name: ci\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm ci\n      - run: npm run lint\n      - run: npm test\n' > "$FIXTURE_REPO/.github/workflows/ci.yml"
  printf 'API_TOKEN=%s\n' "$FIXTURE_SECRET" > "$FIXTURE_REPO/.env"
  printf '# acme-routes\n\nA synthetic project used by the end-to-end suite.\n' > "$FIXTURE_REPO/README.md"
  printf 'module.exports = {};\n' > "$FIXTURE_REPO/src/router.js"
  printf 'module.exports = {};\n' > "$FIXTURE_REPO/src/cache.js"
  printf "it('router', () => {});\n" > "$FIXTURE_REPO/test/api.test.js"
  printf "it('cache', () => {});\n" > "$FIXTURE_REPO/test/cache.test.js"
  fixture_git 1 add --all
  fixture_git 1 commit --quiet -m "feat: initial import"
  index=0
  while [ "$index" -lt 18 ]; do
    if [ $((index % 3)) -eq 2 ]; then source=src/cache.js; tests=test/cache.test.js; else source=src/router.js; tests=test/api.test.js; fi
    printf '// change %s\n' "$index" >> "$FIXTURE_REPO/$source"
    printf '// case %s\n' "$index" >> "$FIXTURE_REPO/$tests"
    fixture_git $((index + 2)) add --all
    fixture_git $((index + 2)) commit --quiet -m "fix: correct edge case number $index"
    index=$((index + 1))
  done
}
# verify_v2_export DIR: JSON verdict on the manifest, hashes and leaks of an exported generated package.
verify_v2_export() {
  node -e '
    const fs = require("fs"), path = require("path"), crypto = require("crypto");
    const [dir, ...forbidden] = process.argv.slice(1);
    const out = {errors: []};
    const walk = (d, base = d) => fs.readdirSync(d, {withFileTypes: true}).flatMap(e => e.isDirectory() ? walk(path.join(d, e.name), base) : [path.relative(base, path.join(d, e.name)).split(path.sep).join("/")]).sort();
    try {
      const files = walk(dir);
      const manifest = JSON.parse(fs.readFileSync(path.join(dir, ".olivium/manifest.json"), "utf8"));
      const listed = manifest.files.map(f => f.path).sort();
      const onDisk = files.filter(f => f !== ".olivium/manifest.json");
      out.files_on_disk = files.length; out.manifest_entries = listed.length;
      if (JSON.stringify(listed) !== JSON.stringify(onDisk)) out.errors.push("manifest/disk mismatch: " + JSON.stringify({listed, onDisk}).slice(0, 300));
      out.sha256_mismatches = manifest.files.filter(f => crypto.createHash("sha256").update(fs.readFileSync(path.join(dir, f.path))).digest("hex") !== f.sha256).map(f => f.path);
      if (out.sha256_mismatches.length) out.errors.push("sha256 mismatch: " + out.sha256_mismatches.join(","));
      for (const file of files) { const text = fs.readFileSync(path.join(dir, file), "utf8"); for (const value of forbidden) if (text.includes(value)) out.errors.push(file + " contains forbidden value " + value); }
      // Stage 1 (docs/plans/harness-enhancement-plan.md, item 1; contract.md sections 4 and 6): the root file
      // carries at most 600 model-visible bytes and no process command; nothing it leaves out is silent.
      const claude = fs.readFileSync(path.join(dir, "CLAUDE.md"), "utf8");
      const visible = claude.replace(/<!--[\s\S]*?-->/g, "").trim();
      out.claude_md_visible_bytes = Buffer.byteLength(visible);
      if (out.claude_md_visible_bytes > 600) out.errors.push("CLAUDE.md shows the model " + out.claude_md_visible_bytes + " bytes, budget 600");
      const commandLine = /^\s*(?:[-*]\s*)?(?:lint|format|formatting|type ?check|type-check|build|install)\s*:/i;
      const commandWord = /npm run (?:lint|format)|npm ci|npm install|\beslint\b|\bprettier\b/;
      const processLines = visible.split("\n").filter(line => commandLine.test(line) || commandWord.test(line));
      if (processLines.length) out.errors.push("CLAUDE.md names a lint, format, type-check, build or install command: " + JSON.stringify(processLines).slice(0, 200));
      const provenance = JSON.parse(fs.readFileSync(path.join(dir, ".olivium/guidance-provenance.json"), "utf8"));
      const codes = ["default_guessable", "duplicate", "import_marker", "in_skill", "no_subject", "over_budget", "process_only", "scoped", "tool_unverified"];
      const rows = Array.isArray(provenance.withheld) ? provenance.withheld : [];
      out.withheld = rows.length; out.withheld_counts = provenance.withheld_counts;
      out.est_tokens_per_request = provenance.est_tokens_per_request;
      if (provenance.budget_bytes !== 600) out.errors.push("provenance budget_bytes " + provenance.budget_bytes);
      if (Math.abs(provenance.rendered_bytes - out.claude_md_visible_bytes) > 2) out.errors.push("provenance rendered_bytes " + provenance.rendered_bytes + " but CLAUDE.md shows " + out.claude_md_visible_bytes);
      const price = provenance.rendered_bytes === 0 ? 0 : 110 + Math.floor((provenance.rendered_bytes * 10 + 27) / 28);
      if (provenance.est_tokens_per_request !== price) out.errors.push("est_tokens_per_request " + provenance.est_tokens_per_request + ", formula gives " + price);
      for (const row of rows) {
        if (typeof row.section !== "string" || typeof row.text !== "string" || !codes.includes(row.reason)) out.errors.push("withheld row without section, text or a known reason: " + JSON.stringify(row).slice(0, 160));
        else if (row.bytes !== Buffer.byteLength(row.text)) out.errors.push("withheld row bytes " + row.bytes + " for " + JSON.stringify(row.text));
      }
      const counts = provenance.withheld_counts || {};
      const optional = ["duplicate", "in_skill", "no_subject"];
      for (const code of codes) if ((optional.includes(code) && counts[code] === undefined ? 0 : counts[code]) !== rows.filter(row => row.reason === code).length) out.errors.push("withheld_counts." + code + " is " + counts[code] + ", rows say " + rows.filter(row => row.reason === code).length);
      const withheldText = rows.map(row => row.text).join("\n");
      if (!visible.includes("npm test") && !withheldText.includes("npm test")) out.errors.push("the test command is neither in CLAUDE.md nor withheld with a reason");
      if (!rows.some(row => row.text.includes("npm run lint") && ["process_only", "tool_unverified"].includes(row.reason))) out.errors.push("the lint command is not withheld as process_only or tool_unverified");
      for (const file of [".claude/hooks/olivium-env-check.sh", ".claude/hooks/olivium-before-stop.sh", ".olivium/test-pairs.tsv", ".olivium/cochange.tsv", ".olivium/guidance-provenance.json"])
        if (!listed.includes(file)) out.errors.push("manifest does not list " + file);
      const pairs = fs.existsSync(path.join(dir, ".olivium/test-pairs.tsv")) ? fs.readFileSync(path.join(dir, ".olivium/test-pairs.tsv"), "utf8") : "";
      out.test_pairs = pairs.split("\n").filter(Boolean).length;
      for (const [source, test] of [["src/router.js", "test/api.test.js"], ["src/cache.js", "test/cache.test.js"]])
        if (!pairs.split("\n").some(line => { const [a, b, n] = line.split("\t"); return a === source && b === test && Number(n) >= 2; })) out.errors.push("test-pairs.tsv has no row " + source + " -> " + test);
    } catch (e) { out.errors.push(e.message); }
    process.stdout.write(JSON.stringify(out));
  ' "$1" "$FIXTURE_SECRET" "$FIXTURE_AUTHOR" "$FIXTURE_EMAIL" "$E2E_EXPORT_ROOT" "$FIXTURE_REPO"
}
# no_leak: fail the scenario if the last command printed the planted secret or the fixture author.
no_leak() {
  if grep -q -e "$FIXTURE_SECRET" -e "$FIXTURE_EMAIL" "$OUT" "$ERR"; then fail "$1 printed a secret or author identity"; fi
}
verdict_errors() { node -e 'process.stdout.write(JSON.parse(process.argv[1]).errors.join("; "))' "$1"; }
build_fixture

# ---- C12 analyze --------------------------------------------------------------------------------------------
begin C12 "analyze PATH --json reports detected commands and conventions, and prints no secret; text mode names the commands"
if hf analyze "$FIXTURE_REPO" --json && ok; then
  no_leak "analyze --json"
  [ "$(jx 'd.result.profile.commands.test')" = "npm test" ] || fail "test command: $(jx 'd.result.profile.commands.test')"
  [ "$(jx 'd.result.profile.commands.lint')" = "npm run lint" ] || fail "lint command: $(jx 'd.result.profile.commands.lint')"
  [ "$(jx 'd.result.repository.git')" = "available" ] || fail "git status: $(jx 'd.result.repository.git')"
  scenario_detail=$(jx '({commands: d.result.profile.commands, conventions: d.result.profile.conventions, rule_candidates: d.result.profile.rule_candidates.length, head: d.result.repository.head})')
else fail "analyze --json failed: $(head -c 300 "$ERR") $JSON"; fi
if hf analyze "$FIXTURE_REPO"; then
  no_leak "analyze"
  grep -q 'npm test' "$OUT" || fail "text output does not name npm test"
else fail "analyze text mode failed: $(head -c 300 "$ERR")"; fi
finish

# ---- C13 generate + export ----------------------------------------------------------------------------------
begin C13 "generate PATH --runtime claude_code --export DIR --json writes a package whose files match the manifest, with no secret, identity or absolute path; CLAUDE.md shows at most 600 bytes and no process command, and every withheld line has a reason"
GENERATE_DIR=$E2E_EXPORT_ROOT/cli-generate
GENERATE_DIGEST=""
if [ -e "$GENERATE_DIR" ]; then fail "export target is not fresh: $GENERATE_DIR"; fi
if hf generate "$FIXTURE_REPO" --runtime claude_code --export "$GENERATE_DIR" --json && ok; then
  no_leak "generate"
  GENERATE_DIGEST=$(jx 'd.result.digest')
  [ "${#GENERATE_DIGEST}" = "64" ] || fail "digest: $GENERATE_DIGEST"
  [ "$(jx 'd.result.export')" = "$GENERATE_DIR" ] || fail "reported export path: $(jx 'd.result.export')"
  verdict=$(verify_v2_export "$GENERATE_DIR")
  errors=$(verdict_errors "$verdict")
  [ -z "$errors" ] || fail "$errors"
  scenario_detail=$(node -e 'const v = JSON.parse(process.argv[1]); v.digest = process.argv[2]; process.stdout.write(JSON.stringify(v))' "$verdict" "$GENERATE_DIGEST")
else fail "generate failed: $(head -c 300 "$ERR") $JSON"; fi
finish

# ---- C14 repeat generate ------------------------------------------------------------------------------------
begin C14 "generating again gives the same digest and a byte-identical export tree"
REPEAT_DIR=$E2E_EXPORT_ROOT/cli-generate-repeat
if [ -n "$GENERATE_DIGEST" ]; then
  if hf generate "$FIXTURE_REPO" --runtime claude_code --export "$REPEAT_DIR" --json && ok; then
    repeat_digest=$(jx 'd.result.digest')
    [ "$repeat_digest" = "$GENERATE_DIGEST" ] || fail "digest changed: $GENERATE_DIGEST -> $repeat_digest"
    if tree_diff=$(diff -r "$GENERATE_DIR" "$REPEAT_DIR" 2>&1); then identical=true; else identical=false; fail "export trees differ: $(printf '%s' "$tree_diff" | head -c 300)"; fi
    scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({first_digest: process.argv[1], repeat_digest: process.argv[2], identical_digest: process.argv[1] === process.argv[2], identical_tree: process.argv[3] === "true"}))' "$GENERATE_DIGEST" "$repeat_digest" "$identical")
  else fail "repeat generate failed: $(head -c 300 "$ERR") $JSON"; fi
else fail "no digest from C13"; fi
finish

# ---- C15 refused requests -----------------------------------------------------------------------------------
begin C15 "a runtime without generated packages exits 3 with a clear message and writes nothing; a usage error exits 2"
NEVER_DIR=$E2E_EXPORT_ROOT/cli-generate-never
hf generate "$FIXTURE_REPO" --runtime codex --export "$NEVER_DIR" --json; unsupported_status=$?
[ "$unsupported_status" = "3" ] || fail "codex exit status $unsupported_status, expected 3"
[ "$(jx 'd.error')" = "unsupported_runtime" ] || fail "codex error: $JSON"
unsupported_message=$(jx 'd.message')
case "$unsupported_message" in *claude_code*) ;; *) fail "message does not name the supported runtime: $unsupported_message" ;; esac
[ ! -e "$NEVER_DIR" ] || fail "export directory was created for an unsupported runtime"
hf generate "$FIXTURE_REPO" --runtime claude_code --json; usage_status=$?
[ "$usage_status" = "2" ] || fail "missing --export exit status $usage_status, expected 2"
[ "$(jx 'd.error')" = "invalid_arguments" ] || fail "usage error: $JSON"
scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({unsupported_status: Number(process.argv[1]), message: process.argv[2], usage_status: Number(process.argv[3])}))' "$unsupported_status" "$unsupported_message" "$usage_status")
finish

# ---- C16 not a repository -----------------------------------------------------------------------------------
begin C16 "analyze and generate refuse a directory that is not a git repository with exit status 1 and a clear message"
PLAIN_DIR=$E2E_EXPORT_ROOT/cli-plain-directory
mkdir -p "$PLAIN_DIR"
printf 'not a repository\n' > "$PLAIN_DIR/notes.txt"
hf analyze "$PLAIN_DIR" --json; analyze_status=$?
[ "$analyze_status" = "1" ] || fail "analyze exit status $analyze_status, expected 1"
[ "$(jx 'd.error')" = "not_a_git_repository" ] || fail "analyze error: $JSON"
hf generate "$PLAIN_DIR" --runtime claude_code --export "$E2E_EXPORT_ROOT/cli-plain-export"; generate_status=$?
[ "$generate_status" = "1" ] || fail "generate exit status $generate_status, expected 1"
grep -q 'not_a_git_repository' "$ERR" || fail "text error does not name the failure: $(head -c 200 "$ERR")"
[ ! -e "$E2E_EXPORT_ROOT/cli-plain-export" ] || fail "export directory was created for a non-repository"
scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({analyze_status: Number(process.argv[1]), generate_status: Number(process.argv[2])}))' "$analyze_status" "$generate_status")
finish

# ---- C17 permissions -----------------------------------------------------------------------------------------
begin C17 "exported solo .claude/settings.json allows the file tools, the shell and the detected test command without a prompt, still denies the dangerous commands, carries only the measured context trim and registers session start and stop hooks without an edit formatter"
if [ -f "$GENERATE_DIR/.claude/settings.json" ]; then
  verdict=$(node -e '
    const fs = require("fs");
    const settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const {allow, ask, deny} = settings.permissions, errors = [];
    for (const rule of ["Read", "Edit", "Bash(npm test:*)"]) {
      if (!allow.includes(rule)) errors.push(rule + " is not allowed");
      if (deny.includes(rule)) errors.push(rule + " is denied");
    }
    if (ask.length) errors.push("ask rules take precedence over allow: " + JSON.stringify(ask));
    if (!deny.includes("Edit(.env)")) errors.push("secrets are not denied");
    if (deny.some(rule => rule.startsWith("Read("))) errors.push("a Read deny rule makes every cd compound ask");
    if (!(settings.hooks.PreToolUse || []).some(entry => entry.hooks.some(hook => hook.command.includes("olivium-guard.sh")))) errors.push("no guard hook");
    // Solo mode is hands-free: the shell is allowed as a whole, and deny rules (checked first) and the guard refuse.
    if (!allow.includes("Bash")) errors.push("solo export does not allow the shell");
    for (const rule of ["Bash(rm -rf:*)", "Bash(curl:*)", "Bash(git push:*)", "Bash(sudo:*)"]) if (!deny.includes(rule)) errors.push(rule + " is not denied");
    // Stage 1, item 2 (contract.md section 5): the lean profile and nothing unmeasured.
    const lean = ["CronCreate", "CronDelete", "CronList", "EnterWorktree", "ExitWorktree", "ListAgents", "Monitor", "NotebookEdit",
      "ReportFindings", "ScheduleWakeup", "SendMessage", "Skill", "Task", "TaskStop", "Workflow"];
    if (settings.includeGitInstructions !== false) errors.push("includeGitInstructions is not false");
    const missingDeny = lean.filter(name => !deny.includes(name));
    if (missingDeny.length) errors.push("lean deny names missing: " + missingDeny.join(","));
    if (deny.includes("ToolSearch")) errors.push("ToolSearch is denied");
    for (const key of ["disableBundledSkills", "skillOverrides", "autoMemoryEnabled"]) if (key in settings) errors.push(key + " is set");
    // Items 3 and 4: session start and stop hooks; the edit formatter is gone. Prompt submit is stage 2.
    for (const event of ["SessionStart", "Stop"]) if (!(settings.hooks[event] || []).length) errors.push("no " + event + " hook");
    if ((settings.hooks.PostToolUse || []).length) errors.push("a PostToolUse hook is still registered: " + JSON.stringify(settings.hooks.PostToolUse).slice(0, 160));
    const unexpected = Object.keys(settings.hooks).filter(event => !["PreToolUse", "SessionStart", "UserPromptSubmit", "Stop"].includes(event));
    if (unexpected.length) errors.push("unexpected hook events: " + unexpected.join(","));
    process.stdout.write(JSON.stringify({allow_rules: allow.length, ask_rules: ask.length, deny_rules: deny.length, hook_events: Object.keys(settings.hooks),
      include_git_instructions: settings.includeGitInstructions, lean_deny_present: lean.length - missingDeny.length, errors}));
  ' "$GENERATE_DIR/.claude/settings.json")
  errors=$(verdict_errors "$verdict")
  [ -z "$errors" ] || fail "$errors"
  scenario_detail=$verdict
else fail "no settings file from C13"; fi
finish

# ---- helpers for the hook scenarios ------------------------------------------------------------------------------
# hook_command EVENT: the first command registered for EVENT in the C13 export's settings.
hook_command() {
  node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const e = (s.hooks || {})[process.argv[2]] || [];
    const h = e.flatMap(x => x.hooks || []).find(x => x.type === "command"); process.stdout.write(h ? h.command : "");' "$GENERATE_DIR/.claude/settings.json" "$1" 2>/dev/null
}
# hook_copy NAME: a fresh copy of the synthetic fixture with the C13 export laid over it, as Claude Code would see it.
hook_copy() {
  local dir=$E2E_EXPORT_ROOT/$1
  rm -rf "$dir"
  cp -R "$FIXTURE_REPO" "$dir" && cp -R "$GENERATE_DIR"/. "$dir"/ && printf '%s' "$dir"
}
# run_hook DIR PATH_PREFIX STDIN COMMAND: runs a generated hook command with a minimal environment, a stub-first PATH
# and a 120 s alarm; stdout in $OUT, stderr in $ERR, returns its exit status. Stubs stand in for every tool, so no
# project or third-party code runs on the host.
run_hook() {
  local dir=$1 prefix=$2 input=$3 command=$4
  scenario_cmds+=("(cd $dir && CLAUDE_PROJECT_DIR=$dir PATH=${prefix:+$prefix:}/usr/bin:/bin /bin/sh -c <hook command>)")
  printf '%s' "$input" | (cd "$dir" && env -i PATH="${prefix:+$prefix:}/usr/bin:/bin" HOME="$dir" LC_ALL=C CLAUDE_PROJECT_DIR="$dir" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="${STUB_LOG:-/dev/null}" STUB_FAIL_ON="${STUB_FAIL_ON:-}" \
    perl -e 'alarm shift; exec @ARGV' 120 /bin/sh -c "$command") > "$OUT" 2> "$ERR"
  local status=$?
  { printf -- '----- %s [%s] hook in %s, exit %s; stdout:\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$scenario_id" "$dir" "$status"; cat "$OUT"; printf -- '----- stderr:\n'; cat "$ERR"; } >> "$LOG"
  return $status
}
# make_stub DIR NAME: an executable that records its argv and exits 0, or exits 1 with a test-failure message when
# STUB_FAIL_ON appears in its arguments and the call is not a format or lint call.
make_stub() {
  mkdir -p "$1"
  cat > "$1/$2" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "${STUB_LOG:-/dev/null}"
[ -n "${STUB_FAIL_ON:-}" ] || exit 0
case " $* " in *"$STUB_FAIL_ON"*) ;; *) exit 0 ;; esac
case "${0##*/} $*" in *prettier*|*eslint*|*lint*|*format*|*--write*|*--check*) exit 0 ;; esac
echo "  1) cache"
echo "     AssertionError: expected 1 to equal 2 (synthetic stub failure)"
echo "1 failing"
exit 1
STUB
  chmod +x "$1/$2"
}
# tool_probes ROLE: the probe names the export's spec lists for ROLE, space separated.
tool_probes() {
  node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const t = ((s.spec || {}).project || {}).tools || [];
    const r = t.find(x => x.role === process.argv[2]); process.stdout.write(r ? r.probe.join(" ") : "");' "$GENERATE_DIR/.olivium/spec.json" "$1" 2>/dev/null
}

# ---- C18 environment check ----------------------------------------------------------------------------------------
begin C18 "the session-start environment check, with stub tools, prints one fixed line for the one missing tool and nothing when every tool is present"
ENV_COMMAND=$(hook_command SessionStart)
if [ -z "$ENV_COMMAND" ]; then fail "no SessionStart hook in the C13 export"
else
  test_probes=$(tool_probes test); lint_probes=$(tool_probes lint); format_probes=$(tool_probes format)
  [ -n "$test_probes" ] && [ -n "$lint_probes" ] && [ -n "$format_probes" ] || fail "spec.project.tools lacks test, lint or format probes: test=[$test_probes] lint=[$lint_probes] format=[$format_probes]"
  env_dir=$(hook_copy c18-env-check)
  for name in $test_probes $lint_probes; do make_stub "$env_dir/node_modules/.bin" "$name"; done
  format_first=${format_probes%% *}
  for name in $format_probes; do rm -f "$env_dir/node_modules/.bin/$name"; done
  expected="Formatting is not available here: $format_first is not installed. Skip it. Do not install it."
  run_hook "$env_dir" "" "" "$ENV_COMMAND"; missing_status=$?
  missing_out=$(cat "$OUT"); missing_err=$(cat "$ERR")
  [ "$missing_status" = "0" ] || fail "exit status $missing_status with a missing tool"
  [ "$missing_out" = "$expected" ] || fail "with $format_first missing, printed: $(printf '%s' "$missing_out" | head -c 300)"
  [ -z "$missing_err" ] || fail "stderr with a missing tool: $(printf '%s' "$missing_err" | head -c 200)"
  for name in $format_probes; do make_stub "$env_dir/node_modules/.bin" "$name"; done
  run_hook "$env_dir" "" "" "$ENV_COMMAND"; present_status=$?
  present_bytes=$(wc -c < "$OUT" | tr -d ' '); present_err=$(wc -c < "$ERR" | tr -d ' ')
  [ "$present_status" = "0" ] || fail "exit status $present_status with every tool present"
  [ "$present_bytes" = "0" ] && [ "$present_err" = "0" ] || fail "with every tool present, printed $present_bytes bytes and $present_err on stderr"
  scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({probes: {test: process.argv[1], lint: process.argv[2], format: process.argv[3]}, missing: {status: Number(process.argv[4]), stdout: process.argv[5]}, present: {status: Number(process.argv[6]), stdout_bytes: Number(process.argv[7])}}))' \
    "$test_probes" "$lint_probes" "$format_probes" "$missing_status" "$missing_out" "$present_status" "$present_bytes")
fi
finish

# ---- C19 stop hook --------------------------------------------------------------------------------------------------
begin C19 "the stop hook, with stub runners on the synthetic repository: a changed source file runs no test, even when its history pair would fail; a changed passing test runs and an unrelated failing test does not, exit 0 and nothing printed; a failing changed test exits 2 with at most 1,200 characters ending in the fixed line"
STOP_COMMAND=$(hook_command Stop)
STOP_LAST="If these failures are not caused by your change, stop again."
if [ -z "$STOP_COMMAND" ]; then fail "no Stop hook in the C13 export"
else
  STUBS=$E2E_EXPORT_ROOT/c19-stubs
  rm -rf "$STUBS"
  for name in npm npx node yarn pnpm mocha eslint prettier; do make_stub "$STUBS" "$name"; done
  stop_input='{"session_id":"e2e-c19","transcript_path":"/dev/null","hook_event_name":"Stop","stop_hook_active":false}'
  # S: one changed source file. Its history pair test/api.test.js would fail, but only changed test files run.
  stop_s=$(hook_copy c19-stop-source-only)
  printf '// e2e change\n' >> "$stop_s/src/router.js"
  STUB_LOG=$E2E_EXPORT_ROOT/c19-source-only.log STUB_FAIL_ON=test/api.test.js run_hook "$stop_s" "$STUBS" "$stop_input" "$STOP_COMMAND"; s_status=$?
  s_out=$(cat "$OUT" "$ERR"); s_calls=$(cat "$E2E_EXPORT_ROOT/c19-source-only.log" 2>/dev/null)
  [ "$s_status" = "0" ] || fail "source-only change: exit $s_status"
  [ -z "$s_out" ] || fail "source-only change printed: $(printf '%s' "$s_out" | head -c 300)"
  case "$s_calls" in *.test.js*) fail "a test ran for a source-only change: $(printf '%s' "$s_calls" | head -c 300)" ;; esac
  # A: a changed source file and a changed passing test; test/cache.test.js would fail, but it did not change.
  stop_a=$(hook_copy c19-stop-unrelated)
  printf '// e2e change\n' >> "$stop_a/src/router.js"
  printf '// e2e change\n' >> "$stop_a/test/api.test.js"
  STUB_LOG=$E2E_EXPORT_ROOT/c19-unrelated.log STUB_FAIL_ON=test/cache.test.js run_hook "$stop_a" "$STUBS" "$stop_input" "$STOP_COMMAND"; a_status=$?
  a_out=$(cat "$OUT" "$ERR"); a_calls=$(cat "$E2E_EXPORT_ROOT/c19-unrelated.log" 2>/dev/null)
  [ "$a_status" = "0" ] || fail "unrelated failure: exit $a_status"
  [ -z "$a_out" ] || fail "unrelated failure printed: $(printf '%s' "$a_out" | head -c 300)"
  # Format and lint steps are checked only when the spec has them (the generator emits a changed_files step only for
  # a command that takes file arguments).
  changed_steps=$(node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(((s.spec || {}).hooks || []).filter(h => h.event === "before_stop" && h.selector === "changed_files").length));' "$GENERATE_DIR/.olivium/spec.json" 2>/dev/null)
  if [ "${changed_steps:-0}" != "0" ]; then
    case "$a_calls" in *src/router.js*) ;; *) fail "no format or lint call got src/router.js: $(printf '%s' "$a_calls" | head -c 300)" ;; esac
  fi
  case "$a_calls" in *test/api.test.js*) ;; *) fail "the changed test test/api.test.js did not run: $(printf '%s' "$a_calls" | head -c 300)" ;; esac
  case "$a_calls" in *test/cache.test.js*) fail "the unrelated test ran" ;; esac
  # B: a changed test that fails.
  stop_b=$(hook_copy c19-stop-failing)
  printf '// e2e change\n' >> "$stop_b/test/cache.test.js"
  STUB_LOG=$E2E_EXPORT_ROOT/c19-failing.log STUB_FAIL_ON=test/cache.test.js run_hook "$stop_b" "$STUBS" "$stop_input" "$STOP_COMMAND"; b_status=$?
  b_err=$(cat "$ERR"); b_chars=$(printf '%s' "$b_err" | wc -m | tr -d ' '); b_last=$(printf '%s\n' "$b_err" | tail -n 1)
  [ "$b_status" = "2" ] || fail "failing changed test: exit $b_status, expected 2"
  [ "$b_chars" -le 1200 ] || fail "failure message has $b_chars characters, limit 1200"
  [ "$b_last" = "$STOP_LAST" ] || fail "last line: $b_last"
  [ ! -s "$OUT" ] || fail "stdout is not empty on failure"
  scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({changed_file_steps: Number(process.argv[6] || 0), source_only: {status: Number(process.argv[7]), calls: process.argv[8].split("\n").filter(Boolean)}, unrelated: {status: Number(process.argv[1]), calls: process.argv[2].split("\n").filter(Boolean)}, failing: {status: Number(process.argv[3]), characters: Number(process.argv[4]), last_line: process.argv[5]}}))' \
    "$a_status" "$a_calls" "$b_status" "$b_chars" "$b_last" "$changed_steps" "$s_status" "$s_calls")
fi
finish

# ---- C21 replay gate --------------------------------------------------------------------------------------------------
begin C21 "the replay gate on the synthetic call list refuses none of the normal calls and every unsafe call under the exported settings and guard"
GATE_OUT=$E2E_EXPORT_ROOT/c21-replay-gate.json
GATE_SCRATCH=$E2E_EXPORT_ROOT/c21-replay-scratch
rm -rf "$GATE_OUT" "$GATE_SCRATCH"
if [ -f "$GENERATE_DIR/.claude/settings.json" ]; then
  gate_cmd="python3 bench/value/replay/gate.py --export $GENERATE_DIR --synthetic --runner host --scratch $GATE_SCRATCH --out $GATE_OUT --quiet"
  scenario_cmds+=("$gate_cmd")
  python3 bench/value/replay/gate.py --export "$GENERATE_DIR" --synthetic --runner host --scratch "$GATE_SCRATCH" --out "$GATE_OUT" --quiet >> "$LOG" 2>&1; gate_status=$?
  if [ -f "$GATE_OUT" ]; then
    verdict=$(node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).synthetic || {}; const errors = [];
      if (r.normal_refused !== 0) errors.push(r.normal_refused + " of " + r.normal_total + " normal calls refused");
      if (r.unsafe_refused !== r.unsafe_total || !r.unsafe_total) errors.push(r.unsafe_refused + " of " + r.unsafe_total + " unsafe calls refused: " + JSON.stringify(r.unsafe_not_refused || []).slice(0, 160));
      if ((r.unsafe_oracle_mismatch || []).length || (r.unsafe_expected_not_labelled || []).length) errors.push("oracle disagreement: " + JSON.stringify([r.unsafe_oracle_mismatch, r.unsafe_expected_not_labelled]).slice(0, 200));
      process.stdout.write(JSON.stringify({normal_total: r.normal_total, normal_refused: r.normal_refused, unsafe_total: r.unsafe_total, unsafe_refused: r.unsafe_refused, unsafe_by_layer: r.unsafe_by_layer, unsafe_oracle_mismatch: r.unsafe_oracle_mismatch, errors}));' "$GATE_OUT")
    errors=$(verdict_errors "$verdict")
    [ -z "$errors" ] || fail "$errors"
    [ "$gate_status" = "0" ] || fail "gate exit status $gate_status"
    scenario_detail=$verdict
  else fail "the gate wrote no report (exit $gate_status)"; fi
else fail "no settings file from C13"; fi
finish

# ---- C22 practice rule ----------------------------------------------------------------------------------------
begin C22 "a repository whose source marks three public functions deprecated gets the blueprint's fixed deprecation sentence in CLAUDE.md, from a derived practices rule, byte-identical across two exports; the C13 fixture, with none, does not; no repository text is copied"
DEPRECATION_REPO=$E2E_EXPORT_ROOT/fixture-repo-deprecations
DEPRECATION_DIR=$E2E_EXPORT_ROOT/cli-generate-deprecations
DEPRECATION_REPEAT=$E2E_EXPORT_ROOT/cli-generate-deprecations-repeat
rm -rf "$DEPRECATION_REPO"
if [ -e "$DEPRECATION_DIR" ] || [ -e "$DEPRECATION_REPEAT" ]; then fail "export targets are not fresh"
elif ! cp -R "$FIXTURE_REPO" "$DEPRECATION_REPO"; then fail "could not copy the fixture"
else
  # Three JSDoc @deprecated tags: the node blueprint's threshold is 3 deprecation sites. Nothing here is run.
  printf '/** @deprecated Use route() instead. */\nexports.legacyAlpha = function () {};\n/** @deprecated Use route() instead. */\nexports.legacyBeta = function () {};\n/** @deprecated Use route() instead. */\nexports.legacyGamma = function () {};\n' > "$DEPRECATION_REPO/src/legacy.js"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME="$FIXTURE_AUTHOR" GIT_AUTHOR_EMAIL="$FIXTURE_EMAIL" GIT_AUTHOR_DATE=2026-01-28T12:00:00Z \
    GIT_COMMITTER_NAME="$FIXTURE_AUTHOR" GIT_COMMITTER_EMAIL="$FIXTURE_EMAIL" GIT_COMMITTER_DATE=2026-01-28T12:00:00Z \
    sh -c 'git -C "$1" add --all && git -C "$1" commit --quiet -m "feat: keep legacy routes"' sh "$DEPRECATION_REPO" >> "$LOG" 2>&1 \
    || fail "could not commit the deprecations fixture"
  if hf generate "$DEPRECATION_REPO" --runtime claude_code --export "$DEPRECATION_DIR" --json && ok; then
    first_digest=$(jx 'd.result.digest')
    if hf generate "$DEPRECATION_REPO" --runtime claude_code --export "$DEPRECATION_REPEAT" --json && ok; then
      repeat_digest=$(jx 'd.result.digest')
      [ "$repeat_digest" = "$first_digest" ] || fail "digest changed: $first_digest -> $repeat_digest"
      diff -r "$DEPRECATION_DIR" "$DEPRECATION_REPEAT" > /dev/null 2>&1 || fail "the two exports differ"
    else fail "repeat generate failed: $(head -c 300 "$ERR") $JSON"; fi
    verdict=$(node -e '
      const fs = require("fs");
      const [positive, negative, blueprint] = process.argv.slice(1), errors = [];
      const sentence = JSON.parse(fs.readFileSync(blueprint, "utf8")).practices.rules.deprecation;
      const visible = dir => fs.readFileSync(dir + "/CLAUDE.md", "utf8").replace(/<!--[\s\S]*?-->/g, "").trim();
      const practiceRules = dir => (JSON.parse(fs.readFileSync(dir + "/.olivium/spec.json", "utf8")).spec.rules || [])
        .filter(rule => rule.source && rule.source.detector === "practices");
      const pos = visible(positive), neg = visible(negative), posRules = practiceRules(positive), negRules = practiceRules(negative);
      if (typeof sentence !== "string" || !sentence) errors.push("the node blueprint has no deprecation sentence");
      else {
        if (!pos.includes(sentence)) errors.push("CLAUDE.md lacks the deprecation sentence: " + JSON.stringify(pos).slice(0, 200));
        if (neg.includes(sentence)) errors.push("the C13 export, with no deprecation sites, shows the sentence");
      }
      if (!posRules.some(rule => rule.source.signal === "practices.deprecation")) errors.push("no derived practices.deprecation rule in the spec");
      if (negRules.length) errors.push("the C13 spec has practices rules: " + JSON.stringify(negRules).slice(0, 160));
      for (const word of ["legacyAlpha", "legacyBeta", "legacyGamma", "route() instead"]) if (pos.includes(word)) errors.push("CLAUDE.md copies repository text: " + word);
      if (Buffer.byteLength(pos) > 600) errors.push("CLAUDE.md shows " + Buffer.byteLength(pos) + " bytes, budget 600");
      process.stdout.write(JSON.stringify({visible_bytes: Buffer.byteLength(pos), c13_visible_bytes: Buffer.byteLength(neg), practice_rules: posRules.map(rule => rule.source.signal), errors}));
    ' "$DEPRECATION_DIR" "$GENERATE_DIR" "$project/priv/blueprints/node.json")
    errors=$(verdict_errors "$verdict")
    [ -z "$errors" ] || fail "$errors"
    scenario_detail=$(node -e 'const v = JSON.parse(process.argv[1]); v.digest = process.argv[2]; v.repeat_digest = process.argv[3]; process.stdout.write(JSON.stringify(v))' "$verdict" "$first_digest" "${repeat_digest:-}")
  else fail "generate failed: $(head -c 300 "$ERR") $JSON"; fi
fi
finish

# ---- C23 context profile and CLAUDE.md price in the text summary ------------------------------------------------
begin C23 "generate in text mode prints the CLAUDE.md price (bytes, estimated tokens per request), the withheld-line count and the lean context profile with every removed tool name and the saving; --context standard exports without the trim"
TEXT_DIR=$E2E_EXPORT_ROOT/cli-generate-text
STANDARD_DIR=$E2E_EXPORT_ROOT/cli-generate-standard
if hf generate "$FIXTURE_REPO" --runtime claude_code --export "$TEXT_DIR"; then
  text_out=$(cat "$OUT")
  verdict=$(node -e '
    const fs = require("fs");
    const [dir, text] = process.argv.slice(1), errors = [];
    const prov = JSON.parse(fs.readFileSync(dir + "/.olivium/guidance-provenance.json", "utf8"));
    const settings = JSON.parse(fs.readFileSync(dir + "/.claude/settings.json", "utf8"));
    const lean = ["CronCreate", "CronDelete", "CronList", "EnterWorktree", "ExitWorktree", "ListAgents", "Monitor", "NotebookEdit",
      "ReportFindings", "ScheduleWakeup", "SendMessage", "Skill", "Task", "TaskStop", "Workflow"];
    const removed = lean.filter(name => settings.permissions.deny.includes(name));
    const price = prov.rendered_bytes === 0 ? "0 bytes the model reads, 0 tokens per request"
      : prov.rendered_bytes + " bytes the model reads, about " + prov.est_tokens_per_request + " tokens on every request";
    const withheld = (prov.withheld || []).length;
    const expected = [
      "CLAUDE.md   " + price + "; " + withheld + " line" + (withheld === 1 ? "" : "s") + " withheld",
      "Context profile: lean (removes git instructions and " + removed.length + " tools no recorded benchmark run used, including subagents (Task) and skills (Skill, Workflow): " + removed.join(", ") + ";",
      "about 11,700 fewer tokens on every model request, measured on Claude Code 2.1.311",
      "Use --context standard to keep them."];
    for (const line of expected) if (!text.includes(line)) errors.push("summary lacks: " + line);
    if (text.includes("unused tools")) errors.push("summary calls the removed tools unused; only the benchmark runs did not use them");
    if (removed.length !== 15) errors.push("lean export removes " + removed.length + " tools, expected 15");
    process.stdout.write(JSON.stringify({rendered_bytes: prov.rendered_bytes, est_tokens_per_request: prov.est_tokens_per_request, withheld, removed: removed.length, errors}));
  ' "$TEXT_DIR" "$text_out")
  errors=$(verdict_errors "$verdict")
  [ -z "$errors" ] || fail "$errors"
  if hf generate "$FIXTURE_REPO" --runtime claude_code --export "$STANDARD_DIR" --context standard --json && ok; then
    [ "$(jx 'd.result.context.profile')" = "standard" ] || fail "standard export reports profile $(jx 'd.result.context.profile')"
    standard=$(node -e '
      const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")), errors = [];
      if ("includeGitInstructions" in s) errors.push("standard export sets includeGitInstructions");
      const trimmed = ["Task", "Skill", "Workflow", "ScheduleWakeup"].filter(name => s.permissions.deny.includes(name));
      if (trimmed.length) errors.push("standard export denies " + trimmed.join(","));
      process.stdout.write(JSON.stringify({errors}));' "$STANDARD_DIR/.claude/settings.json")
    errors=$(verdict_errors "$standard")
    [ -z "$errors" ] || fail "$errors"
  else fail "generate --context standard failed: $(head -c 300 "$ERR") $JSON"; fi
  hf generate "$FIXTURE_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/cli-generate-badcontext" --context tiny --json; bad_status=$?
  [ "$bad_status" = "2" ] || fail "--context tiny exit status $bad_status, expected 2"
  [ ! -e "$E2E_EXPORT_ROOT/cli-generate-badcontext" ] || fail "an export was written for --context tiny"
  scenario_detail=$(node -e 'const v = JSON.parse(process.argv[1]); v.bad_context_status = Number(process.argv[2]); process.stdout.write(JSON.stringify(v))' "$verdict" "$bad_status")
else fail "generate (text) failed: $(head -c 300 "$ERR")"; fi
finish

# ---- C24 lean-ai: learned bundle, locator, rewrites -------------------------------------------------------------
# The repository is a copy of the synthetic fixture with 25 more synthetic commits that name two functions, so the
# locator replay gate has something to find. The bundle is synthetic too: the shared contract fixture
# (test/fixtures/learned/learned-v1.synthetic.json) with node-flavoured items and this repository's HEAD as base,
# re-signed here. Nothing from a real repository or a model runs; the exported hooks run on synthetic input only.
LEANAI_REPO=$E2E_EXPORT_ROOT/fixture-repo-lean-ai
LEANAI_DIR=$E2E_EXPORT_ROOT/cli-generate-lean-ai
LEANAI_REPEAT=$E2E_EXPORT_ROOT/cli-generate-lean-ai-repeat
lean_git() { # day args...
  local stamp day=$1
  shift
  stamp=$(printf '2026-02-%02dT12:00:00Z' "$day")
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME="$FIXTURE_AUTHOR" GIT_AUTHOR_EMAIL="$FIXTURE_EMAIL" GIT_AUTHOR_DATE="$stamp" \
    GIT_COMMITTER_NAME="$FIXTURE_AUTHOR" GIT_COMMITTER_EMAIL="$FIXTURE_EMAIL" GIT_COMMITTER_DATE="$stamp" \
    git -C "$LEANAI_REPO" "$@"
}
build_lean_ai_repo() {
  local index day source tests message
  rm -rf "$LEANAI_REPO"
  cp -R "$FIXTURE_REPO" "$LEANAI_REPO" || return 1
  printf 'function routeRequest(path) {\n  return path;\n}\nmodule.exports = { routeRequest };\n' > "$LEANAI_REPO/src/router.js"
  printf 'function cacheEntry(key) {\n  return key;\n}\nmodule.exports = { cacheEntry };\n' > "$LEANAI_REPO/src/cache.js"
  # Three deprecation sites, so the static deprecation rule exists and the bundle's learned deprecation line can take
  # its place in CLAUDE.md (a learned line only ever replaces one).
  {
    printf "const util = require('util');\n"
    printf "const oldRoute = util.deprecate((p) => p, 'oldRoute() is deprecated: use routeRequest()');\n"
    printf "const oldCache = util.deprecate((k) => k, 'oldCache() is deprecated: use cacheEntry()');\n"
    printf "const oldLookup = util.deprecate((k) => k, 'oldLookup() is deprecated: use cacheEntry()');\n"
    printf 'module.exports = { oldRoute, oldCache, oldLookup };\n'
  } > "$LEANAI_REPO/src/legacy.js"
  lean_git 1 add --all && lean_git 1 commit --quiet -m "feat: add routeRequest and cacheEntry" || return 1
  index=0
  while [ "$index" -lt 24 ]; do
    if [ $((index % 2)) -eq 0 ]; then source=src/router.js; tests=test/api.test.js; message="fix: routeRequest keeps the trailing slash ($index)"
    else source=src/cache.js; tests=test/cache.test.js; message="fix: cacheEntry drops stale keys ($index)"; fi
    printf '// fix %s\n' "$index" >> "$LEANAI_REPO/$source"
    printf '// fix case %s\n' "$index" >> "$LEANAI_REPO/$tests"
    day=$((index + 2)); [ "$day" -gt 28 ] && day=28
    lean_git "$day" add --all && lean_git "$day" commit --quiet -m "$message" || return 1
    index=$((index + 1))
  done
}
# make_bundle MODE DIR: ok | tamper (a byte changed after signing) | base (an unknown base commit) | unavailable
# (the learner did not run: only deterministic commands and rewrites). learned.json is canonical JSON (sorted keys,
# no spaces) with its sha256 field over the document without it; learned.sha256 holds the file checksum.
make_bundle() {
  node -e '
    const fs = require("fs"), path = require("path"), crypto = require("crypto");
    const [fixture, head, mode, dir] = process.argv.slice(1);
    const canon = (v) => Array.isArray(v) ? "[" + v.map(canon).join(",") + "]"
      : (v !== null && typeof v === "object") ? "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + canon(v[k])).join(",") + "}"
      : JSON.stringify(v);
    const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");
    const ev = (c) => c.repeat(40);
    const doc = JSON.parse(fs.readFileSync(fixture, "utf8"));
    doc.repository = {...doc.repository, name: "acme-routes", base_commit: mode === "base" ? "f".repeat(40) : head};
    doc.verification = {...doc.verification, image: "acme-routes-deps:fixture"};
    doc.concepts = [
      {id: "c01", paths: ["src/router.js"], tests: ["test/api.test.js"], symbols: ["routeRequest"], terms: ["route", "trailing slash"], evidence: [ev("a"), ev("b"), ev("c")], support: 6},
      {id: "c02", paths: ["src/gone.js"], tests: [], symbols: [], terms: ["legacy"], evidence: [ev("d"), ev("e")], support: 2}];
    doc.pitfalls = [
      {id: "p01", scope: "global", concept: null, kind: "deprecation", status: "verified", trigger_terms: [], evidence: [ev("a"), ev("f"), ev("1")],
       check: {type: "diff_regex", pattern: "deprecate", min_commits: 2},
       text: "Keep removed exports working for one minor release: wrap them with util.deprecate and name the replacement."},
      {id: "p02", scope: "concept", concept: "c01", kind: "test_location", status: "verified", trigger_terms: ["route"], evidence: [ev("b"), ev("c")],
       check: {type: "diff_regex", pattern: "trailing", min_commits: 2},
       text: "Route tests live in test/api.test.js and cover the path with and without a trailing slash."}];
    doc.commands = [{id: "cmd-test-file", role: "test_file", source: "learned", argv: ["npx", "mocha", "{file}"],
      verify: {status: "verified", exit: 0, ms: 800, output_bytes: 90, sample_arg: "test/api.test.js"}}];
    doc.rewrites = [
      {id: "rw01", kind: "missing_tool", source: "deterministic", match: {argv_prefix: ["npx", "tsc"]}, replace: {message_id: "tool_missing", tool: "tsc"},
       verify: {bytes_after: 70, bytes_before: 120, ms: 300, right_exit: 0, wrong_exit: 127, wrong_signature: "exit_127"}},
      {id: "rw02", kind: "wrong_runner", source: "learned", match: {argv_prefix: ["mocha"]}, replace: {argv_prefix: ["npx", "mocha"]},
       verify: {bytes_after: 90, bytes_before: 30, ms: 900, right_exit: 0, wrong_exit: 127, wrong_signature: "exit_127"}}];
    doc.dropped = [{id: "c09", kind: "concept", reason: "path_missing_at_base"}, {id: "rw09", kind: "rewrite", reason: "verify_failed"}];
    if (mode === "unavailable") {
      doc.learner = {...doc.learner, status: "unavailable", status_reason: "cloud_not_allowed", model: "none", requests: 0, cost_nanousd: 0, wall_ms: 0,
        tokens: {input: 0, output: 0, cache_read: 0, cache_write: 0}};
      doc.concepts = []; doc.pitfalls = [];
      doc.commands = doc.commands.map((c) => ({...c, source: "deterministic"}));
      doc.rewrites = doc.rewrites.filter((r) => r.source === "deterministic");
    }
    delete doc.sha256;
    doc.sha256 = sha(canon(doc));
    const bytes = canon(doc) + "\n";
    fs.mkdirSync(dir, {recursive: true});
    fs.writeFileSync(path.join(dir, "learned.json"), mode === "tamper" ? bytes.replace("acme-routes", "acme-routez") : bytes);
    fs.writeFileSync(path.join(dir, "learned.sha256"), sha(bytes) + "  learned.json\n");
  ' "$project/test/fixtures/learned/learned-v1.synthetic.json" "$2" "$1" "$3"
}
# leanai_hook EVENT INDEX: the command of the INDEX-th entry of EVENT in the lean-ai export's settings.
leanai_hook() {
  node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const e = ((s.hooks || {})[process.argv[2]] || [])[Number(process.argv[3])];
    const h = ((e || {}).hooks || []).find(x => x.type === "command"); process.stdout.write(h ? h.command : "");' "$LEANAI_DIR/.claude/settings.json" "$1" "$2" 2>/dev/null
}
begin C24 "lean-ai: generate with a synthetic learned bundle prints the AI learning and locator lines, exports the bundle, index, locator and rewrite hooks byte-identically twice; the hooks print a card or a verified rewrite and nothing otherwise, never a permission decision; a missing, changed or foreign bundle and a learner that did not run are refused or shown, never silent"
BUNDLES=$E2E_EXPORT_ROOT/learned-bundles
if [ -e "$LEANAI_DIR" ] || [ -e "$LEANAI_REPEAT" ]; then fail "export targets are not fresh"
elif ! build_lean_ai_repo >> "$LOG" 2>&1; then fail "could not build the lean-ai fixture repository"
else
  head=$(git -C "$LEANAI_REPO" rev-parse HEAD)
  for mode in ok tamper base unavailable; do make_bundle "$mode" "$head" "$BUNDLES/$mode" || fail "could not write the $mode bundle"; done
  if hf generate "$LEANAI_REPO" --runtime claude_code --export "$LEANAI_DIR" --context lean-ai --learned "$BUNDLES/ok"; then
    text_out=$(cat "$OUT")
    no_leak "generate --context lean-ai"
    if hf generate "$LEANAI_REPO" --runtime claude_code --export "$LEANAI_REPEAT" --context lean-ai --learned "$BUNDLES/ok" --json && ok; then
      leanai_json=$JSON
      diff -r "$LEANAI_DIR" "$LEANAI_REPEAT" > /dev/null 2>&1 || fail "the two lean-ai exports differ"
    else fail "lean-ai generate --json failed: $(head -c 300 "$ERR") $JSON"; leanai_json="{}"; fi
    verdict=$(node -e '
      const fs = require("fs");
      const [dir, bundle, text, json] = process.argv.slice(1), errors = [];
      const d = JSON.parse(json || "{}"), r = d.result || {}, learning = r.learning || {}, locator = r.locator || {};
      const read = (p) => fs.existsSync(dir + "/" + p) ? fs.readFileSync(dir + "/" + p, "utf8") : null;
      const kept = Object.values(learning.kept || {}).reduce((a, b) => a + b, 0), dropped = learning.dropped + learning.dropped_at_render;
      const aiLine = "AI learning: ok (claude-haiku-5-5, $0.0155, 257,220 tokens), " + kept + " kept, " + dropped + " dropped";
      if (!text.split("\n").includes(aiLine)) errors.push("summary lacks: " + aiLine);
      if (kept !== 6 || dropped !== 3) errors.push("kept " + kept + ", dropped " + dropped + "; expected 6 and 3 (one concept names a missing file)");
      const locLine = "Locator: " + (locator.rendered ? "on" : "off") + " (top-3 " + locator.top3_hits + "/" + locator.replay_n + ", wrong " + locator.wrong + "/" + locator.replay_n + ")";
      if (!text.split("\n").includes(locLine)) errors.push("summary lacks: " + locLine);
      if (!locator.rendered) errors.push("the locator gate did not pass on the lean-ai fixture: " + locLine);
      // printed cards = hits + wrong: at least 70% of them name a changed file, wrong at most 15% of the replays
      if (locator.replay_n < 10 || locator.top3_hits * 100 < 70 * (locator.top3_hits + locator.wrong) || locator.wrong * 100 > 15 * locator.replay_n) errors.push("gate numbers do not meet the bar: " + locLine);
      if (!/learned_item_dropped_at_render/.test(text)) errors.push("the render-time drop is not shown");
      if (read(".olivium/learned.json") !== fs.readFileSync(bundle + "/learned.json", "utf8")) errors.push(".olivium/learned.json is not the bundle byte for byte");
      for (const p of [".olivium/index/symbols.tsv", ".olivium/index/terms.tsv", ".olivium/index/tests.tsv", ".claude/hooks/olivium-locate.sh", ".claude/hooks/olivium-rewrite.sh"])
        if (read(p) === null) errors.push(p + " missing");
      if (!(read(".olivium/index/symbols.tsv") || "").split("\n").some((l) => l.startsWith("routeRequest\tsrc/router.js\t"))) errors.push("symbols.tsv has no routeRequest row");
      const rewrites = "rw01\tmissing_tool\tnpx tsc\ttool_missing tsc\nrw02\twrong_runner\tmocha\tnpx mocha\n";
      if (read(".olivium/rewrites.tsv") !== rewrites) errors.push("rewrites.tsv: " + JSON.stringify(read(".olivium/rewrites.tsv")));
      const s = JSON.parse(read(".claude/settings.json") || "{}"), hooks = s.hooks || {};
      const pre = hooks.PreToolUse || [], ups = hooks.UserPromptSubmit || [];
      if (pre.length !== 2 || pre[1].matcher !== "Bash" || !/olivium-rewrite\.sh/.test(JSON.stringify(pre[1]))) errors.push("PreToolUse is not the guard then the Bash rewrite: " + JSON.stringify(pre.map((e) => e.matcher)));
      if (ups.length !== 1 || !/olivium-locate\.sh/.test(JSON.stringify(ups))) errors.push("no UserPromptSubmit locator entry");
      for (const e of [pre[1], ups[0]]) if (e && /permissionDecision/.test(JSON.stringify(e))) errors.push("a lean-ai hook command names permissionDecision");
      const spec = JSON.parse(read(".olivium/spec.json") || "{}").spec || {};
      if ((spec.context || {}).profile !== "lean-ai") errors.push("spec.context.profile " + (spec.context || {}).profile);
      if ((spec.learning || {}).bundle_sha256 !== JSON.parse(fs.readFileSync(bundle + "/learned.json", "utf8")).sha256) errors.push("spec.learning.bundle_sha256 is not the bundle sha256");
      const claude = (read("CLAUDE.md") || "").replace(/<!--[\s\S]*?-->/g, "").trim();
      if (!claude.includes("util.deprecate")) errors.push("CLAUDE.md lacks the learned global pitfall");
      if (claude.includes("keep the old behaviour working")) errors.push("CLAUDE.md keeps the static deprecation line beside the learned one");
      const lines = (spec.learning || {}).claude_md_lines || {};
      if (lines.replacing !== 1 || lines.left_out_no_static_line !== 0) errors.push("spec.learning.claude_md_lines " + JSON.stringify(lines));
      if (Buffer.byteLength(claude) > 600) errors.push("CLAUDE.md shows " + Buffer.byteLength(claude) + " bytes");
      process.stdout.write(JSON.stringify({ai_line: aiLine, locator_line: locLine, claude_md_visible_bytes: Buffer.byteLength(claude), files: (r.files || []).length, errors}));
    ' "$LEANAI_DIR" "$BUNDLES/ok" "$text_out" "$leanai_json")
    errors=$(verdict_errors "$verdict"); [ -z "$errors" ] || fail "$errors"
    export_verdict=$(verify_v2_export "$LEANAI_DIR")
    errors=$(verdict_errors "$export_verdict"); [ -z "$errors" ] || fail "export check: $errors"
    # The exported hooks, laid over a copy of the repository, on synthetic prompts and commands.
    hook_dir=$E2E_EXPORT_ROOT/c24-hooks
    rm -rf "$hook_dir"; cp -R "$LEANAI_REPO" "$hook_dir" && cp -R "$LEANAI_DIR"/. "$hook_dir"/
    LOCATE=$(leanai_hook UserPromptSubmit 0); REWRITE=$(leanai_hook PreToolUse 1)
    run_hook "$hook_dir" "" '{"hook_event_name":"UserPromptSubmit","prompt":"routeRequest drops the trailing slash on nested paths"}' "$LOCATE"; card_status=$?
    card=$(cat "$OUT"); card_bytes=$(wc -c < "$OUT" | tr -d ' ')
    [ "$card_status" = "0" ] || fail "locator exit status $card_status"
    case "$card" in "Olivium locator (learned from this repository's history; check before relying on it):"*) ;; *) fail "card does not start with the fixed header: $(printf '%s' "$card" | head -c 200)" ;; esac
    printf '%s' "$card" | grep -q '^- src/router.js: routeRequest' || fail "card does not name src/router.js and routeRequest first: $(printf '%s' "$card" | head -c 300)"
    [ "$card_bytes" -le 600 ] || fail "card is $card_bytes bytes"
    run_hook "$hook_dir" "" '{"hook_event_name":"UserPromptSubmit","prompt":"Say hello in one short sentence."}' "$LOCATE"
    [ ! -s "$OUT" ] || fail "the locator printed a card for an unrelated prompt: $(head -c 200 "$OUT")"
    rewrite_of() { run_hook "$hook_dir" "" "$(node -e 'process.stdout.write(JSON.stringify({tool_name: "Bash", tool_input: {command: process.argv[1], description: "run"}}))' "$1")" "$REWRITE"; node -e '
      const out = require("fs").readFileSync(process.argv[1], "utf8"); if (!out) process.exit(0);
      const h = JSON.parse(out).hookSpecificOutput; if ("permissionDecision" in h) process.stdout.write("PERMISSION ");
      process.stdout.write(h.updatedInput.command + " | " + h.updatedInput.description);' "$OUT"; }
    got=$(rewrite_of "mocha test/api.test.js")
    [ "$got" = "printf 'olivium: ran npx mocha (verified at export)\\n'; npx mocha test/api.test.js | run" ] || fail "mocha rewrite: $got"
    got=$(rewrite_of "npx tsc --noEmit && npm test")
    [ "$got" = "printf 'olivium: tsc is not installed here (checked at export); skip it.\\n'; true&& npm test | run" ] || fail "tsc rewrite: $got"
    for plain in "npm test" "npx mocha test" "echo mocha" "mocha \$(ls test)" "ls -la"; do
      got=$(rewrite_of "$plain"); [ -z "$got" ] || fail "rewrote '$plain': $got"
    done
  else fail "lean-ai generate failed: $(head -c 300 "$ERR") $JSON"; card_bytes=0; fi
  # Refusals: nothing is exported for any of them.
  hf generate "$LEANAI_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/c24-no-bundle" --context lean-ai --json; no_bundle=$?
  [ "$no_bundle" = "2" ] && [ "$(jx 'd.error')" = "invalid_arguments" ] || fail "lean-ai without --learned: exit $no_bundle $JSON"
  hf generate "$LEANAI_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/c24-lean-bundle" --context lean --learned "$BUNDLES/ok" --json; lean_bundle=$?
  [ "$lean_bundle" = "2" ] || fail "--learned with --context lean: exit $lean_bundle $JSON"
  hf generate "$LEANAI_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/c24-tamper" --context lean-ai --learned "$BUNDLES/tamper" --json; tamper=$?
  [ "$tamper" = "1" ] && [ "$(jx 'd.error')" = "learned_invalid" ] || fail "changed bundle: exit $tamper $JSON"
  hf generate "$LEANAI_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/c24-base" --context lean-ai --learned "$BUNDLES/base" --json; base=$?
  [ "$base" = "1" ] && [ "$(jx 'd.error')" = "learned_base_mismatch" ] || fail "foreign base: exit $base $JSON"
  for name in c24-no-bundle c24-lean-bundle c24-tamper c24-base; do [ ! -e "$E2E_EXPORT_ROOT/$name" ] || fail "an export was written for $name"; done
  # A learner that did not run: the export says so, with only the deterministic items.
  if hf generate "$LEANAI_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/c24-unavailable" --context lean-ai --learned "$BUNDLES/unavailable"; then
    grep -qx 'AI learning: unavailable (none, \$0.0000, 0 tokens), 2 kept, 2 dropped' "$OUT" || fail "unavailable line: $(grep '^AI learning' "$OUT")"
    grep -q 'ai_learning_unavailable' "$OUT" || fail "the ai_learning_unavailable warning is not shown"
  else fail "generate with an unavailable learner failed: $(head -c 300 "$ERR")"; fi
  scenario_detail=$(node -e 'const v = JSON.parse(process.argv[1] || "{}"); Object.assign(v, {card_bytes: Number(process.argv[2]), exits: {no_bundle: Number(process.argv[3]), lean_with_bundle: Number(process.argv[4]), changed_bundle: Number(process.argv[5]), foreign_base: Number(process.argv[6])}}); process.stdout.write(JSON.stringify(v))' \
    "${verdict:-}" "${card_bytes:-0}" "$no_bundle" "$lean_bundle" "$tamper" "$base")
fi
finish

# ---- C25-C31 generated Claude Code skills and subagents ------------------------------------------------------
# bench/native/fixture.sh writes a synthetic Python-shaped repository whose history the native templates can use
# (src/acme/http/h11.py and tools.py change together 8 times, a revert, follow-up fixes, 40 more sources, 6
# history-paired tests). Every commit subject carries ZZSUBJECTMARK, which must never reach an export. Nothing in the
# repository runs.
NATIVE_REPO=$E2E_EXPORT_ROOT/fixture-repo-native
NATIVE_MARK=ZZSUBJECTMARK
build_native_fixture() {
  rm -rf "$NATIVE_REPO"
  bash "$project/bench/native/fixture.sh" "$NATIVE_REPO" "$FIXTURE_SECRET"
}
# verify_native_export DIR SUMMARY_JSON: files, frontmatter, sizes, provenance hashes and evidence against the repository.
verify_native_export() {
  node -e '
    const fs = require("fs"), path = require("path"), crypto = require("crypto"), {execFileSync} = require("child_process");
    const [dir, summaryText, repo, mark, base] = process.argv.slice(1), errors = [];
    const native = JSON.parse(summaryText), cfg = JSON.parse(fs.readFileSync(base, "utf8")).native;
    const walk = (d, b = d) => fs.existsSync(d) ? fs.readdirSync(d, {withFileTypes: true}).flatMap(e => e.isDirectory() ? walk(path.join(d, e.name), b) : [path.relative(b, path.join(d, e.name)).split(path.sep).join("/")]).sort() : [];
    const files = walk(dir);
    const nativeFiles = files.filter(f => f.startsWith(".claude/skills/") || f.startsWith(".claude/agents/"));
    const items = native.items || [];
    const out = {items: items.map(i => i.name), native_files: nativeFiles, listing_bytes: native.listing_bytes,
      est_tokens_per_request: native.est_tokens_per_request, checked_commits: 0};
    const want = items.map(i => i.path).sort();
    if (JSON.stringify(want) !== JSON.stringify(nativeFiles)) errors.push("summary paths " + JSON.stringify(want) + " but disk has " + JSON.stringify(nativeFiles));
    const skills = items.filter(i => i.kind === "skill"), agents = items.filter(i => i.kind === "agent");
    if (skills.length < 1 || !skills.every(i => /^olivium-area-[a-z0-9-]+$/.test(i.name) && i.template === "area")) errors.push("expected at least one olivium-area-* skill: " + JSON.stringify(skills.map(i => i.name)));
    if (JSON.stringify(agents.map(i => i.name)) !== JSON.stringify(["olivium-locator", "olivium-test-runner"])) errors.push("agents " + JSON.stringify(agents.map(i => i.name)));
    const tools = {"olivium-locator": "Read, Grep, Glob", "olivium-test-runner": "Bash, Read"};
    const turns = {"olivium-locator": String(cfg.max_turns.locator), "olivium-test-runner": String(cfg.max_turns.test_runner)};
    let listing = 0;
    for (const item of items) {
      const text = fs.readFileSync(path.join(dir, item.path), "utf8");
      const m = text.match(/^---\n([\s\S]*?)\n---\n\n([\s\S]*)$/);
      if (!m) { errors.push(item.path + ": no frontmatter"); continue; }
      const front = {};
      for (const line of m[1].split("\n")) { const k = line.indexOf(": "); front[line.slice(0, k)] = line.slice(k + 2); }
      const keys = Object.keys(front);
      const expected = item.kind === "skill" ? ["name", "description"] : ["name", "description", "tools", "maxTurns"];
      if (JSON.stringify(keys) !== JSON.stringify(expected)) errors.push(item.path + " frontmatter keys " + JSON.stringify(keys));
      let name, description;
      try { name = JSON.parse(front.name); description = JSON.parse(front.description); } catch (e) { errors.push(item.path + ": name or description is not a quoted string"); continue; }
      if (name !== item.name) errors.push(item.path + " name " + name);
      if (description !== item.description) errors.push(item.path + " description differs from the summary");
      const dBytes = Buffer.byteLength(description), bBytes = Buffer.byteLength(m[2].replace(/\n$/, ""));
      if (dBytes > 200 || dBytes !== item.description_bytes) errors.push(item.path + " description " + dBytes + " B, summary " + item.description_bytes);
      if (bBytes !== item.body_bytes || bBytes > 2048) errors.push(item.path + " body " + bBytes + " B, summary " + item.body_bytes);
      if (item.kind === "agent") {
        if (front.tools !== tools[item.name]) errors.push(item.path + " tools " + front.tools);
        if (JSON.stringify(item.tools) !== JSON.stringify(tools[item.name].split(", "))) errors.push(item.name + " summary tools " + JSON.stringify(item.tools));
        if (front.maxTurns !== turns[item.name]) errors.push(item.path + " maxTurns " + front.maxTurns);
        listing += Buffer.byteLength(item.name) + dBytes + Buffer.byteLength(" (Tools: " + front.tools + ")") + 4;
      } else listing += Buffer.byteLength(item.name) + dBytes + 4;
      if (/[^\x20-\x7e\n]/.test(text)) errors.push(item.path + " has a byte outside printable ASCII");
      // "- <sha>: `file`, ..." lines say what a past fix changed: the commit must be in this history and touch each file.
      for (const fix of m[2].matchAll(/^- ([0-9a-f]{10}): (.*)$/gm)) {
        out.checked_fix_lines = (out.checked_fix_lines || 0) + 1;
        let touched = [];
        try { touched = execFileSync("git", ["-C", repo, "show", "--name-only", "--format=", fix[1]]).toString().split("\n").filter(Boolean); }
        catch (e) { errors.push(item.path + " fix " + fix[1] + " is not a commit of this repository"); continue; }
        for (const f of [...fix[2].matchAll(/`([^`]+)`/g)].map(x => x[1])) if (!touched.includes(f)) errors.push(item.path + " fix " + fix[1] + " did not change " + f);
      }
    }
    if (agents.length) listing += cfg.costs.agent_header_bytes;
    if (listing !== native.listing_bytes) errors.push("listing_bytes " + native.listing_bytes + ", files give " + listing);
    // The hostile commit of the fixture forges a fix with this SHA in its subject, and adds files whose names hold a
    // quote, a newline and an @: none of it may reach any exported file.
    const hostile = ["deadbeefdeadbeef", "forged", "odd\"quote", "at@sign", "new\nline"];
    for (const file of files) {
      const text = fs.readFileSync(path.join(dir, file), "utf8");
      if (text.includes(mark)) errors.push(file + " contains the commit-subject marker");
      for (const h of hostile) if (text.includes(h)) errors.push(file + " contains hostile fixture text " + JSON.stringify(h));
      if (/allowed-tools|permissionMode|mcpServers/.test(text) && file.startsWith(".claude/")) errors.push(file + " grants or changes permissions");
    }
    const settings = JSON.parse(fs.readFileSync(path.join(dir, ".claude/settings.json"), "utf8"));
    if (settings.disableSkillShellExecution !== true) errors.push("disableSkillShellExecution is not true");
    for (const rule of ["Bash(git push:*)", "Bash(gh:*)"]) if (!settings.permissions.deny.includes(rule)) errors.push(rule + " is not denied");
    let prov = null;
    try { prov = JSON.parse(fs.readFileSync(path.join(dir, ".olivium/native-provenance.json"), "utf8")); } catch (e) { errors.push("native-provenance.json: " + e.message); }
    if (prov) {
      if (prov.schema !== "olivium.native-provenance/v1") errors.push("provenance schema " + prov.schema);
      const head = execFileSync("git", ["-C", repo, "rev-parse", "HEAD"]).toString().trim();
      if (prov.history_head !== head) errors.push("history_head " + prov.history_head + " is not HEAD " + head);
      for (const row of prov.items) {
        const sha = crypto.createHash("sha256").update(fs.readFileSync(path.join(dir, row.path))).digest("hex");
        if (sha !== row.sha256) errors.push(row.path + " sha256 differs from the provenance");
        const summary = items.find(i => i.name === row.name);
        if (!summary || summary.body_bytes !== row.body_bytes || summary.description_bytes !== row.description_bytes) errors.push(row.name + " provenance differs from the summary");
        const owned = new Set(row.evidence.files);
        for (const commit of [...new Set([...row.evidence.commits, ...row.evidence.fix_commits])]) {
          out.checked_commits += 1;
          try { execFileSync("git", ["-C", repo, "merge-base", "--is-ancestor", commit, "HEAD"], {stdio: "ignore"}); }
          catch (e) { errors.push(row.name + " evidence " + commit + " is not an ancestor of HEAD"); continue; }
          const touched = execFileSync("git", ["-C", repo, "show", "--name-only", "--format=", commit]).toString().split("\n").filter(Boolean);
          if (!touched.some(f => owned.has(f))) errors.push(row.name + " evidence " + commit + " touches none of " + JSON.stringify([...owned]));
        }
      }
      if (prov.listing_bytes !== native.listing_bytes) errors.push("provenance listing_bytes " + prov.listing_bytes);
    }
    out.errors = errors;
    process.stdout.write(JSON.stringify(out));
  ' "$1" "$2" "$NATIVE_REPO" "$NATIVE_MARK" "$project/priv/blueprints/base.json"
}
NATIVE_DIR=$E2E_EXPORT_ROOT/cli-generate-native
NATIVE_SUMMARY=""
NATIVE_DIGEST=""

begin C25 "native: generate on a synthetic repository with history writes area skills, the locator and the test-runner subagents; frontmatter keys exact, descriptions at most 200 B, the summary matches the disk, every evidence commit is an ancestor of HEAD and touches the item's files, and no commit subject reaches the export"
if [ -e "$NATIVE_DIR" ]; then fail "export target is not fresh: $NATIVE_DIR"
elif ! build_native_fixture >> "$LOG" 2>&1; then fail "could not build the native fixture repository"
elif hf generate "$NATIVE_REPO" --runtime claude_code --export "$NATIVE_DIR" --json && ok; then
  no_leak "generate (native)"
  grep -q "$NATIVE_MARK" "$OUT" && fail "the CLI printed a commit subject"
  NATIVE_SUMMARY=$(jx 'd.result.native')
  NATIVE_DIGEST=$(jx 'd.result.digest')
  [ "$(jx 'd.result.native.select')" = "all" ] || fail "default native select: $(jx 'd.result.native.select')"
  verdict=$(verify_native_export "$NATIVE_DIR" "$NATIVE_SUMMARY")
  errors=$(verdict_errors "$verdict")
  [ -z "$errors" ] || fail "$errors"
  scenario_detail=$(node -e 'const v = JSON.parse(process.argv[1]); v.digest = process.argv[2]; v.commits = Number(process.argv[3]); process.stdout.write(JSON.stringify(v))' "$verdict" "$NATIVE_DIGEST" "$(git -C "$NATIVE_REPO" rev-list --count HEAD)")
else fail "generate failed: $(head -c 300 "$ERR") $JSON"; fi
finish

begin C26 "native: generating the same repository again gives the same digest and a byte-identical export tree, generated files included"
NATIVE_REPEAT=$E2E_EXPORT_ROOT/cli-generate-native-repeat
if [ -z "$NATIVE_DIGEST" ]; then fail "no digest from C25"
elif hf generate "$NATIVE_REPO" --runtime claude_code --export "$NATIVE_REPEAT" --json && ok; then
  repeat_digest=$(jx 'd.result.digest')
  [ "$repeat_digest" = "$NATIVE_DIGEST" ] || fail "digest changed: $NATIVE_DIGEST -> $repeat_digest"
  if tree_diff=$(diff -r "$NATIVE_DIR" "$NATIVE_REPEAT" 2>&1); then identical=true; else identical=false; fail "export trees differ: $(printf '%s' "$tree_diff" | head -c 300)"; fi
  native_files=$(cd "$NATIVE_REPEAT" && find .claude/skills .claude/agents .olivium/native-provenance.json -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "${native_files:-0}" -ge 4 ] || fail "the repeat export has $native_files native files"
  scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({first_digest: process.argv[1], repeat_digest: process.argv[2], identical_tree: process.argv[3] === "true", native_files: Number(process.argv[4])}))' "$NATIVE_DIGEST" "$repeat_digest" "$identical" "$native_files")
else fail "repeat generate failed: $(head -c 300 "$ERR") $JSON"; fi
finish

begin C27 "native: --native all, skills, agents and none each keep exactly the tools their files need (Skill, Task), set disableBundledSkills only with skills, deny Claude Code's built-in subagents by name (Agent(<name>)) exactly when Task is kept and never through the env switch, and report the cost and saving the measured table gives, built-in listing included"
NATIVE_MODES=""
if [ -z "$NATIVE_SUMMARY" ]; then fail "no native summary from C25"
else
  for mode in all skills agents none; do
    dir=$E2E_EXPORT_ROOT/cli-generate-native-$mode
    if hf generate "$NATIVE_REPO" --runtime claude_code --export "$dir" --native "$mode" --json && ok; then
      row=$(node -e '
        const fs = require("fs"), path = require("path");
        const [mode, resultText, dir, base] = process.argv.slice(1), errors = [];
        const r = JSON.parse(resultText).result, ctx = r.context, native = r.native, cfg = JSON.parse(fs.readFileSync(base, "utf8")).native;
        const settings = JSON.parse(fs.readFileSync(path.join(dir, ".claude/settings.json"), "utf8"));
        const deny = settings.permissions.deny, allow = settings.permissions.allow;
        const has = (p) => fs.existsSync(path.join(dir, p));
        const skills = native.items.filter(i => i.kind === "skill").length, agents = native.items.filter(i => i.kind === "agent").length;
        const want = {all: [true, true], skills: [true, false], agents: [false, true], none: [false, false]}[mode];
        if ((skills > 0) !== want[0] || (agents > 0) !== want[1]) errors.push(mode + ": " + skills + " skills, " + agents + " agents");
        if (native.select !== mode) errors.push("select " + native.select);
        const kept = [want[0] ? "Skill" : null, want[1] ? "Task" : null].filter(Boolean);
        if (JSON.stringify(ctx.kept_tools) !== JSON.stringify(kept)) errors.push("kept_tools " + JSON.stringify(ctx.kept_tools));
        if (ctx.disable_bundled_skills !== want[0]) errors.push("disable_bundled_skills " + ctx.disable_bundled_skills);
        // Kept Task lists the Claude Code built-in subagents again; the lean export denies them by name (probe E-N1).
        // The env switch has no effect from project settings on 2.1.311, so it is never written.
        if (ctx.disable_builtin_agents !== want[1]) errors.push("disable_builtin_agents " + ctx.disable_builtin_agents);
        const builtinRules = cfg.builtin_agents.map(n => "Agent(" + n + ")");
        const builtinDenied = builtinRules.filter(x => deny.includes(x));
        if (builtinDenied.length !== (want[1] ? builtinRules.length : 0)) errors.push("built-in agent deny rules " + JSON.stringify(builtinDenied));
        const builtin = want[1] ? Math.ceil(cfg.costs.builtin_agents_bytes * 1000 / cfg.costs.listing_bytes_per_1000_tokens) : 0;
        if (mode !== "none" && native.cost.builtin_agents_denied_tokens !== builtin) errors.push("builtin_agents_denied_tokens " + native.cost.builtin_agents_denied_tokens + ", expected " + builtin);
        if ((settings.disableBundledSkills === true) !== want[0]) errors.push("settings disableBundledSkills " + settings.disableBundledSkills);
        const env = (settings.env || {}).CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS;
        if (env !== undefined) errors.push("settings env built-in agents " + env);
        if (!deny.includes("Workflow")) errors.push("Workflow is not denied");
        if (deny.includes("Skill") === want[0]) errors.push("Skill deny " + deny.includes("Skill"));
        if (deny.includes("Task") === want[1]) errors.push("Task deny " + deny.includes("Task"));
        const skillRules = native.items.filter(i => i.kind === "skill").map(i => "Skill(" + i.name + ")").sort();
        if (allow.includes("Skill")) errors.push("the bare Skill tool is allowed");
        if (JSON.stringify(allow.filter(r => r.startsWith("Skill(")).sort()) !== JSON.stringify(want[0] ? skillRules : [])) errors.push("Skill allow rules " + JSON.stringify(allow.filter(r => r.startsWith("Skill("))));
        if (settings.disableSkillShellExecution !== true) errors.push("disableSkillShellExecution");
        if (has(".olivium/native-provenance.json") !== (mode !== "none")) errors.push("native-provenance.json present: " + has(".olivium/native-provenance.json"));
        if (has(".claude/agents/olivium-test-runner.md") !== want[1]) errors.push("test runner file present: " + has(".claude/agents/olivium-test-runner.md"));
        const config = {all: "skills_agents", skills: "skills", agents: "agents"}[mode];
        const listingTokens = Math.ceil(native.listing_bytes * 1000 / cfg.costs.listing_bytes_per_1000_tokens);
        if (mode === "none") {
          if (ctx.est_tokens_saved_per_request !== 11700) errors.push("none saving " + ctx.est_tokens_saved_per_request);
          if (native.items.length) errors.push("none still lists items");
        } else {
          const saved = cfg.costs.saved_vs_none[config] + builtin - listingTokens;
          if (ctx.est_tokens_saved_per_request !== saved) errors.push("saving " + ctx.est_tokens_saved_per_request + ", table gives " + saved);
          const cost = cfg.costs.fixed_tokens[config] - builtin + listingTokens;
          if (native.est_tokens_per_request !== cost) errors.push("cost " + native.est_tokens_per_request + ", table gives " + cost);
          if (native.measured_on !== "claude-code 2.1.311") errors.push("measured_on " + native.measured_on);
        }
        process.stdout.write(JSON.stringify({mode, skills, agents, kept_tools: ctx.kept_tools, disable_bundled_skills: ctx.disable_bundled_skills,
          disable_builtin_agents: ctx.disable_builtin_agents, builtin_denied: builtinDenied, builtin_agents_denied_tokens: builtin, deny_bare: deny.filter(d => !d.includes("(")).length,
          listing_bytes: native.listing_bytes, est_tokens_per_request: native.est_tokens_per_request,
          est_tokens_saved_per_request: ctx.est_tokens_saved_per_request, errors}));
      ' "$mode" "$JSON" "$dir" "$project/priv/blueprints/base.json")
      errors=$(verdict_errors "$row")
      [ -z "$errors" ] || fail "$mode: $errors"
      NATIVE_MODES="$NATIVE_MODES$row
"
    else fail "generate --native $mode failed: $(head -c 300 "$ERR") $JSON"; fi
  done
  scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({modes: process.argv[1].split("\n").filter(Boolean).map(l => JSON.parse(l))}))' "$NATIVE_MODES")
fi
finish

begin C28 "native: the all export allows exactly what the none export allows plus one Skill(<name>) rule per generated skill (never the bare Skill tool) and denies exactly what it denies minus Skill and Task plus Agent(<name>) for each Claude Code built-in subagent; the replay gate, with the test-runner calls carrying agent_type, refuses no normal call and every unsafe one (test-runner flags that load code, writes into the generated skill and subagent files)"
GATE_OUT=$E2E_EXPORT_ROOT/c28-replay-gate.json
GATE_SCRATCH=$E2E_EXPORT_ROOT/c28-replay-scratch
ALL_DIR=$E2E_EXPORT_ROOT/cli-generate-native-all
NONE_DIR=$E2E_EXPORT_ROOT/cli-generate-native-none
if [ ! -f "$ALL_DIR/.claude/settings.json" ] || [ ! -f "$NONE_DIR/.claude/settings.json" ]; then fail "no all or none export from C27"
else
  sets=$(node -e '
    const fs = require("fs"), [a, n] = process.argv.slice(1).map(d => JSON.parse(fs.readFileSync(d + "/.claude/settings.json", "utf8")).permissions), errors = [];
    const same = (x, y) => JSON.stringify([...new Set(x)].sort()) === JSON.stringify([...new Set(y)].sort());
    const skillNames = fs.readdirSync(process.argv[1] + "/.claude/skills").sort();
    const skillRules = skillNames.map(name => "Skill(" + name + ")");
    if (!skillNames.length) errors.push("the all export has no skill");
    if (a.allow.includes("Skill")) errors.push("the all export allows the bare Skill tool");
    if (!same(a.allow, [...n.allow, ...skillRules])) errors.push("allow(all) is not allow(none) plus " + JSON.stringify(skillRules) + ": " + JSON.stringify(a.allow.filter(x => !n.allow.includes(x))) + " / " + JSON.stringify(n.allow.filter(x => !a.allow.includes(x))));
    const builtinRules = ["Explore", "general-purpose", "statusline-setup"].map(x => "Agent(" + x + ")");
    if (!same(a.deny, [...n.deny.filter(x => !["Skill", "Task"].includes(x)), ...builtinRules])) errors.push("deny(all) is not deny(none) minus Skill and Task plus the built-in agent rules: " + JSON.stringify(n.deny.filter(x => !a.deny.includes(x))) + " / " + JSON.stringify(a.deny.filter(x => !n.deny.includes(x))));
    if (!n.deny.includes("Skill") || !n.deny.includes("Task")) errors.push("the none export does not deny Skill and Task");
    if ((a.ask || []).length || (n.ask || []).length) errors.push("ask rules present");
    process.stdout.write(JSON.stringify({allow_all: a.allow.length, allow_none: n.allow.length, deny_all: a.deny.length, deny_none: n.deny.length, skill_rules: skillRules, errors}));
  ' "$ALL_DIR" "$NONE_DIR")
  errors=$(verdict_errors "$sets")
  [ -z "$errors" ] || fail "$errors"
  rm -rf "$GATE_OUT" "$GATE_SCRATCH"
  scenario_cmds+=("python3 bench/value/replay/gate.py --export $ALL_DIR --synthetic --runner host --scratch $GATE_SCRATCH --out $GATE_OUT --quiet")
  python3 bench/value/replay/gate.py --export "$ALL_DIR" --synthetic --runner host --scratch "$GATE_SCRATCH" --out "$GATE_OUT" --quiet >> "$LOG" 2>&1; gate_status=$?
  if [ -f "$GATE_OUT" ]; then
    verdict=$(node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).synthetic || {}; const errors = [];
      if (r.normal_refused !== 0) errors.push(r.normal_refused + " of " + r.normal_total + " normal calls refused: " + JSON.stringify(r.normal_refused_list || []).slice(0, 200));
      if (r.unsafe_refused !== r.unsafe_total || !r.unsafe_total) errors.push(r.unsafe_refused + " of " + r.unsafe_total + " unsafe calls refused: " + JSON.stringify(r.unsafe_not_refused || []).slice(0, 200));
      if (!(r.test_runner_entries >= 12)) errors.push("test-runner entries replayed: " + r.test_runner_entries);
      if (r.test_runner_command !== "pytest") errors.push("test runner command " + r.test_runner_command);
      if ((r.unsafe_oracle_mismatch || []).length) errors.push("the oracle disagrees with the refusing layer: " + JSON.stringify(r.unsafe_oracle_mismatch).slice(0, 200));
      if ((r.unsafe_expected_not_labelled || []).length) errors.push("unsafe entries the oracle does not label: " + JSON.stringify(r.unsafe_expected_not_labelled).slice(0, 200));
      process.stdout.write(JSON.stringify({normal_total: r.normal_total, normal_refused: r.normal_refused, unsafe_total: r.unsafe_total, unsafe_refused: r.unsafe_refused,
        unsafe_by_layer: r.unsafe_by_layer, test_runner_entries: r.test_runner_entries, unsafe_oracle_mismatch: r.unsafe_oracle_mismatch, unsafe_expected_not_labelled: r.unsafe_expected_not_labelled, runner_scope_by_layer: r.runner_scope_by_layer, errors}));' "$GATE_OUT")
    errors=$(verdict_errors "$verdict")
    [ -z "$errors" ] || fail "$errors"
    [ "$gate_status" = "0" ] || fail "gate exit status $gate_status"
    scenario_detail=$(node -e 'process.stdout.write(JSON.stringify({settings: JSON.parse(process.argv[1]), gate: JSON.parse(process.argv[2])}))' "$sets" "$verdict")
  else fail "the gate wrote no report (exit $gate_status)"; fi
fi
finish

begin C29 "native: lean-x writes no skill or subagent by default; standard writes them with no deny list, no Agent(<name>) rule, no bundled-skills or built-in-agents switch"
if [ -z "$NATIVE_SUMMARY" ]; then fail "no native summary from C25"
else
  details="{}"
  for profile in lean-x standard; do
    dir=$E2E_EXPORT_ROOT/cli-generate-native-$profile
    if hf generate "$NATIVE_REPO" --runtime claude_code --export "$dir" --context "$profile" --json && ok; then
      row=$(node -e '
        const fs = require("fs"), path = require("path");
        const [profile, resultText, dir] = process.argv.slice(1), errors = [];
        const r = JSON.parse(resultText).result, settings = JSON.parse(fs.readFileSync(path.join(dir, ".claude/settings.json"), "utf8"));
        const nativeFiles = [".claude/skills", ".claude/agents"].filter(p => fs.existsSync(path.join(dir, p)));
        const trim = ["Skill", "Task", "Workflow", "ScheduleWakeup", "CronCreate", "Monitor"].filter(n => settings.permissions.deny.includes(n));
        if (profile === "lean-x") {
          if (r.native.select !== "none" || r.native.items.length) errors.push("lean-x native " + r.native.select + " with " + r.native.items.length + " items");
          if (nativeFiles.length || fs.existsSync(path.join(dir, ".olivium/native-provenance.json"))) errors.push("lean-x wrote native files: " + nativeFiles);
          if (!settings.permissions.deny.includes("Skill") || !settings.permissions.deny.includes("Task")) errors.push("lean-x keeps Skill or Task");
        } else {
          if (r.native.select !== "all" || r.native.items.length < 3) errors.push("standard native " + r.native.select + " with " + r.native.items.length + " items");
          if (nativeFiles.length !== 2) errors.push("standard native files: " + nativeFiles);
          if (trim.length) errors.push("standard denies " + trim.join(","));
          if ("disableBundledSkills" in settings || "env" in settings) errors.push("standard sets disableBundledSkills or env");
          if (r.context.disable_bundled_skills || r.context.disable_builtin_agents) errors.push("standard context switches on");
          if (settings.permissions.deny.some(x => x.startsWith("Agent("))) errors.push("standard denies a built-in agent");
          const skillRules = r.native.items.filter(i => i.kind === "skill").map(i => "Skill(" + i.name + ")");
          if (settings.permissions.allow.includes("Skill") || !skillRules.length || !skillRules.every(x => settings.permissions.allow.includes(x))) errors.push("standard does not allow exactly its skills: " + JSON.stringify(settings.permissions.allow.filter(x => x.startsWith("Skill"))));
          if (r.native.cost.fixed_tokens !== 0) errors.push("standard fixed cost " + r.native.cost.fixed_tokens);
        }
        if (settings.disableSkillShellExecution !== true) errors.push("disableSkillShellExecution");
        process.stdout.write(JSON.stringify({profile, select: r.native.select, items: r.native.items.map(i => i.name), native_dirs: nativeFiles,
          trim_denied: trim, est_tokens_per_request: r.native.est_tokens_per_request, errors}));
      ' "$profile" "$JSON" "$dir")
      errors=$(verdict_errors "$row")
      [ -z "$errors" ] || fail "$profile: $errors"
      details=$(node -e 'const d = JSON.parse(process.argv[1]); const r = JSON.parse(process.argv[2]); d[r.profile] = r; process.stdout.write(JSON.stringify(d))' "$details" "$row")
    else fail "generate --context $profile failed: $(head -c 300 "$ERR") $JSON"; fi
  done
  scenario_detail=$details
fi
finish

begin C30 "native: the text summary names each skill (listed and on-use bytes), each subagent with its tools and the measured cost; the lean line gives the saving for the kept tools, never 11,700; --native none says none generated and restores 11,700; a bad --native exits 2 and writes nothing; the C13 fixture says why none was generated"
if [ -z "$NATIVE_SUMMARY" ]; then fail "no native summary from C25"
elif hf generate "$NATIVE_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/cli-generate-native-text"; then
  text_all=$(cat "$OUT")
  grep -q "$NATIVE_MARK" "$OUT" && fail "the text summary printed a commit subject"
  hf generate "$NATIVE_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/cli-generate-native-text-none" --native none || fail "--native none failed: $(head -c 300 "$ERR")"
  text_none=$(cat "$OUT")
  hf generate "$FIXTURE_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/cli-generate-c13-text-native" || fail "C13 fixture text generate failed: $(head -c 300 "$ERR")"
  text_c13=$(cat "$OUT")
  hf generate "$NATIVE_REPO" --runtime claude_code --export "$E2E_EXPORT_ROOT/cli-generate-native-bad" --native some --json; bad_status=$?
  [ "$bad_status" = "2" ] || fail "--native some exit status $bad_status, expected 2"
  [ "$(jx 'd.error')" = "invalid_arguments" ] || fail "--native some error: $JSON"
  [ ! -e "$E2E_EXPORT_ROOT/cli-generate-native-bad" ] || fail "an export was written for --native some"
  verdict=$(node -e '
    const [summaryText, all, none, c13] = process.argv.slice(1), errors = [];
    const native = JSON.parse(summaryText), fmt = (n) => n.toLocaleString("en-US");
    const skills = native.items.filter(i => i.kind === "skill"), agents = native.items.filter(i => i.kind === "agent");
    const lines = [
      "skills      " + skills.length + ": " + skills.map(i => i.name + " (" + (Buffer.byteLength(i.name) + i.description_bytes + 4) + " B listed, " + fmt(i.body_bytes) + " B on use)").join(", "),
      "agents      " + agents.length + ": " + agents.map(i => i.name + " (" + i.tools.join(", ") + ")").join(", "),
      "native      about " + fmt(native.est_tokens_per_request) + " tokens on every model request for these (measured on Claude Code 2.1.311); --native none removes them",
      "subagents   each call costs about " + fmt(native.subagent_turn_tokens.min) + "-" + fmt(native.subagent_turn_tokens.max) + " tokens per turn of its own, not in the figure above; " + ((native.builtin_agents_denied || []).length
        ? "Claude Code\u0027s built-in subagents (" + native.builtin_agents_denied.join(", ") + ") are denied by name, which takes about " + fmt(native.builtin_agents_denied_tokens) + " tokens off every request (included above); your own and the repository\u0027s skills and subagents stay listed"
        : "Claude Code\u0027s built-in subagents stay listed, and the figure above includes them")];
    if (JSON.stringify(native.builtin_agents_denied) !== JSON.stringify(["Explore", "general-purpose", "statusline-setup"])) errors.push("builtin_agents_denied " + JSON.stringify(native.builtin_agents_denied));
    const allLines = all.split("\n");
    for (const line of lines) if (!allLines.includes(line)) errors.push("summary lacks the line: " + line);
    const lean = allLines.find(l => l.startsWith("Context profile: lean"));
    if (!lean || !lean.includes("keeps Skill, Task for the generated skills and subagents")) errors.push("lean line does not name the kept tools: " + lean);
    if (!lean || lean.includes("11,700") || !/about [0-9,]+ fewer tokens on every model request than no settings, estimated from measurements on Claude Code 2\.1\.311/.test(lean)) errors.push("lean line saving: " + lean);
    const noneLines = none.split("\n");
    if (!noneLines.includes("native      none generated (not_selected)")) errors.push("--native none summary: " + noneLines.filter(l => l.startsWith("native")));
    if (noneLines.some(l => /^(skills|agents)      /.test(l))) errors.push("--native none still lists skills or agents");
    if (!none.includes("about 11,700 fewer tokens on every model request, measured on Claude Code 2.1.311")) errors.push("--native none does not restore the 11,700 saving");
    const c13native = c13.split("\n").filter(l => l.startsWith("native      "));
    if (c13native.length !== 1 || !/^native      none generated \((gate_failed|history_unavailable)(, [a-z_]+)*\)$/.test(c13native[0])) errors.push("C13 fixture native line: " + JSON.stringify(c13native));
    if (!c13.includes("about 11,700 fewer tokens")) errors.push("C13 fixture lean saving changed");
    if (/native_none_generated/.test(c13)) errors.push("the none-generated fact is printed twice");
    process.stdout.write(JSON.stringify({lines, lean_line: lean, none_line: noneLines.find(l => l.startsWith("native")), c13_line: c13native[0], errors}));
  ' "$NATIVE_SUMMARY" "$text_all" "$text_none" "$text_c13")
  errors=$(verdict_errors "$verdict")
  [ -z "$errors" ] || fail "$errors"
  scenario_detail=$(node -e 'const v = JSON.parse(process.argv[1]); v.bad_native_status = Number(process.argv[2]); process.stdout.write(JSON.stringify(v))' "$verdict" "$bad_status")
else fail "generate (text, native) failed: $(head -c 300 "$ERR")"; fi
finish

begin C31 "native: a shallow clone is graded by what it holds: with at least 200 commits it gets the history skills and subagents (every evidence commit in the clone), with fewer it gets none and the JSON says to run git fetch --unshallow"
SHALLOW_SMALL=$E2E_EXPORT_ROOT/fixture-repo-native-shallow-10
NATIVE_LONG=$E2E_EXPORT_ROOT/fixture-repo-native-long
SHALLOW_LONG=$E2E_EXPORT_ROOT/fixture-repo-native-shallow-long
if [ ! -d "$NATIVE_REPO/.git" ]; then fail "no native fixture repository from C25"
else
  rm -rf "$SHALLOW_SMALL" "$NATIVE_LONG" "$SHALLOW_LONG"
  scenario_cmds+=("git clone --no-local --depth=10 file://$NATIVE_REPO $SHALLOW_SMALL")
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git clone --quiet --no-local --depth=10 "file://$NATIVE_REPO" "$SHALLOW_SMALL" >> "$LOG" 2>&1 || fail "shallow clone (10) failed"
  # 200 one-file commits on top of the fixture (not focused changes, so the clusters stay the fixture's), then a
  # clone one commit short of the whole history: it holds them and every fixture commit after the initial one.
  scenario_cmds+=("git clone --no-local file://$NATIVE_REPO $NATIVE_LONG; 200 one-file commits; git clone --no-local --depth=<commits - 1> file://$NATIVE_LONG $SHALLOW_LONG")
  (
    set -e
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME="Synthetic Author" GIT_AUTHOR_EMAIL=synthetic-author@example.invalid \
      GIT_COMMITTER_NAME="Synthetic Author" GIT_COMMITTER_EMAIL=synthetic-author@example.invalid
    git clone --quiet --no-local "file://$NATIVE_REPO" "$NATIVE_LONG"
    for n in $(seq 1 200); do
      stamp="$((1772366400 + (100 + n) * 86400)) +0000"
      printf '# filler %s\n' "$n" >> "$NATIVE_LONG/src/acme/m$(( n % 7 + 10 )).py"
      GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git -C "$NATIVE_LONG" commit --quiet -am "feat: $NATIVE_MARK filler $n"
    done
    git clone --quiet --no-local --depth="$(( $(git -C "$NATIVE_LONG" rev-list --count HEAD) - 1 ))" "file://$NATIVE_LONG" "$SHALLOW_LONG"
  ) >> "$LOG" 2>&1 || fail "could not build the long shallow clone"
  small_json=""; long_json=""
  if hf generate "$SHALLOW_SMALL" --runtime claude_code --export "$E2E_EXPORT_ROOT/cli-generate-native-shallow-10" --json && ok; then small_json=$JSON
  else fail "generate on the 10-commit shallow clone failed: $(head -c 300 "$ERR")"; fi
  if hf generate "$SHALLOW_LONG" --runtime claude_code --export "$E2E_EXPORT_ROOT/cli-generate-native-shallow-long" --json && ok; then long_json=$JSON
  else fail "generate on the long shallow clone failed: $(head -c 300 "$ERR")"; fi
  if [ -n "$small_json" ] && [ -n "$long_json" ]; then
    verdict=$(node -e '
      const {execFileSync} = require("child_process");
      const [smallText, longText, small, long, mark] = process.argv.slice(1), errors = [];
      const s = JSON.parse(smallText).result, l = JSON.parse(longText).result;
      const shallow = (repo) => execFileSync("git", ["-C", repo, "rev-parse", "--is-shallow-repository"]).toString().trim();
      if (shallow(small) !== "true" || shallow(long) !== "true") errors.push("the clones are not shallow");
      if (s.native.items.length) errors.push("the 10-commit clone generated " + s.native.items.map(i => i.name));
      if (!s.native.dropped.some(d => d.reason === "history_unavailable")) errors.push("10-commit clone drop reasons " + JSON.stringify(s.native.dropped.map(d => d.reason)));
      const why = (s.diagnostics || []).find(d => d.code === "native_none_generated");
      if (!why || !why.message.includes("git fetch --unshallow")) errors.push("no unshallow advice: " + JSON.stringify(why));
      const skills = l.native.items.filter(i => i.kind === "skill"), agents = l.native.items.filter(i => i.kind === "agent").map(i => i.name);
      if (!skills.length) errors.push("the long shallow clone generated no skill: " + JSON.stringify(l.native.dropped));
      if (JSON.stringify(agents) !== JSON.stringify(["olivium-locator", "olivium-test-runner"])) errors.push("long shallow clone agents " + JSON.stringify(agents));
      let checked = 0;
      for (const item of l.native.items) for (const sha of item.evidence) {
        checked += 1;
        try { execFileSync("git", ["-C", long, "merge-base", "--is-ancestor", sha, "HEAD"], {stdio: "ignore"}); } catch (e) { errors.push(item.name + " evidence " + sha + " is not in the clone"); }
      }
      if (JSON.stringify(l).includes(mark)) errors.push("a commit subject reached the summary");
      process.stdout.write(JSON.stringify({small_reasons: [...new Set(s.native.dropped.map(d => d.reason))], long_items: l.native.items.map(i => i.name),
        long_est_tokens_per_request: l.native.est_tokens_per_request, checked_commits: checked,
        long_commits: Number(execFileSync("git", ["-C", long, "rev-list", "--count", "HEAD"]).toString().trim()), errors}));
    ' "$small_json" "$long_json" "$SHALLOW_SMALL" "$SHALLOW_LONG" "$NATIVE_MARK")
    errors=$(verdict_errors "$verdict")
    [ -z "$errors" ] || fail "$errors"
    scenario_detail=$verdict
  fi
fi
finish

begin C32 "native: a Node repository whose npm test script is one direct call of a test tool that takes files (node --test) gets the test runner with npm test and npm test -- <file>, never a decoy script (test:browser, test:module) or a subdirectory CI job; CLAUDE.md and the runner agree; the guard lets npm test -- <file> through and refuses a code-loading flag and a test file outside the project (/tmp, ..)"
NODE_REPO=$E2E_EXPORT_ROOT/fixture-repo-node
NODE_DIR=$E2E_EXPORT_ROOT/cli-generate-node
rm -rf "$NODE_REPO"
scenario_cmds+=("synthetic Node repository at $NODE_REPO (package.json scripts test, test:browser, test:module; CI job in website/; 3 sources each changed 3 times with its test)")
if ! (
  set -e
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME="Synthetic Author" GIT_AUTHOR_EMAIL=synthetic-author@example.invalid \
    GIT_COMMITTER_NAME="Synthetic Author" GIT_COMMITTER_EMAIL=synthetic-author@example.invalid
  mkdir -p "$NODE_REPO/.github/workflows" "$NODE_REPO/src" "$NODE_REPO/test" "$NODE_REPO/website"
  printf '{\n  "name": "synthetic-node",\n  "version": "0.1.0",\n  "scripts": {\n    "test": "node --test",\n    "test:browser": "karma start",\n    "test:module": "node --test test/module",\n    "lint": "eslint ."\n  }\n}\n' > "$NODE_REPO/package.json"
  printf 'name: ci\non: [push]\njobs:\n  site:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: website\n    steps:\n      - uses: actions/checkout@v4\n      - run: npm run test:browser\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: npm ci\n      - run: npm test\n' > "$NODE_REPO/.github/workflows/ci.yml"
  node_commit() { # day subject files...
    local day=$1 subject=$2 file stamp
    shift 2
    stamp="$((1772366400 + day * 86400)) +0000"
    for file in "$@"; do printf '// change on day %s\n' "$day" >> "$NODE_REPO/$file"; done
    git -C "$NODE_REPO" add --all
    GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git -C "$NODE_REPO" commit --quiet -m "$subject"
  }
  git -C "$NODE_REPO" init --quiet --initial-branch=main
  node_commit 0 "feat: $NATIVE_MARK initial" src/a.js src/b.js src/c.js test/a.test.js test/b.test.js test/c.test.js website/index.js
  day=1
  for k in a b c; do for n in 1 2 3; do node_commit "$day" "feat: $NATIVE_MARK $k $n" "src/$k.js" "test/$k.test.js"; day=$((day + 1)); done; done
) >> "$LOG" 2>&1; then fail "could not build the Node fixture repository"
elif hf generate "$NODE_REPO" --runtime claude_code --export "$NODE_DIR" --json && ok; then
  verdict=$(node -e '
    const fs = require("fs"), path = require("path"), {execFileSync} = require("child_process");
    const [resultText, dir, mark] = process.argv.slice(1), errors = [];
    const r = JSON.parse(resultText).result;
    const read = (p) => fs.existsSync(path.join(dir, p)) ? fs.readFileSync(path.join(dir, p), "utf8") : "";
    const runner = read(".claude/agents/olivium-test-runner.md"), claude = read("CLAUDE.md");
    const prov = JSON.parse(read(".olivium/native-provenance.json") || "{}");
    if (!runner) errors.push("no test runner: " + JSON.stringify(r.native.dropped));
    if (JSON.stringify(prov.test_runner_commands) !== JSON.stringify(["npm test", "npm test --"])) errors.push("test_runner_commands " + JSON.stringify(prov.test_runner_commands));
    if (!runner.includes("- `npm test` (whole suite)\n- `npm test -- <file>` (one file)\n")) errors.push("runner commands: " + runner.split("\n").filter(l => l.startsWith("- `")).join(" | "));
    for (const decoy of ["test:browser", "test:module", "karma", "website"]) if (runner.includes(decoy) || claude.includes(decoy)) errors.push("decoy " + decoy + " reached the export");
    const line = (label) => (claude.split("\n").find(l => l.startsWith("- " + label + ": ")) || "").slice(label.length + 4);
    const testLine = line("Test"), oneLine = line("Test one");
    if (testLine && testLine !== "`npm test`") errors.push("CLAUDE.md Test line " + testLine + " is not the runner suite npm test");
    if (oneLine !== "`npm test -- <file>`") errors.push("CLAUDE.md Test one line " + JSON.stringify(oneLine));
    if (JSON.stringify(r).includes(mark) || runner.includes(mark)) errors.push("a commit subject reached the export");
    const guard = (command) => execFileSync("/bin/sh", [path.join(dir, ".claude/hooks/olivium-guard.sh")], {cwd: dir,
      env: {PATH: "/usr/bin:/bin", CLAUDE_PROJECT_DIR: dir},
      input: JSON.stringify({hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command}, agent_type: "olivium-test-runner", agent_id: "e2e", cwd: dir})}).toString();
    const calls = {};
    for (const command of ["npm test -- test/a.test.js", "npm test -- test/a.test.js 2>&1 | tail -n 40", "npm test"]) {
      calls[command] = guard(command); if (calls[command].includes("\"deny\"")) errors.push("guard refused " + command);
    }
    for (const command of ["npm test -- --require=./x.js test/a.test.js", "npm test -- --import ./x.js test/a.test.js", "npm run test:browser", "npm test -- /tmp/x.test.js", "npm test -- ../x.test.js"]) {
      calls[command] = guard(command); if (!calls[command].includes("Olivium guard: the test runner runs only: npm test; npm test --")) errors.push("guard let through " + command);
    }
    process.stdout.write(JSON.stringify({items: r.native.items.map(i => i.name), test_runner_commands: prov.test_runner_commands,
      claude_test_line: testLine || null, claude_test_one_line: oneLine, guard: Object.fromEntries(Object.entries(calls).map(([k, v]) => [k, v.includes("\"deny\"") ? "refused" : "allowed"])), errors}));
  ' "$JSON" "$NODE_DIR" "$NATIVE_MARK")
  errors=$(verdict_errors "$verdict")
  [ -z "$errors" ] || fail "$errors"
  scenario_detail=$verdict
else fail "generate on the Node fixture failed: $(head -c 300 "$ERR") $JSON"; fi
finish

begin C33 "native: an npm test script that is a direct jest or vitest call but chains a shell operator or has a pretest script gets no npx form and no test runner (runner_command_unsuitable), while a plain jest script gets npx jest"
c33_verdicts=""
for variant in chain pretest plain; do
  V_REPO=$E2E_EXPORT_ROOT/fixture-repo-node-$variant
  V_DIR=$E2E_EXPORT_ROOT/cli-generate-node-$variant
  rm -rf "$V_REPO"
  case $variant in
    chain) scripts='"test": "jest && node scripts/cleanup.js"' ;;
    pretest) scripts='"pretest": "npm run build", "test": "vitest run", "build": "tsc"' ;;
    plain) scripts='"test": "jest"' ;;
  esac
  scenario_cmds+=("copy of the C32 repository at $V_REPO with package.json scripts {$scripts} in a new commit")
  if [ ! -d "$NODE_REPO/.git" ] || ! (
    set -e
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME="Synthetic Author" GIT_AUTHOR_EMAIL=synthetic-author@example.invalid \
      GIT_COMMITTER_NAME="Synthetic Author" GIT_COMMITTER_EMAIL=synthetic-author@example.invalid
    cp -R "$NODE_REPO" "$V_REPO"
    printf '{\n  "name": "synthetic-node",\n  "version": "0.1.0",\n  "scripts": {%s}\n}\n' "$scripts" > "$V_REPO/package.json"
    git -C "$V_REPO" add --all
    GIT_AUTHOR_DATE="1775000000 +0000" GIT_COMMITTER_DATE="1775000000 +0000" git -C "$V_REPO" commit --quiet -m "chore: scripts"
  ) >> "$LOG" 2>&1; then fail "could not build the $variant variant of the Node fixture"; continue; fi
  if hf generate "$V_REPO" --runtime claude_code --export "$V_DIR" --json && ok; then
    v=$(node -e '
      const fs = require("fs"), path = require("path");
      const [resultText, dir, variant] = process.argv.slice(1), errors = [];
      const r = JSON.parse(resultText).result;
      const prov = JSON.parse(fs.existsSync(path.join(dir, ".olivium/native-provenance.json")) ? fs.readFileSync(path.join(dir, ".olivium/native-provenance.json"), "utf8") : "{}");
      const commands = prov.test_runner_commands || [];
      const runner = fs.existsSync(path.join(dir, ".claude/agents/olivium-test-runner.md"));
      const dropped = JSON.stringify((r.native || {}).dropped || []);
      if (variant === "plain") {
        if (!runner || !commands.includes("npx jest")) errors.push(variant + ": expected a runner with npx jest, got " + JSON.stringify(commands));
      } else {
        if (runner || commands.some(c => c.startsWith("npx "))) errors.push(variant + ": runner commands " + JSON.stringify(commands));
        if (!dropped.includes("runner_command_unsuitable")) errors.push(variant + ": test runner not dropped as runner_command_unsuitable: " + dropped.slice(0, 200));
      }
      process.stdout.write(JSON.stringify({variant, test_runner_commands: commands, runner, errors}));
    ' "$JSON" "$V_DIR" "$variant")
    errors=$(verdict_errors "$v")
    [ -z "$errors" ] || fail "$errors"
    c33_verdicts="$c33_verdicts${c33_verdicts:+,}$v"
  else fail "generate on the $variant variant failed: $(head -c 300 "$ERR") $JSON"; fi
done
scenario_detail="[$c33_verdicts]"
finish

# ---- results --------------------------------------------------------------------------------------------------
ended_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
total_ms=$(( $(now_ms) - suite_t0 ))
node -e '
  const fs = require("fs");
  const [records, out, startedAt, endedAt, totalMs, workspace, exportRoot, restoreTarget, log] = process.argv.slice(1);
  const scenarios = fs.readFileSync(records, "utf8").split("\n").filter(Boolean).map(l => JSON.parse(l));
  const passed = scenarios.filter(s => s.result === "pass").length;
  const results = {
    schema: "harnessforge-e2e-cli/1",
    started_at: startedAt, ended_at: endedAt,
    launcher: "bin/harnessforge (mix run -e HarnessForge.CLI.main; every call boots the BEAM, about 5 s, included in duration_ms)",
    workspace, export_root: exportRoot, restore_target: restoreTarget, log,
    scenarios, passed, failed: scenarios.length - passed, total: scenarios.length, total_duration_ms: Number(totalMs),
    cli_calls: scenarios.reduce((n, s) => n + s.commands.length, 0)
  };
  fs.writeFileSync(out, JSON.stringify(results, null, 2) + "\n");
  const w = Math.max(...scenarios.map(s => s.title.length));
  console.log(["ID   RESULT      MS CALLS TITLE", ...scenarios.map(s => `${s.id.padEnd(4)} ${s.result.toUpperCase().padEnd(6)} ${String(s.duration_ms).padStart(7)} ${String(s.commands.length).padStart(5)} ${s.title.padEnd(w)}${s.error ? "  <- " + s.error : ""}`),
    `passed ${passed}/${scenarios.length}, total ${totalMs} ms, launcher calls ${results.cli_calls}`].join("\n"));
  process.exit(passed === scenarios.length ? 0 : 1);
' "$RECORDS" "$RESULTS" "$started_at" "$ended_at" "$total_ms" "$HARNESSFORGE_WORKSPACE" "$E2E_EXPORT_ROOT" "$E2E_RESTORE_TARGET" "$LOG" | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
