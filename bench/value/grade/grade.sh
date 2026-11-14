#!/bin/bash
# Trusted grading script. Runs in a fresh --network none container from the
# deps image, as root, on a pristine checkout at base_sha.
#
#   in : /work/grade-in/{agent.patch,test.patch,test_files.z,test_command.txt,
#        lint_command.txt[,test_timeout_seconds.txt]}
#   out: /work/grade-out/{patch_applied,test_patch_applied,restored.z,removed.z,
#        lint_exit,test_exit,test_timeout_seconds,results.xml,done,...}
#
# The test command is killed after 300 s, or after the whole number of seconds in
# test_timeout_seconds.txt when that file is present (protocol 3 passes 600, twice
# the selection limit; PROTOCOL-v3.md change log, grading time limit).
#
# Order: agent patch on a clean checkout, then restore every test file and
# piece of test configuration or harness the agent touched, then the real test
# patch, then lint, then tests. An agent cannot pass by weakening the tests.
set -u
IN=/work/grade-in
OUT=/work/grade-out
mkdir -p "$OUT" /work/test-results
cd /work/repo || { echo no_repo >"$OUT/error"; exit 3; }
git config --global --add safe.directory /work/repo
GIT=(git -c core.hooksPath=/dev/null)

is_protected() {
    local path=$1
    case "/$path/" in
        */test/*|*/tests/*|*/testing/*|*/__tests__/*|*/spec/*|*/specs/*) return 0 ;;
    esac
    local base=${path##*/}
    case "$base" in
        conftest.py|pytest.ini|.pytest.ini|pytest.toml|.pytest.toml|tox.ini) return 0 ;;
        noxfile.py|setup.cfg|pyproject.toml|sitecustomize.py|.coveragerc) return 0 ;;
        ruff.toml|.ruff.toml|package.json|package-lock.json|npm-shrinkwrap.json) return 0 ;;
        yarn.lock|pnpm-lock.yaml|.npmrc|.nycrc|.nycrc.json|.nycrc.yml|.nycrc.yaml) return 0 ;;
        .mocharc|.mocharc.*|jest.config.*|jest.setup.*|vitest.config.*|vitest.setup.*) return 0 ;;
        karma.conf.*|.eslintrc|.eslintrc.*|eslint.config.*|.eslintignore) return 0 ;;
        .travis.yml|.gitlab-ci.yml|appveyor.yml|azure-pipelines.yml|Jenkinsfile) return 0 ;;
        codecov.yml|.codecov.yml|.pre-commit-config.yaml|.flake8|mypy.ini|.mypy.ini) return 0 ;;
    esac
    case "$path" in
        .github/*|.circleci/*|.gitlab/*|.azure-pipelines/*|.buildkite/*) return 0 ;;
    esac
    # `python -m pytest` puts the repository root first on sys.path, so a module
    # or package there can shadow the test runner, and any *.dist-info there can
    # register a pytest plugin. Those would forge results without touching a test.
    case "$path" in
        *.dist-info/*|*.egg-info/*) return 0 ;;
        */*)
            case "${path%%/*}" in
                pytest|_pytest|pluggy|iniconfig|packaging|exceptiongroup|tomli|py) return 0 ;;
            esac
            ;;
        *.py|*.pth) return 0 ;;
    esac
    return 1
}

patch_applied=true
if [ -s "$IN/agent.patch" ]; then
    if ! "${GIT[@]}" apply --whitespace=nowarn "$IN/agent.patch" 2>"$OUT/agent_apply.stderr"; then
        patch_applied=false
    fi
fi
echo "$patch_applied" >"$OUT/patch_applied"

# Index-only snapshot of what the agent's patch changed, including new files.
"${GIT[@]}" add -A >/dev/null 2>&1
"${GIT[@]}" diff --cached --name-only --no-renames -z HEAD >"$OUT/changed.z"

restore_path() {
    local path=$1
    if "${GIT[@]}" cat-file -e "HEAD:$path" 2>/dev/null; then
        "${GIT[@]}" checkout -q HEAD -- "$path"
        printf '%s\0' "$path" >>"$OUT/restored.z"
    else
        "${GIT[@]}" rm -q -f --cached -- "$path" >/dev/null 2>&1
        rm -f -- "$path"
        printf '%s\0' "$path" >>"$OUT/removed.z"
    fi
}

: >"$OUT/restored.z"
: >"$OUT/removed.z"
if [ ! -f "$IN/no_protect" ]; then
    while IFS= read -r -d '' path; do
        [ -n "$path" ] || continue
        if is_protected "$path"; then
            restore_path "$path"
        fi
    done <"$OUT/changed.z"
    # The real test files are always restored, even outside the path rules.
    while IFS= read -r -d '' path; do
        [ -n "$path" ] || continue
        if ! "${GIT[@]}" diff --quiet HEAD -- "$path" 2>/dev/null \
           || ! "${GIT[@]}" cat-file -e "HEAD:$path" 2>/dev/null; then
            restore_path "$path"
        fi
    done <"$IN/test_files.z"
fi
"${GIT[@]}" reset -q >/dev/null 2>&1

test_patch_applied=true
if [ -s "$IN/test.patch" ]; then
    if ! "${GIT[@]}" apply --whitespace=nowarn "$IN/test.patch" 2>"$OUT/test_apply.stderr"; then
        test_patch_applied=false
    fi
fi
echo "$test_patch_applied" >"$OUT/test_patch_applied"

lint_cmd=$(cat "$IN/lint_command.txt" 2>/dev/null || true)
if [ -n "$lint_cmd" ] && [ "$test_patch_applied" = true ]; then
    timeout --signal=KILL 300 bash -c "$lint_cmd" >"$OUT/lint.log" 2>&1
    echo "$?" >"$OUT/lint_exit"
else
    echo none >"$OUT/lint_exit"
fi

test_cmd=$(cat "$IN/test_command.txt")
test_limit=300
if [ -f "$IN/test_timeout_seconds.txt" ]; then
    test_limit=$(cat "$IN/test_timeout_seconds.txt")
    case "$test_limit" in
        ''|*[!0-9]*) echo bad_test_timeout >"$OUT/error"; exit 3 ;;
    esac
fi
echo "$test_limit" >"$OUT/test_timeout_seconds"
if [ "$test_patch_applied" = true ]; then
    started=$(date +%s)
    timeout --signal=KILL "$test_limit" bash -c "$test_cmd" >"$OUT/test.log" 2>&1
    echo "$?" >"$OUT/test_exit"
    echo "$(( $(date +%s) - started ))" >"$OUT/test_wall_seconds"
    if [ -f /work/test-results/results.xml ]; then
        cp /work/test-results/results.xml "$OUT/results.xml"
    fi
else
    echo none >"$OUT/test_exit"
fi
touch "$OUT/done"
