#!/usr/bin/env python3
"""Compare SF-1 results against the JSBSim c172p oracle: table on stdout, RESULTS.md, results JSON.

    python3 compare.py [--sf1 sf1_results.json] [--jsbsim jsbsim_results.json]
                       [--md RESULTS.md] [--json oracle_results.json] [--strict]

Exit status is 0 unless --strict is given, in which case any FAIL (or missing/errored scenario) exits 1.
The oracle is a *sanity reference*, not a target: the c172p is a different real aircraft, so WARN/FAIL means
"explain it or fix it", not automatically "the SF-1 is wrong". See README.md.
"""
from __future__ import annotations

import argparse
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))

# (scenario, metric, label, unit, mode, pass_tol, warn_tol, scored)
#   mode "rel": error = (sf1 - ref) / |ref|, tolerances are fractions
#   mode "mag": relative error of magnitudes (|sf1| - |ref|) / |ref|; a sign mismatch is a FAIL
#   mode "abs": error = sf1 - ref, tolerances are in `unit`
BANDS = [
    ("trim", "alpha_deg", "Trim alpha 100 KTAS / 3000 ft", "deg", "abs", 1.0, 2.0, True),
    ("trim", "elevator_deg_up", "Trim elevator (TE up +)", "deg", "abs", 2.0, 4.0, True),
    ("trim", "throttle", "Trim throttle (fraction)", "", "abs", 0.05, 0.10, True),
    ("trim", "power_kw", "Trim shaft power", "kW", "rel", 0.10, 0.20, True),
    ("trim", "climb_fpm", "Trim climb rate", "fpm", "abs", 50.0, 100.0, True),
    ("stall_clean", "v_clmax_kcas", "Stall speed (CLmax), clean, 1000 kg", "KCAS", "rel", 0.08, 0.12, True),
    ("stall_clean", "cl_max", "CLmax clean (peak total CL)", "", "rel", 0.10, 0.20, True),
    ("stall_clean", "alpha_clmax_deg", "Alpha at CLmax clean", "deg", "abs", 2.0, 4.0, True),
    ("stall_clean", "decel_kt_per_s", "Deceleration achieved, clean", "kt/s", "rel", 0.5, 1.0, False),
    ("stall_clean", "cl_ratio_4s_after_peak", "CL retained 4 s after peak, clean", "", "abs", 0.3, 0.6, False),
    ("stall_flaps", "v_clmax_kcas", "Stall speed (CLmax), full flaps", "KCAS", "rel", 0.08, 0.12, True),
    ("stall_flaps", "cl_max", "CLmax full flaps", "", "rel", 0.10, 0.20, True),
    ("stall_flaps", "alpha_clmax_deg", "Alpha at CLmax full flaps", "deg", "abs", 2.0, 4.0, True),
    ("short_period", "wn_rad_s", "Short-period natural frequency", "rad/s", "rel", 0.20, 0.35, True),
    ("short_period", "zeta", "Short-period damping ratio", "", "rel", 0.30, 0.50, True),
    ("short_period", "q_peak_per_deg", "Peak pitch rate per deg elevator", "deg/s/deg", "rel", 0.25, 0.40, True),
    ("aileron_step", "p_ss_dps", "Steady roll rate, 50% stick", "deg/s", "rel", 0.25, 0.40, True),
    ("aileron_step", "p_per_deg_ail", "Steady roll rate per deg aileron", "deg/s/deg", "rel", 0.30, 0.50, True),
    ("aileron_step", "tau_roll_s", "Roll time constant", "s", "abs", 0.3, 0.6, True),
    ("phugoid", "period_s", "Phugoid period", "s", "rel", 0.25, 0.50, True),
    ("phugoid", "zeta", "Phugoid damping ratio", "", "abs", 0.05, 0.10, True),
    ("rudder_step", "beta_ss_per_deg_rudder", "Sideslip per deg rudder (wings level)", "deg/deg", "mag", 0.30, 0.50, True),
    ("rudder_step", "r_ss_dps", "Yaw rate at end of rudder step", "deg/s", "mag", 0.40, 0.80, False),
    ("takeoff", "liftoff_kcas", "Liftoff speed", "KCAS", "rel", 0.08, 0.15, True),
    ("takeoff", "ground_roll_ft", "Ground roll to liftoff", "ft", "rel", 0.15, 0.30, True),
    ("takeoff", "dist_to_55ft_ft", "Distance to 55 ft", "ft", "rel", 0.15, 0.30, True),
]

