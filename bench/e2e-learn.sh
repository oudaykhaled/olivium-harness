#!/usr/bin/env bash
# bench/e2e-learn.sh — end-to-end checks of `learn` (lane L, contract-v4.md section 4) at $0.
#
# Usage:
#   LEARN_REPO=/abs/repo-at-base LEARN_OUT=/abs/fresh-dir VERIFY_IMAGE=deps-image:tag \
#     HARNESSFORGE_WORKSPACE=/abs/workspace bash bench/e2e-learn.sh
# Environment:
#   LEARN_REPO      (required) a git repository whose HEAD is the base commit; the mock plan
#                   bench/../test/fixtures/learning/plan-click.json is written for the bench's
#                   pallets/click repository at base 7944461a
#   LEARN_OUT       (required) a directory that does not exist yet; every run writes under it
#   VERIFY_IMAGE    (required) the verification image (the repository's deps image)
#   METER_IMAGE     mock meter image (default olivium-bench-meter:v1)
#   LEARN_PLAN      mock plan (default test/fixtures/learning/plan-click.json)
#   LEARN_PLAN_NATIVE  mock plan with proposed skills and subagents for L-N1..L-N4
#                   (default test/fixtures/learning/plan-click-native.json)
#   DOCKER_SLOT     optional wrapper that takes a Docker slot, e.g. a with_docker_slot.sh
#   CHECK_LEARNED   optional independent checker, run as: python3 -I CHECK_LEARNED BUNDLE_DIR/learned.json
#   HARNESSFORGE_WORKSPACE  workspace for the CLI (required by the app at boot)
#
# Nothing here calls a paid model: the learner runs against the mock meter, and the
# refusal checks start no learner. Repository commands run only inside the verification
# image with network none. Exit status 1 if any check failed.
set -u
project=$(cd "$(dirname "$0")/.." && pwd)
cd "$project" || exit 2
: "${LEARN_REPO:?LEARN_REPO is required}"
: "${LEARN_OUT:?LEARN_OUT is required}"
: "${VERIFY_IMAGE:?VERIFY_IMAGE is required}"
: "${HARNESSFORGE_WORKSPACE:?HARNESSFORGE_WORKSPACE is required}"
export HARNESSFORGE_WORKSPACE
METER_IMAGE=${METER_IMAGE:-olivium-bench-meter:v1}
LEARN_PLAN=${LEARN_PLAN:-$project/test/fixtures/learning/plan-click.json}
LEARN_PLAN_NATIVE=${LEARN_PLAN_NATIVE:-$project/test/fixtures/learning/plan-click-native.json}
DOCKER_SLOT=${DOCKER_SLOT:-}
CHECK_LEARNED=${CHECK_LEARNED:-}

if [ -e "$LEARN_OUT" ]; then echo "LEARN_OUT must not exist: $LEARN_OUT" >&2; exit 2; fi
mkdir -p "$LEARN_OUT" || exit 2

# Compile first so that "Compiling ..." lines from mix do not mix with the JSON on stdout.
mix compile >"$LEARN_OUT/compile.log" 2>&1 || { echo "mix compile failed" >&2; exit 2; }

# `bin/harnessforge learn` once the CLI dispatches it; until then the module entry point.
learn() {
  if grep -q '"learn"' lib/harness_forge/cli.ex; then
    bin/harnessforge learn "$@"
  else
    mix run -e 'HarnessForge.CLI.Learn.main(System.argv())' -- "$@"
  fi
}

# Read one value from a JSON file: field PATH (dotted) FILE.
field() {
  python3 -I -c '
import json, sys
value = json.load(open(sys.argv[2]))
for key in sys.argv[1].split("."):
    value = value[int(key)] if isinstance(value, list) else value.get(key)
print(json.dumps(value) if isinstance(value, (dict, list)) else value)
' "$1" "$2"
}

failures=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1: expected '$3', got '$2'"; fi; }

run() {
  local name=$1; shift
  local started=$SECONDS
  "$@" >"$LEARN_OUT/$name.stdout" 2>"$LEARN_OUT/$name.stderr"
  local code=$?
  echo "$code" >"$LEARN_OUT/$name.exit"
  echo "ran $name: exit $code in $((SECONDS - started)) s"
  return "$code"
}

