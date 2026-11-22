#!/usr/bin/env python3
"""CI frame-time gate. Reads SKYFORGE_FRAMETIME lines (FrameTimeTests output) and compares median
frame time per scene against docs/perf_baseline.json.

Rules:
- A scene with no baseline entry is reported and never fails (baselines come from real device or
  runner runs; none are invented here).
- A scene fails when median > baseline * (1 + tolerance).
- No SKYFORGE_FRAMETIME lines at all is a failure: the gate must not pass silently.
"""
import json
import re
import sys
from pathlib import Path

LINE = re.compile(r"SKYFORGE_FRAMETIME scene=(\S+) tier=(\S+) \S+ median=([\d.]+)ms p95=([\d.]+)ms")


def parse(text):
    out = {}
    for m in LINE.finditer(text):
        scene, tier, median, p95 = m.group(1), m.group(2), float(m.group(3)), float(m.group(4))
        out[f"{scene}/{tier}"] = {"median": median, "p95": p95}
    return out


def main(log_path, baseline_path, tolerance=0.10):
    results = parse(Path(log_path).read_text(errors="replace"))
    if not results:
        print("perf gate: no SKYFORGE_FRAMETIME lines found in log; failing")
        return 1
    base = {}
    bp = Path(baseline_path)
    if bp.exists():
        base = json.loads(bp.read_text()).get("scenes", {})
    failed = []
    for key, r in sorted(results.items()):
        b = base.get(key)
        if not b:
            print(f"perf gate: {key} median {r['median']:.2f} ms (no baseline, not gated)")
            continue
        limit = b["median"] * (1 + tolerance)
        verdict = "OK" if r["median"] <= limit else "REGRESSION"
        print(f"perf gate: {key} median {r['median']:.2f} ms vs baseline {b['median']:.2f} ms "
              f"(limit {limit:.2f}) {verdict}")
        if verdict != "OK":
            failed.append(key)
    if failed:
        print("perf gate failed: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: perf_gate.py LOG BASELINE_JSON [TOLERANCE]", file=sys.stderr)
        sys.exit(2)
    tol = float(sys.argv[3]) if len(sys.argv) > 3 else 0.10
    sys.exit(main(sys.argv[1], sys.argv[2], tol))
