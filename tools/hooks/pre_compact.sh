#!/bin/sh
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
echo "$(date -u +%FT%TZ) compaction; last commit $(git rev-parse --short HEAD 2>/dev/null)" >> docs/VERIFICATION_LOG.md
exit 0