# L1, L2: mock learn twice into fresh directories; the bundles must be byte-identical.
mock=(--verify-image "$VERIFY_IMAGE" --mock-plan "$LEARN_PLAN" --meter-image "$METER_IMAGE" --json)
run mock-a $DOCKER_SLOT bash -c "$(declare -f learn); learn \"\$@\"" _ "$LEARN_REPO" --out "$LEARN_OUT/mock-a" "${mock[@]}"
check "L1 mock learn exit" "$(cat "$LEARN_OUT/mock-a.exit")" 0
if [ -f "$LEARN_OUT/mock-a/learned.json" ]; then
  j=$LEARN_OUT/mock-a.stdout
  check "L1 learner status" "$(field result.learner.status "$j")" mock
  check "L1 verification status" "$(field result.verification.status "$j")" ok
  commands=$(field result.kept.commands "$j")
  rewrites=$(field result.kept.rewrites "$j")
  if [ "${commands:-0}" -ge 1 ]; then pass "L1 commands verified ($commands)"; else fail "L1 no command verified"; fi
  if [ "${rewrites:-0}" -ge 1 ]; then pass "L1 rewrites verified ($rewrites)"; else fail "L1 no rewrite verified"; fi
  mypy=$(python3 -I -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(sum(1 for r in doc["rewrites"] if r["kind"] == "missing_tool" and r["match"]["argv_prefix"] == ["uv", "run", "mypy"]))
' "$LEARN_OUT/mock-a/learned.json")
  check "L1 missing_tool rewrite for 'uv run mypy'" "$mypy" 1
  dropped=$(field result.dropped_items "$j")
  if [ "${dropped:-0}" -ge 1 ]; then pass "L1 dropped with reasons: $(field result.dropped "$j")"; else fail "L1 nothing dropped"; fi
  # The plan only writes the raw file: no model output, no repository file changes.
  check "L1 learner requests > 0" "$( [ "$(field result.learner.requests "$j")" -gt 0 ] && echo yes)" yes
  if [ -n "$CHECK_LEARNED" ]; then
    if python3 -I "$CHECK_LEARNED" "$LEARN_OUT/mock-a/learned.json" >"$LEARN_OUT/check-learned.txt" 2>&1; then
      pass "L1 independent checker"; else fail "L1 independent checker: $(tail -3 "$LEARN_OUT/check-learned.txt")"; fi
  fi
else
  fail "L1 no bundle written"
fi

run mock-b $DOCKER_SLOT bash -c "$(declare -f learn); learn \"\$@\"" _ "$LEARN_REPO" --out "$LEARN_OUT/mock-b" "${mock[@]}"
check "L2 second mock learn exit" "$(cat "$LEARN_OUT/mock-b.exit")" 0
if cmp -s "$LEARN_OUT/mock-a/learned.json" "$LEARN_OUT/mock-b/learned.json" &&
   cmp -s "$LEARN_OUT/mock-a/learned.sha256" "$LEARN_OUT/mock-b/learned.sha256"; then
  pass "L2 byte-identical bundles ($(cut -c1-16 "$LEARN_OUT/mock-a/learned.sha256"))"
else
  fail "L2 bundles differ"
fi

# L3: the same --out again is refused (exit 1) and the bundle is untouched.
before=$(shasum -a 256 "$LEARN_OUT/mock-a/learned.json" 2>/dev/null)
run again learn "$LEARN_REPO" --out "$LEARN_OUT/mock-a" "${mock[@]}"
check "L3 existing --out exit" "$(cat "$LEARN_OUT/again.exit")" 1
check "L3 bundle untouched" "$(shasum -a 256 "$LEARN_OUT/mock-a/learned.json" 2>/dev/null)" "$before"

# L4: --allow-cloud without --key-file is a usage error and writes nothing.
run cloud-no-key learn "$LEARN_REPO" --out "$LEARN_OUT/cloud-no-key" --verify-image "$VERIFY_IMAGE" --allow-cloud
check "L4 --allow-cloud without --key-file exit" "$(cat "$LEARN_OUT/cloud-no-key.exit")" 2
check "L4 nothing written" "$( [ -e "$LEARN_OUT/cloud-no-key" ] && echo written || echo none)" none

# L5: without --allow-cloud no model runs; the bundle says unavailable/cloud_not_allowed.
run no-cloud $DOCKER_SLOT bash -c "$(declare -f learn); learn \"\$@\"" _ "$LEARN_REPO" --out "$LEARN_OUT/no-cloud" --verify-image "$VERIFY_IMAGE"
check "L5 no --allow-cloud exit" "$(cat "$LEARN_OUT/no-cloud.exit")" 0
if grep -q '^AI learning: unavailable (cloud_not_allowed)' "$LEARN_OUT/no-cloud.stdout"; then
  pass "L5 summary line: $(grep '^AI learning:' "$LEARN_OUT/no-cloud.stdout" | cut -c1-60)"
else
  fail "L5 summary does not say unavailable (cloud_not_allowed)"
fi
for prefix in "AI learning:" "Kept:" "Dropped:" "Bundle:"; do
  grep -q "^$prefix" "$LEARN_OUT/no-cloud.stdout" || fail "L5 summary line '$prefix' missing"
done

# L6: no Docker: verification unavailable/no_docker and every command not_verified.
run no-docker env DOCKER_HOST=unix:///nonexistent bash -c "$(declare -f learn); learn \"\$@\"" _ "$LEARN_REPO" --out "$LEARN_OUT/no-docker" --verify-image "$VERIFY_IMAGE" --json
check "L6 no Docker exit" "$(cat "$LEARN_OUT/no-docker.exit")" 0
if [ -f "$LEARN_OUT/no-docker/learned.json" ]; then
  j=$LEARN_OUT/no-docker.stdout
  check "L6 verification status" "$(field result.verification.status "$j")" unavailable
  check "L6 verification reason" "$(field result.verification.status_reason "$j")" no_docker
  check "L6 commands kept" "$(field result.kept.commands "$j")" 0
  reasons=$(python3 -I -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(",".join(sorted({d["reason"] for d in doc["dropped"] if d["kind"] == "command"})))
' "$LEARN_OUT/no-docker/learned.json")
  case ",$reasons," in
    *,not_verified,*) pass "L6 command drop reasons ($reasons)" ;;
    *) fail "L6 commands were not dropped as not_verified ($reasons)" ;;
  esac
