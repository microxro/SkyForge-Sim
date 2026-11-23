#!/usr/bin/env python3
"""CI frame-time gate. Reads SKYFORGE_FRAMETIME lines (FrameTimeTests output) and compares median
frame time per scene against docs/perf_baseline.json.

Usage: perf_gate.py LOG [LOG ...] BASELINE_JSON [TOLERANCE]

Rules:
- Several logs are several measurements of the same build. Each scene takes its best (lowest) median
  across them, so one slow run on a noisy virtual runner cannot fail the gate on its own.
- A scene with no baseline entry is reported and never fails.
- A scene fails when its best median > baseline * (1 + tolerance). The default tolerance is 0.25: a
  virtual GPU runner varies by about 10 % between runs (a 10 % gate failed a PR that did not touch the scene).
- No SKYFORGE_FRAMETIME lines in any log is a failure: the gate must not pass silently.
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


def best_of(log_paths):
    best = {}
    for lp in log_paths:
        for key, r in parse(Path(lp).read_text(errors="replace")).items():
            if key not in best or r["median"] < best[key]["median"]:
                best[key] = r
    return best


def main(log_paths, baseline_path, tolerance=0.25):
    results = best_of(log_paths)
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
    args = sys.argv[1:]
    tol = 0.25
    if len(args) >= 2 and args[-1].replace(".", "", 1).isdigit():
        tol = float(args.pop())
    if len(args) < 2 or not args[-1].endswith(".json"):
        print("usage: perf_gate.py LOG [LOG ...] BASELINE_JSON [TOLERANCE]", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(args[:-1], args[-1], tol))
