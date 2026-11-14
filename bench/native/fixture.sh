#!/usr/bin/env bash
# bench/native/fixture.sh - writes the synthetic repository the native (skills and subagents) checks generate from.
#
# Usage: bash bench/native/fixture.sh FRESH_REPOSITORY_DIRECTORY [SECRET_VALUE] [AREAS]
#
# A Python-shaped repository with history the native templates can use: src/acme/http/h11.py and tools.py change
# together 8 times with tests/test_http.py, then a revert and three fixes (two follow-ups within 7 days), then a
# hostile commit (forged record separators in its subject, odd file names) that must leave no trace; 40 more
# sources; 5 more sources with 3 paired changes each to their own test, so 6 tests are history-paired. Every commit
# subject carries ZZSUBJECTMARK, which must never reach an export. pyproject.toml and the CI file make `pytest` the
# test command. SECRET_VALUE (optional) goes into .env as a planted value that must never be printed. AREAS (optional,
# 1 or 3, default 1) set to 3 appends two more areas, src/acme/db/{pool,conn}.py with tests/test_db.py and
# src/acme/cli/{main,args}.py with tests/test_cli.py, 5 joint changes each, so the export gets three area skills
# (bench/native/probe.py check E-N8); the default repository and its commits are unchanged.
# Used by bench/e2e-cli.sh (C25-C30) and bench/run.sh (stage e2e-native); bench/e2e.cjs (B23) builds the same
# repository in JavaScript. Nothing in the repository is ever run. Dates are fixed, so the commits are identical
# on every run.
set -eu
repo=${1:?usage: fixture.sh FRESH_REPOSITORY_DIRECTORY [SECRET_VALUE] [AREAS]}
secret=${2:-}
areas=${3:-1}
case "$areas" in 1 | 3) ;; *) echo "fixture.sh: AREAS must be 1 or 3" >&2; exit 2 ;; esac
mark=ZZSUBJECTMARK
author="Synthetic Author"
email=synthetic-author@example.invalid
[ ! -e "$repo" ] || { echo "fixture.sh: $repo exists" >&2; exit 2; }
mkdir -p "$repo/.github/workflows"

fixture_git() { # day args...
  local stamp day=$1
  shift
  stamp="$((1772366400 + day * 86400)) +0000" # 2026-03-01T12:00:00Z + day days
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME="$author" GIT_AUTHOR_EMAIL="$email" GIT_AUTHOR_DATE="$stamp" \
    GIT_COMMITTER_NAME="$author" GIT_COMMITTER_EMAIL="$email" GIT_COMMITTER_DATE="$stamp" \
    git -C "$repo" "$@"
}
fixture_commit() { # day subject files...
  local day=$1 subject=$2 file
  shift 2
  for file in "$@"; do
    mkdir -p "$repo/$(dirname "$file")"
    printf '# change on day %s\n' "$day" >> "$repo/$file"
  done
  fixture_git "$day" add --all
  fixture_git "$day" commit --quiet -m "$subject"
}

fixture_git 0 init --quiet --initial-branch=main
printf '[project]\nname = "acme"\nversion = "0.1.0"\n\n[tool.pytest.ini_options]\ntestpaths = ["tests"]\n' > "$repo/pyproject.toml"
printf 'name: tests\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: pip install -e .\n      - run: pytest\n' > "$repo/.github/workflows/tests.yml"
if [ -n "$secret" ]; then printf 'API_TOKEN=%s\n' "$secret" > "$repo/.env"; fi
sources=()
for i in $(seq 1 40); do sources+=("src/acme/m$i.py"); done
fixture_commit 0 "feat: $mark initial" src/acme/__init__.py src/acme/http/h11.py src/acme/http/tools.py "${sources[@]}" \
  tests/test_http.py tests/test_m1.py tests/test_m2.py tests/test_m3.py tests/test_m4.py tests/test_m5.py
for n in 1 2 3 4 5 6 7 8; do
  fixture_commit "$n" "feat: $mark http change $n" src/acme/http/h11.py src/acme/http/tools.py tests/test_http.py
done
fixture_commit 9 "Revert \"$mark http change 8\"" src/acme/http/h11.py src/acme/http/tools.py
fixture_commit 12 "fix: $mark crash in h11" src/acme/http/h11.py tests/test_http.py
fixture_commit 14 "fix: $mark crash in h11 again" src/acme/http/h11.py tests/test_http.py
fixture_commit 17 "fix: $mark h11 third" src/acme/http/h11.py tests/test_http.py
# A hostile commit: its subject holds the log record separators (bytes 1, 2 and 3) to forge a "fix" with a SHA that
# is not in this history, plus a front-matter fence, backticks and a command substitution; its files include names
# with a quote, a newline and an @. None of it may reach an export: the forged SHA would fail C25's ancestor check.
forged=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
hostile=$(printf 'feat: %s hostile \001%s\0021772366400\002\002fix: forged\003 --- `id` $(id)' "$mark" "$forged")
fixture_commit 18 "$hostile" src/acme/http/h11.py src/acme/http/tools.py tests/test_http.py \
  'src/acme/odd"quote.py' 'src/acme/at@sign.py' "$(printf 'src/acme/new\nline.py')"
for k in 1 2 3 4 5; do
  for n in 1 2 3; do
    fixture_commit $((20 + k * 4 + n)) "feat: $mark m$k $n" "src/acme/m$k.py" "tests/test_m$k.py"
  done
done
if [ "$areas" = 3 ]; then
  for n in 1 2 3 4 5; do
    fixture_commit $((50 + n)) "feat: $mark db change $n" src/acme/db/pool.py src/acme/db/conn.py tests/test_db.py
  done
  for n in 1 2 3 4 5; do
    fixture_commit $((60 + n)) "feat: $mark cli change $n" src/acme/cli/main.py src/acme/cli/args.py tests/test_cli.py
  done
fi