fi

# L7: --allow-cloud with a key file that does not exist: Docker cannot mount it, the meter
# never starts, no request is made, and the bundle says unavailable/no_key_file.
missing_key=$LEARN_OUT/no-such-key-file
run missing-key $DOCKER_SLOT bash -c "$(declare -f learn); learn \"\$@\"" _ "$LEARN_REPO" --out "$LEARN_OUT/missing-key" --verify-image "$VERIFY_IMAGE" --allow-cloud --key-file "$missing_key" --meter-image "$METER_IMAGE" --json
check "L7 missing key file exit" "$(cat "$LEARN_OUT/missing-key.exit")" 0
if [ -f "$LEARN_OUT/missing-key/learned.json" ]; then
  j=$LEARN_OUT/missing-key.stdout
  check "L7 learner status" "$(field result.learner.status "$j")" unavailable
  check "L7 learner reason" "$(field result.learner.status_reason "$j")" no_key_file
  check "L7 learner requests" "$(field result.learner.requests "$j")" 0
  check "L7 learner cost" "$(field result.learner.cost_nanousd "$j")" 0
fi

# L-N1..L-N4: learned skills and subagents (design section 4). The mock plan proposes two skills and three subagents;
# one skill cites a path missing at the base and one subagent a command the deps image does not verify.
# L-N1: kept skills and subagents, with those two drops and their reasons.
native_args=(--verify-image "$VERIFY_IMAGE" --mock-plan "$LEARN_PLAN_NATIVE" --meter-image "$METER_IMAGE" --json)
run native-a $DOCKER_SLOT bash -c "$(declare -f learn); learn \"\$@\"" _ "$LEARN_REPO" --out "$LEARN_OUT/native-a" "${native_args[@]}"
check "L-N1 mock learn (native plan) exit" "$(cat "$LEARN_OUT/native-a.exit")" 0
if [ -f "$LEARN_OUT/native-a/learned.json" ]; then
  verdict=$(python3 -I -c '
import json, sys
doc = json.load(open(sys.argv[1]))
skills, agents = doc.get("skills") or [], doc.get("agents") or []
drops = sorted({(d["kind"], d["reason"]) for d in doc.get("dropped", []) if d.get("kind") in ("skill", "agent")})
print(json.dumps({"skills": len(skills), "agents": len(agents), "agent_kinds": sorted(a.get("kind") for a in agents),
                  "drops": drops}))
' "$LEARN_OUT/native-a/learned.json")
  echo "L-N1 bundle: $verdict"
  case "$verdict" in *'"skills": 0'*) fail "L-N1 no skill kept" ;; *) pass "L-N1 skills kept" ;; esac
  case "$verdict" in *'"agents": 0'*) fail "L-N1 no subagent kept" ;; *) pass "L-N1 subagents kept" ;; esac
  case "$verdict" in *'["skill", "path_missing_at_base"]'*) pass "L-N1 skill dropped path_missing_at_base" ;; *) fail "L-N1 no skill dropped path_missing_at_base" ;; esac
  case "$verdict" in *'["agent", "not_verified"]'*) pass "L-N1 subagent dropped not_verified" ;; *) fail "L-N1 no subagent dropped not_verified" ;; esac
  j=$LEARN_OUT/native-a.stdout
  check "L-N1 learner status" "$(field result.learner.status "$j")" mock
