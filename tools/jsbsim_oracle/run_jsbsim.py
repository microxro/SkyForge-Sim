#!/usr/bin/env python3
"""Run the shared scenarios on JSBSim's Cessna 172P (the oracle).

    python3 run_jsbsim.py [-o jsbsim_results.json] [--only trim,stall_clean] [--selfcheck]

OFFLINE DEV TOOL ONLY. JSBSim and its c172p data (LGPL / MIT, see README.md) are never shipped in the app
and nothing is copied from them into the Swift sources; this script only compares numbers.

The c172p is loaded to the same 1000 kg as the SF-1 by adding payload (copilot + passenger point masses).
"""
from __future__ import annotations

import argparse
import json
import math
import time

import jsbsim

import scenarios as sc

FT = sc.FT
LB_PER_KG = 2.2046226
D2R = math.pi / 180.0
# c172p control surface travel (c172p.xml FCS): elevator -28..+23 deg (pos. = TE down), left aileron
# -20..+15 deg, rudder +-16 deg. Commands scale piecewise: cmd<0 by the min travel, cmd>0 by the max travel.
ELEV_MIN, ELEV_MAX = -28.0, 23.0


class JSBSimPlant:
    name = "JSBSim c172p"
    dt = 1.0 / 120.0
    mass_kg = sc.MASS_KG
    elev_up_max_deg = 28.0
    elev_dn_max_deg = 23.0
    ail_max_deg = 17.5      # mean of the +15/-20 travel
    rud_max_deg = 16.0

    # control sign conventions of the c172p FCS (verified by --selfcheck):
    #   elevator-cmd-norm  -1 = stick back (TE up);   aileron-cmd-norm +1 = roll right;
    #   rudder-cmd-norm    -1 = right pedal (nose right)
    def __init__(self):
        f = jsbsim.FGFDMExec(None)
        f.set_debug_level(0)
        f.load_model("c172p")
        f.set_dt(self.dt)
        self.f = f
        self._load_to_mass()
        self.start_alt = 0.0
        self._started = False

    # ---- helpers
    def _load_to_mass(self):
        f = self.f
        target_lb = self.mass_kg * LB_PER_KG
        f["inertia/pointmass-weight-lbs[1]"] = 180.0       # copilot
        f.run_ic()
        extra = target_lb - f["inertia/weight-lbs"]
        f["inertia/pointmass-weight-lbs[2]"] = max(0.0, extra)  # left passenger, near the CG
        f.run_ic()

    def _elev_cmd(self, deg_up):
        # aerosurface_scale with asymmetric range: cmd < 0 scales by 28 deg, cmd > 0 by 23 deg (verified).
        pos = clamp(-deg_up, ELEV_MIN, ELEV_MAX)          # pos > 0 = trailing edge down
        return pos / -ELEV_MIN if pos < 0 else pos / ELEV_MAX

    def _ic_air(self, tas_kt, alt_ft, alpha_deg):
        f = self.f
        f["ic/terrain-elevation-ft"] = 0.0
        f["ic/h-sl-ft"] = alt_ft
        f["ic/vt-kts"] = tas_kt
        f["ic/alpha-deg"] = alpha_deg
        f["ic/beta-deg"] = 0.0
        f["ic/gamma-deg"] = 0.0
        f["ic/phi-deg"] = 0.0
        f["ic/psi-true-deg"] = 0.0
        f["ic/p-rad_sec"] = 0.0
        f["ic/q-rad_sec"] = 0.0
        f["ic/r-rad_sec"] = 0.0
        if not self._started:       # starting the engine again would reset its rpm and spoil the trim
            f["propulsion/set-running"] = -1
            f["fcs/mixture-cmd-norm"] = 1.0
            f["fcs/flap-cmd-norm"] = 0.0
            f["fcs/left-brake-cmd-norm"] = 0.0
            f["fcs/right-brake-cmd-norm"] = 0.0
            f["fcs/center-brake-cmd-norm"] = 0.0
            self._started = True
        f.run_ic()

    def _settle_flaps(self, flaps):
        """Drive the flap kinematic to its target before trimming (flaps travel takes seconds)."""
        f = self.f
        f["fcs/flap-cmd-norm"] = flaps
        if flaps == 0.0:
            return
        f.hold()  # freeze the equations of motion; FCS components still execute on run()
        for _ in range(int(6.0 / self.dt)):
            f.run()
        f.resume()

    # ---- setup
    def trim(self, tas_kt, alt_ft, flaps):
        f = self.f
        self._ic_air(tas_kt, alt_ft, 2.0)
        self._settle_flaps(flaps)
        f["simulation/do_simple_trim"] = 0   # longitudinal trim: alpha/theta, elevator, throttle
        ok = abs(f["accelerations/udot-ft_sec2"]) < 0.5 and abs(f["accelerations/wdot-ft_sec2"]) < 0.5
        # confirm: run 1 s and make sure vertical speed is small
        h0 = f["position/h-sl-ft"]
        for _ in range(int(1.0 / self.dt)):
            f.run()
        drift = abs(f["position/h-sl-ft"] - h0)
        # JSBSim's trim moves the pitch-trim channel; fold it into the stick so later set_controls is absolute.
        self._t0 = f["simulation/sim-time-sec"]
        self.start_alt = f["position/h-sl-ft"]
        self._d0 = f["position/distance-from-start-mag-mt"]
        elev_up = -f["fcs/elevator-pos-deg"]
        f["fcs/pitch-trim-cmd-norm"] = 0.0
        self.set_controls(elev_deg_up=elev_up)
        return dict(alpha_deg=f["aero/alpha-deg"], theta_deg=f["attitude/theta-deg"],
                    elev_deg_up=elev_up, throttle=f["fcs/throttle-cmd-norm"],
                    power_kw=f["propulsion/engine/power-hp"] * 0.7456999, converged=bool(ok and drift < 5.0))

    def init_flight(self, tas_kt, alt_ft, alpha_deg, flaps, elev_deg_up, throttle):
        f = self.f
        self._ic_air(tas_kt, alt_ft, alpha_deg)
        self._settle_flaps(flaps)
        self.set_controls(elev_deg_up=elev_deg_up, throttle=throttle, flaps=flaps, aileron=0.0, rudder=0.0)
        self._t0 = f["simulation/sim-time-sec"]
        self.start_alt = f["position/h-sl-ft"]
        self._d0 = f["position/distance-from-start-mag-mt"]

    def init_ground(self):
        f = self.f
        f["ic/terrain-elevation-ft"] = 0.0
        f["ic/h-agl-ft"] = 3.0
        f["ic/vt-kts"] = 0.0
        f["ic/gamma-deg"] = 0.0
        f["ic/alpha-deg"] = 0.0
        f["ic/theta-deg"] = 0.0
        f["ic/phi-deg"] = 0.0
        f["ic/psi-true-deg"] = 90.0
        f["propulsion/set-running"] = -1
        f["fcs/mixture-cmd-norm"] = 1.0
        f["fcs/throttle-cmd-norm"] = 0.0
        f["fcs/left-brake-cmd-norm"] = 1.0
        f["fcs/right-brake-cmd-norm"] = 1.0
        f["fcs/flap-cmd-norm"] = 0.0
        f.run_ic()
        for _ in range(int(3.0 * 120)):
            f.run()
        f["fcs/left-brake-cmd-norm"] = 0.0
        f["fcs/right-brake-cmd-norm"] = 0.0
        self.start_alt = f["position/h-sl-ft"]
        self._t0 = f["simulation/sim-time-sec"]
        self._d0 = f["position/distance-from-start-mag-mt"]

    # ---- controls
    def set_controls(self, elev_deg_up=None, aileron=None, rudder=None, throttle=None, flaps=None, brakes=None):
        f = self.f
        if elev_deg_up is not None: f["fcs/elevator-cmd-norm"] = self._elev_cmd(elev_deg_up)
        if aileron is not None: f["fcs/aileron-cmd-norm"] = clamp(aileron, -1, 1)
        if rudder is not None:
            f["fcs/rudder-cmd-norm"] = -clamp(rudder, -1, 1)
            f["fcs/steer-cmd-norm"] = clamp(rudder, -1, 1)   # + = steer right (verified)
        if throttle is not None: f["fcs/throttle-cmd-norm"] = clamp(throttle, 0, 1)
        if flaps is not None: f["fcs/flap-cmd-norm"] = clamp(flaps, 0, 1)
        if brakes is not None:
            f["fcs/left-brake-cmd-norm"] = f["fcs/right-brake-cmd-norm"] = clamp(brakes, 0, 1)

    def step(self):
        self.f.run()

    def obs(self):
        f = self.f
        qbar = f["aero/qbar-psf"]
        cl = f["forces/fwz-aero-lbs"] / (qbar * 174.0) if qbar > 1e-3 else 0.0
        return dict(t=f["simulation/sim-time-sec"] - getattr(self, "_t0", 0.0),
                    tas_kt=f["velocities/vtrue-kts"], cas_kt=f["velocities/vc-kts"],
                    alt_ft=f["position/h-sl-ft"], h_gain_ft=f["position/h-sl-ft"] - self.start_alt,
                    vz_fps=f["velocities/h-dot-fps"], alpha_deg=f["aero/alpha-deg"], beta_deg=f["aero/beta-deg"],
                    theta_deg=f["attitude/theta-deg"], phi_deg=f["attitude/phi-deg"],
                    psi_deg=f["attitude/psi-deg"] % 360.0,
                    p_dps=f["velocities/p-rad_sec"] / D2R, q_dps=f["velocities/q-rad_sec"] / D2R,
                    r_dps=f["velocities/r-rad_sec"] / D2R, cl=cl,
                    wow_main=bool(f["gear/unit[1]/WOW"] or f["gear/unit[2]/WOW"]),
                    dist_ft=(f["position/distance-from-start-mag-mt"] - getattr(self, "_d0", 0.0)) / FT,
                    ail_deg=f["fcs/left-aileron-pos-deg"], elev_deg_up=-f["fcs/elevator-pos-deg"])


