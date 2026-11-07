#!/bin/sh
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
echo "SKYFORGE AUTONOMOUS MODE. The user is away. Never ask questions. Priorities: compile, licence, VISUALS, PERFORMANCE. Re-read docs/MASTER_PROMPT.md sections 1, 2, 8, 22 if unsure."
echo "--- docs/STATE.md (head) ---"; head -n 60 docs/STATE.md 2>/dev/null
echo "--- PROGRESS.md current ---"; grep -n -A4 "CURRENT" PROGRESS.md 2>/dev/null | head -n 20
echo "--- last commits ---"; git log --oneline -n 8 2>/dev/null
echo "Next action: run tools/gate.sh fast, then continue the CURRENT item."
exit 0
