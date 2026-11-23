#!/usr/bin/env python3
"""Run the shared scenarios on the Python mirror of the SF-1 Swift flight model.

    python3 run_sf1.py [-o sf1_results.json] [--only trim,stall_clean]

Output JSON schema is documented in SWIFT_EMITTER.md (same schema as run_jsbsim.py and the Swift test).
"""
from __future__ import annotations

import argparse
import json
import math
import time

import scenarios as sc
import sf1_mirror as m

D2R = m.DEG


class SF1Plant:
    name = "SF-1 (python mirror)"
    dt = 1.0 / 120.0
    mass_kg = m.SF1.mass
    elev_up_max_deg = m.SF1.elevator_max / D2R
    elev_dn_max_deg = m.SF1.elevator_max / D2R
    ail_max_deg = m.SF1.aileron_max / D2R
    rud_max_deg = m.SF1.rudder_max / D2R

    def __init__(self):
        self.fm = m.FlightModel()
        self.env = m.Env()
        self.inp = m.Inputs()
        self.s = None
        self.start_alt = 0.0
        self.start_pos = (0.0, 0.0)

    # ---- setup
    def trim(self, tas_kt, alt_ft, flaps):
        r = self.fm.trim_level(tas_kt * sc.KT, alt_ft * sc.FT, flaps, self.env)
        self.s, self.inp = r["state"], r["inputs"]
        self.start_alt = self.s.altitude
        self.start_pos = (self.s.pos[0], self.s.pos[1])
        sigma = m.isa_state(self.s.altitude).density / m.ISA_RHO0
        return dict(alpha_deg=r["alpha"] / D2R, theta_deg=r["alpha"] / D2R,
                    elev_deg_up=self.inp.elevator * self.elev_up_max_deg, throttle=self.inp.throttle,
                    power_kw=m.SF1.max_power * self.inp.throttle * sigma ** 1.1 / 1000.0,
                    converged=r["converged"])

    def init_flight(self, tas_kt, alt_ft, alpha_deg, flaps, elev_deg_up, throttle):
        a, v = alpha_deg * D2R, tas_kt * sc.KT
        self.s = m.State((0.0, 0.0, -alt_ft * sc.FT), (v * math.cos(a), 0.0, v * math.sin(a)),
                         m.Quat.from_euler(0.0, a, 0.0), (0.0, 0.0, 0.0))
        self.inp = m.Inputs(elevator=elev_deg_up / self.elev_up_max_deg, throttle=throttle, flaps=flaps)
        self.start_alt = self.s.altitude
        self.start_pos = (0.0, 0.0)

    def init_ground(self):
        # Settle on the gear with brakes on, then release (a parked aircraft at sea level).
        self.s = m.State((0.0, 0.0, -1.20), (0.0, 0.0, 0.0), m.Quat.from_euler(0.0, 0.0, 0.0), (0.0, 0.0, 0.0))
        self.inp = m.Inputs(brakes=1.0)
        for _ in range(int(3.0 * 120)):
            self.s = self.fm.step(self.s, self.inp, self.env, self.dt)
        self.s = m.State(self.s.pos, (0.0, 0.0, 0.0), self.s.att, (0.0, 0.0, 0.0), 0.0)
        self.inp = m.Inputs()
        self.start_alt = self.s.altitude
        self.start_pos = (self.s.pos[0], self.s.pos[1])

    # ---- controls
    def set_controls(self, elev_deg_up=None, aileron=None, rudder=None, throttle=None, flaps=None, brakes=None):
        i = self.inp
        if elev_deg_up is not None: i.elevator = sc.clampf(elev_deg_up / self.elev_up_max_deg, -1, 1)
        if aileron is not None: i.aileron = sc.clampf(aileron, -1, 1)
        if rudder is not None: i.rudder = sc.clampf(rudder, -1, 1)
        if throttle is not None: i.throttle = sc.clampf(throttle, 0, 1)
        if flaps is not None: i.flaps = sc.clampf(flaps, 0, 1)
        if brakes is not None: i.brakes = sc.clampf(brakes, 0, 1)

    def step(self):
        self.s = self.fm.step(self.s, self.inp, self.env, self.dt)

    def _main_wow(self):
        for leg in self.fm.config.gear:
            if not leg.braked:
                continue
            p = m.vadd(self.s.pos, self.s.att.rotate(leg.position))
            if p[2] - (-self.env.elevation(p[0], p[1])) > 0:
                return True
        return False

    def obs(self):
        s = self.s
        out = self.fm.outputs(s, self.inp, self.env)
        roll, pitch, yaw = s.att.euler()
        vned = s.att.rotate(s.vel)
        p, q, r = s.rates
        return dict(t=s.time, tas_kt=out.true_airspeed / sc.KT, cas_kt=out.calibrated_airspeed / sc.KT,
                    alt_ft=s.altitude / sc.FT, h_gain_ft=(s.altitude - self.start_alt) / sc.FT,
                    vz_fps=-vned[2] / sc.FT, alpha_deg=out.alpha / D2R, beta_deg=out.beta / D2R,
                    theta_deg=pitch / D2R, phi_deg=roll / D2R, psi_deg=(yaw / D2R) % 360.0,
                    p_dps=p / D2R, q_dps=q / D2R, r_dps=r / D2R, cl=out.lift_coefficient,
                    wow_main=self._main_wow(),
                    dist_ft=math.hypot(s.pos[0] - self.start_pos[0], s.pos[1] - self.start_pos[1]) / sc.FT,
                    ail_deg=self.inp.aileron * self.ail_max_deg,
                    elev_deg_up=self.inp.elevator * self.elev_up_max_deg)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--out", default="sf1_results.json")
    ap.add_argument("--only", default="", help="comma-separated scenario names")
    ap.add_argument("--series", action="store_true", help="also write raw time series (Swift emitter format)")
    a = ap.parse_args()
    only = [x for x in a.only.split(",") if x]
    sc.EMIT_SERIES = a.series
    t0 = time.time()
    print("SF-1 mirror scenarios")
    res = sc.run_all(SF1Plant, only)
    doc = dict(meta=dict(source="sf1_mirror.py", model="SF-1 Trainer", mass_kg=m.SF1.mass,
                         scenario_defs=sc.SCENARIOS, runtime_s=round(time.time() - t0, 1)),
               scenarios=res)
    with open(a.out, "w") as f:
        json.dump(doc, f, indent=2)
    print(f"wrote {a.out} in {time.time()-t0:.1f}s")


if __name__ == "__main__":
    main()
