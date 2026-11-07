#!/bin/sh
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
mkdir -p .skyforge
date -u +%s > .skyforge/rate_limited
cat >> .skyforge/api_failures.log
exit 0