# Likely causes, shown for WARN/FAIL rows. Each was checked against the c172p.xml coefficients and, where
# marked [what-if], by re-running the mirror with the single coefficient changed (whatif.py).
HINTS = {
    ("trim", "elevator_deg_up"): "SF-1 cm0=0.02, cmAlpha=-0.89 vs c172p cm0=0.10, cmAlpha=-1.8. [what-if] cm0/cmAlpha at c172p values moves the trim elevator to the c172p value.",
    ("trim", "alpha_deg"): "Follows the lift curve (cL0 0.31, slope 5.14/rad) and the Cm balance above; small in absolute terms.",
    ("trim", "power_kw"): "SF-1 cD0=0.031 vs c172p 0.027 (+15%). [what-if] cD0=0.027 recovers part of the gap; the remainder is likely the flat prop efficiency (eta 0.80 in the thrust model) and the induced-drag factor (oswald 0.75).",
    ("trim", "throttle"): "Different power model: SF-1 throttle is linear in shaft power with density lapse sigma^1.1; the c172p engine map is manifold-pressure/rpm dependent.",
    ("stall_clean", "v_clmax_kcas"): "SF-1 reaches a higher effective CLmax than the c172p (see CLmax row), so it stalls slower.",
    ("stall_clean", "cl_max"): "Declared cLMaxClean=1.55, but the measured peak is total CL: up-elevator at full aft stick subtracts cLElevator*de (about -0.19) and the softplus rounding (w=0.06) shaves a little more. The c172p peaks near 1.30 at this loading.",
    ("stall_clean", "alpha_clmax_deg"): "In the SF-1 the peak sits at alpha = (cLMax - cL0) / cLAlpha = 13.8 deg, where the soft-saturated linear lift reaches CLmax. The c172p table keeps rising to about 16 deg and rolls off later. `stallAlpha` (16 deg) in AircraftConfig is not used by forcesAndMoments.",
    ("stall_flaps", "v_clmax_kcas"): "Full-flap CLmax 2.05 declared (about 1.9 measured) vs c172p 1.6: the flap lift increment cLFlap=0.55 plus cLMaxFlaps=2.05 is generous for 30 deg plain flaps.",
    ("stall_flaps", "cl_max"): "cLMaxFlaps=2.05 declared (about 1.89 measured as total CL) vs c172p about 1.6; the SF-1 flap lift increment is cLFlap=0.55 vs the c172p table's 0.35 at 30 deg.",
    ("short_period", "wn_rad_s"): "Static longitudinal stability: cmAlpha=-0.89 vs c172p -1.8 (about half, so wn ~ sqrt(2) lower). [what-if] cmAlpha=-1.8 gives c172p's wn.",
    ("short_period", "zeta"): "cmAlphaDot (-5.2) is declared in AeroCoefficients but never used by forcesAndMoments (c172p applies Cm_alphadot -7.27 and CL_alphadot 1.7), and cmAlpha is lower; damping is carried by cmQ only.",
    ("aileron_step", "p_ss_dps"): "SF-1 cnAileron=-0.053 is ~10x the c172p value (-0.0053): strong adverse yaw builds sideslip whose dihedral effect (clBeta) throttles the roll. Likely a decimal slip. [what-if] cnAileron=-0.0053 restores the c172p roll rate.",
    ("aileron_step", "p_per_deg_ail"): "Same cause as the roll-rate row (adverse yaw / clBeta), plus clAileron 0.178 vs 0.229.",
    ("phugoid", "period_s"): "Phugoid is mostly speed/drag driven; the SF-1 is close to the c172p, any residual comes from L/D and cL slope.",
    ("rudder_step", "beta_ss_per_deg_rudder"): "SF-1 cnRudder=-0.0657 vs c172p -0.043 (+53%) with similar cnBeta (0.065 vs 0.059). [what-if] cnRudder=-0.043 recovers the c172p value.",
    ("takeoff", "liftoff_kcas"): "Not isolated. SF-1 lifts off about 12 kt above the 55 kt rotation speed vs about 7 kt for the c172p with the same pitch law. Candidates: rotation pitch authority at low dynamic pressure, the 8% ground-effect lift term, main-gear height (1.25 m below CG).",
    ("takeoff", "ground_roll_ft"): "Thrust is not the cause (SF-1 static thrust 2.4 kN vs about 2.0 kN for the c172p in this run, and rolling friction is 0.02 on both). The roll follows the higher liftoff speed (distance scales with v squared).",
    ("takeoff", "dist_to_55ft_ft"): "Ground roll plus a flatter initial climb-out at the higher liftoff speed; c172p climbs out more steeply after rotation.",
    ("stall_flaps", "alpha_clmax_deg"): "Same mechanism as the clean case: the SF-1 peak sits at (cLMaxFlaps - cL0 - cLFlap) / cLAlpha = 13.3 deg, the c172p at about 16 deg.",
}