def clamp(x, lo, hi): return max(lo, min(hi, x))


def selfcheck():
    """Verify control sign conventions and CL definition against the live c172p model."""
    p = JSBSimPlant()
    tr = p.trim(100.0, 3000.0, 0.0)
    print(f"trim: {tr}")
    o = p.obs()
    print(f"  CL at trim = {o['cl']:.3f} (expect ~0.4)   weight = {p.f['inertia/weight-lbs']/LB_PER_KG:.1f} kg   "
          f"CG x = {p.f['inertia/cg-x-in']:.1f} in")
    checks = []
    for name, kw, key, sign in (("stick back -> q>0", dict(elev_deg_up=tr["elev_deg_up"] + 5), "q_dps", 1),
                                ("stick right -> p>0", dict(aileron=0.5), "p_dps", 1),
                                ("right pedal -> r>0", dict(rudder=0.5), "r_dps", 1)):
        p = JSBSimPlant()
        tr = p.trim(100.0, 3000.0, 0.0)
        if "elev_deg_up" in kw:
            kw = dict(elev_deg_up=tr["elev_deg_up"] + 5)
        p.set_controls(**kw)
        for _ in range(120):
            p.step()
        v = p.obs()[key]
        ok = v * sign > 0
        checks.append(ok)
        print(f"  {name}: {key} = {v:.2f}  {'OK' if ok else 'WRONG SIGN'}")
    return all(checks)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--out", default="jsbsim_results.json")
    ap.add_argument("--only", default="", help="comma-separated scenario names")
    ap.add_argument("--series", action="store_true", help="also write raw time series (Swift emitter format)")
    ap.add_argument("--selfcheck", action="store_true", help="verify control signs and exit")
    a = ap.parse_args()
    if a.selfcheck:
        raise SystemExit(0 if selfcheck() else 1)
    only = [x for x in a.only.split(",") if x]
    sc.EMIT_SERIES = a.series
    t0 = time.time()
    print(f"JSBSim {jsbsim.__version__} c172p scenarios")
    res = sc.run_all(JSBSimPlant, only)
    doc = dict(meta=dict(source="jsbsim", jsbsim_version=jsbsim.__version__, model="c172p", mass_kg=sc.MASS_KG,
                         scenario_defs=sc.SCENARIOS, runtime_s=round(time.time() - t0, 1)),
               scenarios=res)
    with open(a.out, "w") as f:
        json.dump(doc, f, indent=2)
    print(f"wrote {a.out} in {time.time()-t0:.1f}s")


if __name__ == "__main__":
    main()
