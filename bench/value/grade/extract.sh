#!/bin/bash
# Runs in a fresh --network none container from the agent image.
# The agent's working tree was copied to /work/agent/repo. Its .git is removed
# and the diff is taken against the pristine repository at /work/repo, so
# nothing the agent wrote into .git (config, hooks, refs) is ever used.
set -u
out=/work/extract-out
mkdir -p "$out"
tree=/work/agent/repo
[ -d "$tree" ] || { echo missing_tree >"$out/error"; exit 3; }
find "$tree" -name .git -prune -exec rm -rf {} + 2>/dev/null
chmod -R u+rwX "$tree" 2>/dev/null
export GIT_DIR=/work/repo/.git GIT_WORK_TREE="$tree"
git_safe=(git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.pager=cat)
cd "$tree" || exit 3
"${git_safe[@]}" add -A -- . \
    ':(exclude,top)CLAUDE.md' ':(exclude,top)AGENTS.md' ':(exclude,top).claude' \
    ':(exclude,top).cursor' ':(exclude,top).github/copilot-instructions.md' \
    ':(exclude,top).olivium' \
    2>"$out/add.stderr"
add_status=$?
"${git_safe[@]}" diff --cached --binary --no-color --no-ext-diff --no-textconv --no-renames HEAD \
    >"$out/agent.patch" 2>"$out/diff.stderr"
diff_status=$?
"${git_safe[@]}" diff --cached --name-only --no-renames -z HEAD >"$out/changed.z" 2>/dev/null
echo "$add_status" >"$out/add_status"
echo "$diff_status" >"$out/diff_status"
touch "$out/done"