def classify(err, pass_tol, warn_tol):
    a = abs(err)
    return "PASS" if a <= pass_tol else "WARN" if a <= warn_tol else "FAIL"


def finalize(doc):
    """Swift emits raw `series` for the two curve-fit scenarios; compute their metrics here (same code as the
    Python runners, so mirror and Swift are post-processed identically)."""
    import scenarios as sc
    s = doc.get("scenarios", {})
    sp = s.get("short_period", {})
    if "series" in sp and "wn_rad_s" not in sp:
        ser = sp["series"]
        rec = [dict(t=t, q_dps=q) for t, q in zip(ser["t"], ser["q_dps"])]
        sp.update(sc._clean(sc.short_period_metrics(rec)))
    ph = s.get("phugoid", {})
    if "series" in ph and "period_s" not in ph:
        ser = ph["series"]
        rec = [dict(t=t, tas_kt=v, alt_ft=h) for t, v, h in zip(ser["t"], ser["tas_kt"], ser["alt_ft"])]
        ph.update(sc._clean(sc.phugoid_metrics(rec, 0.25)))
    return doc


def build_rows(sf1, js):
    rows = []
    for scen, key, label, unit, mode, pt, wt, scored in BANDS:
        a = sf1.get("scenarios", {}).get(scen, {})
        b = js.get("scenarios", {}).get(scen, {})
        va, vb = a.get(key), b.get(key)
        row = dict(scenario=scen, metric=key, label=label, unit=unit, mode=mode, pass_tol=pt, warn_tol=wt,
                   scored=scored, sf1=va, jsbsim=vb)
        if not isinstance(va, (int, float)) or not isinstance(vb, (int, float)) or isinstance(va, bool) \
                or math.isnan(va) or math.isnan(vb):
            row.update(error=None, status="MISSING")
        else:
            if mode == "rel" and abs(vb) > 1e-12: err = (va - vb) / abs(vb)
            elif mode == "mag" and abs(vb) > 1e-12: err = (abs(va) - abs(vb)) / abs(vb)
            else: err = va - vb
            status = classify(err, pt, wt) if scored else "INFO"
            if mode == "mag" and va * vb < 0: status = "FAIL" if scored else "INFO"   # opposite sign
            row.update(error=err, status=status,
                       severity=abs(err) / wt if wt else 0.0)
        rows.append(row)
    return rows


def fmt(v):
    if v is None: return "n/a"
    if abs(v) < 1e-9: return "0"
    if abs(v) >= 100: return f"{v:.0f}"
    if abs(v) >= 10: return f"{v:.1f}"
    return f"{v:.3g}" if abs(v) < 1 else f"{v:.2f}"


def fmt_err(r):
    if r["error"] is None: return "n/a"
    return f"{r['error'] * 100:+.1f}%" if r["mode"] in ("rel", "mag") else f"{r['error']:+.2f} {r['unit']}".strip()


def fmt_band(r):
    if r["mode"] in ("rel", "mag"): return f"{r['pass_tol']*100:.0f}% / {r['warn_tol']*100:.0f}%"
    return f"{r['pass_tol']:g} / {r['warn_tol']:g} {r['unit']}".strip()


