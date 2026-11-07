#!/usr/bin/env python3
"""Fail if two tracked paths differ only by letter case (they collide on macOS/Windows filesystems)."""
import subprocess, sys
paths = subprocess.run(['git', 'ls-files'], capture_output=True, text=True, check=True).stdout.split('\n')
seen, bad = {}, []
for p in filter(None, paths):
    parts = p.split('/')
    for i in range(1, len(parts) + 1):
        prefix = '/'.join(parts[:i])
        key = prefix.lower()
        if key in seen and seen[key] != prefix:
            bad.append((seen[key], prefix))
        seen.setdefault(key, prefix)
for a, b in sorted(set(bad)):
    print(f'path case collision: {a} vs {b}')
print('path check:', 'FAIL' if bad else 'OK')
sys.exit(1 if bad else 0)
