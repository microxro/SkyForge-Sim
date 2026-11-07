#!/bin/sh
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
mkdir -p .skyforge
[ -f SKYFORGE_DONE ] && exit 0
[ -f .skyforge/rate_limited ] && exit 0
n=$(cat .skyforge/stop_blocks 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > .skyforge/stop_blocks
if [ "$n" -gt "${SKYFORGE_MAX_STOP_BLOCKS:-60}" ]; then echo 0 > .skyforge/stop_blocks; exit 0; fi
printf '%s\n' '{"decision":"block","reason":"SKYFORGE is not done (SKYFORGE_DONE absent). The user is away. Update docs/STATE.md, run tools/gate.sh fast, commit if green, then continue the next unchecked item in PROGRESS.md. Do not ask the user anything."}'
exit 0
