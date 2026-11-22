#!/usr/bin/env python3
"""Check that the Python mirror reproduces the Swift flight model: compare the JSON written by the Swift test
(OracleExportTests, see SWIFT_EMITTER.md) with run_sf1.py output, metric by metric.

    python3 check_mirror.py swift_results.json sf1_results.json [--rtol 1e-4] [--atol 1e-6]

Exit 1 if any metric differs. Differences mean the mirror (or the Swift side) has drifted: fix sf1_mirror.py
until this passes, because the JSBSim comparison in RESULTS.md is only as trustworthy as the mirror.
Curve-fitted metrics are fitted from the Swift series by compare.finalize, so they must agree too.
"""
import argparse
import json
import math

import compare


def flat(d, prefix=""):
    for k, v in d.items():
        if k == "series":
            continue
        if isinstance(v, dict):
            yield from flat(v, f"{prefix}{k}.")
        else:
            yield f"{prefix}{k}", v


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("swift"), ap.add_argument("mirror")
    ap.add_argument("--rtol", type=float, default=1e-4)
    ap.add_argument("--atol", type=float, default=1e-6)
    a = ap.parse_args()
    sw = dict(flat(compare.finalize(json.load(open(a.swift)))["scenarios"]))
    mi = dict(flat(compare.finalize(json.load(open(a.mirror)))["scenarios"]))
    bad = 0
    for k in sorted(set(sw) | set(mi)):
        x, y = sw.get(k), mi.get(k)
        if isinstance(x, (int, float)) and isinstance(y, (int, float)) and not isinstance(x, bool):
            ok = math.isclose(x, y, rel_tol=a.rtol, abs_tol=a.atol)
        else:
            ok = x == y
        if not ok:
            bad += 1
            print(f"DIFF {k}: swift={x!r} mirror={y!r}")
    print(f"{len(sw)} swift metrics, {len(mi)} mirror metrics, {bad} differences")
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
