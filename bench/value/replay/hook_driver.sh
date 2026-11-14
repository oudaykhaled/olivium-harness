#!/bin/sh
# Replay driver for bench/value/replay/gate.py and hooks.py.
#
# Runs hook commands, exactly as a candidate .claude/settings.json registers them,
# on one-line JSON hook inputs. Each input line of $GATE_IN/payloads.tsv is
#   <hook file name><TAB><one-line JSON hook input>
# and $GATE_IN/hooks/<hook file name> holds the hook command text. The JSON is
# given to the hook on stdin only; this script never executes, evaluates or
# expands anything from it. Results: $GATE_OUT/r/<n>.out, <n>.err, <n>.code.
#
# In Docker (the default for recorded calls) the candidate harness in
# $GATE_IN/arm is installed into $GATE_PROJECT first, the way
# bench/value/arms/entry.sh installs an arm. On the host it is used only with
# synthetic inputs and a scratch copy of the export as $GATE_PROJECT.
set -u
in=${GATE_IN:?GATE_IN is required}
out=${GATE_OUT:?GATE_OUT is required}
project=${GATE_PROJECT:?GATE_PROJECT is required}
mkdir -p "$out/r" || exit 2
cd "$project" || exit 2
if [ -d "$in/arm" ] && [ "${GATE_INSTALL_ARM:-0}" = "1" ]; then
    find . -path ./.git -prune -o -path ./node_modules -prune -o \
        \( -name CLAUDE.md -o -name AGENTS.md -o -name .claude \) -print \
        | while IFS= read -r stale; do rm -rf -- "$stale"; done
    cp -a "$in/arm/." "$project/" || exit 2
fi
export CLAUDE_PROJECT_DIR="$project"
tab=$(printf '\t')
n=0
while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    hook=${line%%"$tab"*}
    payload=${line#*"$tab"}
    case $hook in
        *[!A-Za-z0-9_.-]* | '') echo 125 >"$out/r/$n.code"; continue ;;
    esac
    command=$(cat "$in/hooks/$hook") || { echo 125 >"$out/r/$n.code"; continue; }
    printf '%s\n' "$payload" | (cd "$project" && sh -c "$command") >"$out/r/$n.out" 2>"$out/r/$n.err"
    echo $? >"$out/r/$n.code"
done <"$in/payloads.tsv"
echo "$n" >"$out/count"