else
  fail "L-N1 no bundle written"
fi

# L-N2: the same plan again gives a byte-identical bundle.
run native-b $DOCKER_SLOT bash -c "$(declare -f learn); learn \"\$@\"" _ "$LEARN_REPO" --out "$LEARN_OUT/native-b" "${native_args[@]}"
check "L-N2 second mock learn (native plan) exit" "$(cat "$LEARN_OUT/native-b.exit")" 0
if cmp -s "$LEARN_OUT/native-a/learned.json" "$LEARN_OUT/native-b/learned.json" &&
   cmp -s "$LEARN_OUT/native-a/learned.sha256" "$LEARN_OUT/native-b/learned.sha256"; then
  pass "L-N2 byte-identical native bundles ($(cut -c1-16 "$LEARN_OUT/native-a/learned.sha256"))"
else
  fail "L-N2 native bundles differ"
fi

# L-N3: lean-ai renders the learned items as skills and subagents, byte-identically twice.
generate() { bin/harnessforge generate "$LEARN_REPO" --runtime claude_code --context lean-ai "$@"; }
run native-gen-a generate --learned "$LEARN_OUT/native-a" --export "$LEARN_OUT/native-export-a" --json
check "L-N3 generate --context lean-ai exit" "$(cat "$LEARN_OUT/native-gen-a.exit")" 0
run native-gen-b generate --learned "$LEARN_OUT/native-a" --export "$LEARN_OUT/native-export-b" --json
check "L-N3 second generate exit" "$(cat "$LEARN_OUT/native-gen-b.exit")" 0
if [ -d "$LEARN_OUT/native-export-a" ] && diff -r "$LEARN_OUT/native-export-a" "$LEARN_OUT/native-export-b" >/dev/null 2>&1; then
  pass "L-N3 byte-identical exports"
else
  fail "L-N3 exports differ or are missing"
fi
learned_items=$(python3 -I -c '
import json, os, sys
line = [l for l in open(sys.argv[1]) if l.startswith("{")][-1]
native = json.loads(line)["result"]["native"]
learned = [i for i in native["items"] if i["origin"] == "learned"]
missing = [i["path"] for i in learned if not os.path.isfile(os.path.join(sys.argv[2], i["path"]))]
print("%d %s %s" % (len(learned), ",".join(i["name"] for i in learned), ",".join(missing) or "-"))
' "$LEARN_OUT/native-gen-a.stdout" "$LEARN_OUT/native-export-a" 2>/dev/null)
echo "L-N3 learned items: ${learned_items:-none}"
case "$learned_items" in
  ""|0\ *) fail "L-N3 no learned skill or subagent rendered" ;;
  *" -") pass "L-N3 learned items rendered and on disk ($learned_items)" ;;
  *) fail "L-N3 learned item files missing ($learned_items)" ;;
esac

# L-N4: a bundle whose learner did not run (L5, cloud_not_allowed) still generates, says so, and renders nothing learned.
run native-gen-unavailable generate --learned "$LEARN_OUT/no-cloud" --export "$LEARN_OUT/native-export-unavailable"
check "L-N4 generate with an unavailable learner exit" "$(cat "$LEARN_OUT/native-gen-unavailable.exit")" 0
if grep -q '^AI learning: unavailable' "$LEARN_OUT/native-gen-unavailable.stdout" &&
   grep -q 'ai_learning_unavailable' "$LEARN_OUT/native-gen-unavailable.stdout"; then
  pass "L-N4 the unavailable learner is shown with its warning"
else
  fail "L-N4 the unavailable learner is not shown"
fi
if grep -q '^native      ' "$LEARN_OUT/native-gen-unavailable.stdout"; then
  pass "L-N4 native line: $(grep '^native      ' "$LEARN_OUT/native-gen-unavailable.stdout" | cut -c1-90)"
else
  fail "L-N4 no native line in the summary"
fi
if [ -d "$LEARN_OUT/native-export-unavailable" ] && ! grep -rqs '"origin":"learned"' "$LEARN_OUT/native-export-unavailable/.olivium/native-provenance.json"; then
  pass "L-N4 nothing learned rendered"
else
  fail "L-N4 learned items rendered without a learner, or no export"
fi

echo "learn e2e: $failures failed"
[ "$failures" -eq 0 ]
