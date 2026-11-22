#!/usr/bin/env python3
"""Sensitivity checks on the SF-1 mirror: change ONE coefficient toward the c172p value and re-run the
affected scenario, to confirm (or refute) a suspected cause of a discrepancy. Writes whatif_results.json.

    python3 whatif.py [-o whatif_results.json]

Only the Python mirror is modified in memory; nothing is written to the Swift sources.
"""
from __future__ import annotations

import argparse
import dataclasses
import json

import run_sf1 as s
import scenarios as sc
import sf1_mirror as m

# (label, aero overrides, scenario, headline metric, c172p reference note)
CHECKS = [
    ("cnAileron -0.053 -> -0.0053 (c172p Cn_da)", dict(cnAileron=-0.0053), "aileron_step", "p_ss_dps"),
    ("cmAlpha -0.89 -> -1.8 (c172p Cm_alpha)", dict(cmAlpha=-1.8), "short_period", "wn_rad_s"),
    ("cmAlpha -0.89 -> -1.8 (c172p Cm_alpha)", dict(cmAlpha=-1.8), "short_period", "zeta"),
    ("cm0 0.02 -> 0.10 and cmAlpha -> -1.8 (c172p)", dict(cm0=0.10, cmAlpha=-1.8), "trim", "elevator_deg_up"),
    ("cD0 0.031 -> 0.027 (c172p CD0)", dict(cD0=0.027), "trim", "power_kw"),
    ("cnRudder -0.0657 -> -0.043 (c172p Cn_dr)", dict(cnRudder=-0.043), "rudder_step", "beta_ss_per_deg_rudder"),
]


def plant_with(**overrides):
    class P(s.SF1Plant):
        def __init__(self):
            super().__init__()
            cfg = dataclasses.replace(m.SF1, aero=dataclasses.replace(m.SF1.aero, **overrides))
            self.fm = m.FlightModel(cfg)
    return P


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--out", default="whatif_results.json")
    a = ap.parse_args()
    rows = []
    for label, ov, scen, key in CHECKS:
        res = sc._clean(sc.RUNNERS[scen](plant_with(**ov)()))
        rows.append(dict(change=label, scenario=scen, metric=key, value=res[key]))
        print(f"{label:55s} {scen}.{key} = {res[key]:.4g}")
    json.dump(rows, open(a.out, "w"), indent=2)


if __name__ == "__main__":
    main()