def text_table(rows):
    w = max(len(r["label"]) for r in rows)
    out = [f"{'Metric':<{w}}  {'Unit':<9} {'SF-1':>9} {'JSBSim':>9} {'Error':>14}  {'Band (pass/warn)':<18} Status"]
    for r in rows:
        out.append(f"{r['label']:<{w}}  {r['unit']:<9} {fmt(r['sf1']):>9} {fmt(r['jsbsim']):>9} "
                   f"{fmt_err(r):>14}  {fmt_band(r):<18} {r['status']}")
    return "\n".join(out)


def markdown(rows, sf1, js, whatif):
    counts = {k: sum(1 for r in rows if r["status"] == k) for k in ("PASS", "WARN", "FAIL", "INFO", "MISSING")}
    worst = sorted([r for r in rows if r.get("severity") is not None and r["status"] in ("WARN", "FAIL")],
                   key=lambda r: -r["severity"])
    L = []
    L.append("# SF-1 vs JSBSim c172p oracle comparison")
    L.append("")
    L.append("Generated by `tools/jsbsim_oracle/compare.py`. Offline development check only: JSBSim and its c172p data "
             "(LGPL code; aircraft data under its own MIT/LGPL-style licences) are never shipped in the app and nothing was copied from them into the "
             "Swift sources.")
    L.append("")
    L.append(f"* Oracle: JSBSim {js.get('meta', {}).get('jsbsim_version', '?')}, `c172p`, loaded to "
             f"{js.get('meta', {}).get('mass_kg', '?')} kg (copilot + passenger point masses; CG 43.4 in).")
    L.append(f"* Subject: `{sf1.get('meta', {}).get('source', '?')}` (Python mirror of "
             f"`SFFlightModel`; Swift emitter output can be dropped in as `--sf1`, see SWIFT_EMITTER.md).")
    L.append("* The mirror matches `SFFlightModel` at git HEAD when written (FlightDynamics.swift 389 lines); later working-tree "
             "changes (Mach schedule, engine model, stall behaviour) are not ported, so re-run after re-porting.")
    L.append("* Identical scenarios and control laws on both sides (`scenarios.py`); both run at 120 Hz, ISA, no wind, sea-level runway.")
    L.append(f"* Result: **{counts['PASS']} PASS, {counts['WARN']} WARN, {counts['FAIL']} FAIL** "
             f"({counts['INFO']} informational, {counts['MISSING']} missing).")
    L.append("* The c172p is a different aircraft with different real-world numbers; bands are sanity bands, "
             "not a certification of equality.")
    L.append("")
    L.append("## Results")
    L.append("")
    L.append("| Metric | Unit | SF-1 | JSBSim | Error | Band (pass / warn) | Status |")
    L.append("|---|---|---:|---:|---:|---|---|")
    for r in rows:
        L.append(f"| {r['label']} | {r['unit']} | {fmt(r['sf1'])} | {fmt(r['jsbsim'])} | {fmt_err(r)} | "
                 f"{fmt_band(r)} | {r['status']} |")
    L.append("")
    L.append("## Biggest discrepancies and likely causes")
    L.append("")
    if not worst:
        L.append("None: every scored metric is within its pass band.")
    for i, r in enumerate(worst[:8], 1):
        hint = HINTS.get((r["scenario"], r["metric"]), "No hypothesis recorded.")
        L.append(f"{i}. **{r['label']}** ({r['status']}): SF-1 {fmt(r['sf1'])} vs JSBSim {fmt(r['jsbsim'])} {r['unit']} "
                 f"({fmt_err(r)}). {hint}")
    others = [r for r in worst[8:]]
    if others:
        L.append("")
        L.append("Other WARN/FAIL rows: " + "; ".join(f"{r['label']} ({fmt_err(r)})" for r in others) + ".")
    L.append("")
    L.append("### Unused or inconsistent parameters spotted while porting")
    L.append("")
    L.append("* `AeroCoefficients.cmAlphaDot` is never read by `forcesAndMoments` (no alpha-dot damping term); "
             "`cLQ` is applied but there is no `cLAlphaDot`.")
    L.append("* `AircraftConfig.stallAlpha` and `ixz` are declared but unused by the dynamics; "
             "the effective stall is set by `cLMaxClean/cLMaxFlaps` and the fixed 2.5 deg break offset.")
    L.append("* Measured CLmax (about 1.42 clean / 1.89 flaps) is below the declared 1.55 / 2.05 mainly because "
             "the full-aft elevator subtracts tail lift (cLElevator*de, about -0.19) from the total CL, plus softplus rounding "
             "(w = 0.06) before the sigmoid break.")
    L.append("* Post-stall: the SF-1 loses lift abruptly (CL retained 4 s after the peak is low) while the c172p "
             "mushes at near-constant CL. That is a design choice, not necessarily a bug.")
    if whatif:
        L.append("")
        L.append("## Sensitivity checks (mirror only, one coefficient changed at a time)")
        L.append("")
        L.append("| Change | Scenario | Metric | Value after change |")
        L.append("|---|---|---|---:|")
        for w in whatif:
            L.append(f"| {w['change']} | {w['scenario']} | {w['metric']} | {fmt(w['value'])} |")
        L.append("")
        L.append("Compare the values with the JSBSim column above: a change that lands on the oracle value "
                 "confirms the hypothesis for that discrepancy.")
    L.append("")
    L.append("## Method notes and caveats")
    L.append("")
    L.append("* Stall: power off, wings held level, pitch attitude ramped at 1 deg/s through a pitch-hold loop that saturates at "
             "full aft stick; speed is read at the CL peak. The achieved deceleration differs between aircraft (reported, "
             "informational) because idle drag and flight-path energy differ; stall speed is insensitive to it (checked at 0.35-1.4 deg/s).")
    L.append("* CL is wind-axis lift / (qbar S) on both sides, i.e. total aerodynamic CL including tail and pitch-rate terms.")
    L.append("* Short-period and phugoid values come from least-squares damped-sinusoid fits (`scenarios.fit_damped`); the short "
             "period of both aircraft is well damped so the fit conditions (wn, zeta) are less precise than the phugoid.")
    L.append("* Takeoff: same rotation law (55 KCAS, 9 deg pitch target), heading-hold on rudder/nose-wheel, height gain 55 ft "
             "measured at the CG relative to its static height. Runway friction, gear geometry and brake models differ.")
    L.append("* c172p control travels differ (elevator 28/23 deg, ailerons -20/+15, rudder 16 deg vs SF-1 25/18/20 deg); "
             "dynamics metrics use deflection in degrees where possible, step metrics use 50% stick.")
    L.append("* JSBSim's longitudinal trim leaves about 1 fpm residual climb; engine/propeller states are not reset after trim.")
    L.append("")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sf1", default=os.path.join(HERE, "sf1_results.json"))
    ap.add_argument("--jsbsim", default=os.path.join(HERE, "jsbsim_results.json"))
    ap.add_argument("--whatif", default=os.path.join(HERE, "whatif_results.json"))
    ap.add_argument("--md", default=os.path.join(HERE, "RESULTS.md"))
    ap.add_argument("--json", default=os.path.join(HERE, "oracle_results.json"))
    ap.add_argument("--strict", action="store_true", help="exit 1 on any FAIL or missing scored metric")
    a = ap.parse_args()
    sf1 = finalize(json.load(open(a.sf1)))
    js = finalize(json.load(open(a.jsbsim)))
    whatif = json.load(open(a.whatif)) if os.path.exists(a.whatif) else []
    rows = build_rows(sf1, js)
    print(text_table(rows))
    counts = {k: sum(1 for r in rows if r["status"] == k) for k in ("PASS", "WARN", "FAIL", "INFO", "MISSING")}
    print("\n" + ", ".join(f"{v} {k}" for k, v in counts.items()))
    with open(a.md, "w") as f:
        f.write(markdown(rows, sf1, js, whatif))
    with open(a.json, "w") as f:
        json.dump(dict(summary=counts, rows=rows, whatif=whatif), f, indent=2)
    print(f"wrote {a.md} and {a.json}")
    if a.strict and (counts["FAIL"] or counts["MISSING"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
