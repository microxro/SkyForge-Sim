"""Shared scenario definitions, control laws and metric extraction for the JSBSim oracle.

Both sides (JSBSim c172p adapter in run_jsbsim.py, SF-1 mirror adapter in run_sf1.py, and the Swift
emitter described in SWIFT_EMITTER.md) drive a *Plant* through the exact same procedures and metric
extraction defined here, so any difference in the numbers is a difference in the aircraft model.

Plant interface (duck typed; all angles deg, speeds kt, altitude ft unless stated):

    name, mass_kg, dt (s), elev_up_max_deg, elev_dn_max_deg, ail_max_deg, rud_max_deg
    trim(tas_kt, alt_ft, flaps)  -> dict(alpha_deg, theta_deg, elev_deg_up, throttle, power_kw,
                                         converged)   # also leaves the plant flying the trim
    init_flight(tas_kt, alt_ft, alpha_deg, flaps, elev_deg_up, throttle)  # level, wings level
    init_ground()               # on the runway, sea level, engine running, brakes released, t = 0
    set_controls(elev_deg_up=, aileron=, rudder=, throttle=, flaps=, brakes=)   # None = unchanged
                                # aileron/rudder are stick fractions, +1 = right roll / right yaw
    step()                      # advance dt
    obs() -> dict(t, tas_kt, cas_kt, alt_ft, h_gain_ft, vz_fps, alpha_deg, beta_deg, theta_deg,
                  phi_deg, psi_deg, p_dps, q_dps, r_dps, cl, wow_main, dist_ft, ail_deg, elev_deg_up)

Sign conventions: elev_deg_up positive = trailing edge up = nose-up moment; stick right/pedal right = +.
"""
from __future__ import annotations

import math

import numpy as np

KT = 0.514444  # m/s per knot
FT = 0.3048

# ---------------------------------------------------------------------------- scenario definitions
EMIT_SERIES = False       # run_*.py --series: also write the raw series the Swift emitter ships
MASS_KG = 1000.0          # both aircraft are loaded to this mass for comparison
TRIM_TAS_KT = 100.0
TRIM_ALT_FT = 3000.0

SCENARIOS = {
    "trim": dict(tas_kt=TRIM_TAS_KT, alt_ft=TRIM_ALT_FT, flaps=0.0),
    "stall_clean": dict(start_tas_kt=80.0, alt_ft=TRIM_ALT_FT, flaps=0.0, pitch_ramp_dps=1.0, ramp_start_s=3.0, max_s=150.0),
    "stall_flaps": dict(start_tas_kt=65.0, alt_ft=TRIM_ALT_FT, flaps=1.0, pitch_ramp_dps=1.0, ramp_start_s=3.0, max_s=150.0),
    "short_period": dict(amp_deg=2.5, half_pulse_s=0.5, pre_s=2.0, post_s=8.0, fit_s=6.0),
    "aileron_step": dict(stick=0.5, pre_s=2.0, post_s=5.0),
    "phugoid": dict(dv_kt=8.0, duration_s=150.0),
    "rudder_step": dict(stick=0.5, pre_s=3.0, post_s=12.0),
    "takeoff": dict(vr_kcas=55.0, pitch_deg=9.0, gain_ft=55.0, max_s=90.0, throttle=1.0),
}

# ---------------------------------------------------------------------------- numerics helpers
def clampf(x, lo, hi): return max(lo, min(hi, x))


def fit_damped(t, y, w_range, s_range, drift=0):
    """Fit y(t) ~ exp(-s t)(a cos wt + b sin wt) + poly_drift(t); returns dict(freq_rad_s, sigma, zeta,
    wn, period_s, rms). Grid search over (w, s) with linear least squares for the rest, refined twice."""
    t = np.asarray(t, float) - t[0]
    y = np.asarray(y, float)

    def solve(w, s):
        e = np.exp(-s * t)
        cols = [e * np.cos(w * t), e * np.sin(w * t)] + [t ** k for k in range(drift + 1)]
        A = np.stack(cols, axis=1)
        coef, *_ = np.linalg.lstsq(A, y, rcond=None)
        r = y - A @ coef
        return float(np.sqrt(np.mean(r * r))), coef

    w0, w1 = w_range
    s0, s1 = s_range
    best = (1e99, None, None)
    for _ in range(3):
        for w in np.linspace(w0, w1, 41):
            for s in np.linspace(s0, s1, 41):
                rms, _c = solve(w, s)
                if rms < best[0]:
                    best = (rms, w, s)
        dw, ds = (w1 - w0) / 20, (s1 - s0) / 20
        w0, w1 = max(1e-3, best[1] - dw), best[1] + dw
        s0, s1 = best[2] - ds, best[2] + ds
    rms, w, s = best
    wn = math.hypot(w, s)
    return dict(freq_rad_s=w, sigma=s, wn=wn, zeta=s / wn, period_s=2 * math.pi / w, rms=rms)


def mean_between(ts, ys, t0, t1):
    sel = [y for t, y in zip(ts, ys) if t0 <= t <= t1]
    return float(np.mean(sel)) if sel else float("nan")


def history(plant, seconds, controller=None, keys=None):
    """Run the plant for `seconds`; controller(obs, t_rel) is called each step before stepping."""
    n = int(round(seconds / plant.dt))
    rec = []
    for k in range(n):
        o = plant.obs()
        if controller is not None:
            controller(o, k * plant.dt)
        rec.append(o)
        plant.step()
    rec.append(plant.obs())
    return rec


def col(rec, key): return [r[key] for r in rec]

# ---------------------------------------------------------------------------- control laws
class PitchHold:
    """Inner pitch-attitude loop (deg stick-free-of-plant): elev_up = e0 + Kth (theta_cmd - theta) - Kq q."""
    KTH, KQ = 1.0, 0.4

    def __init__(self, plant, e0):
        self.plant, self.e0 = plant, e0

    def __call__(self, o, theta_cmd):
        e = self.e0 + self.KTH * (theta_cmd - o["theta_deg"]) - self.KQ * o["q_dps"]
        e = clampf(e, -self.plant.elev_dn_max_deg, self.plant.elev_up_max_deg)
        self.plant.set_controls(elev_deg_up=e)


class WingsLevel:
    """Aileron loop holding phi = 0: ail_deg(roll right) = -(Kphi phi + Kp p)."""
    KPHI, KP = 0.8, 0.35

    def __init__(self, plant): self.plant = plant

    def __call__(self, o):
        d = -(self.KPHI * o["phi_deg"] + self.KP * o["p_dps"])
        self.plant.set_controls(aileron=clampf(d / self.plant.ail_max_deg, -1, 1))

# ---------------------------------------------------------------------------- scenario procedures
def run_trim(plant, cfg=SCENARIOS["trim"]):
    tr = plant.trim(cfg["tas_kt"], cfg["alt_ft"], cfg["flaps"])
    o = plant.obs()
    return dict(converged=bool(tr["converged"]), alpha_deg=tr["alpha_deg"], elevator_deg_up=tr["elev_deg_up"],
                throttle=tr["throttle"], power_kw=tr["power_kw"], climb_fpm=o["vz_fps"] * 60.0,
                cas_kt=o["cas_kt"], cl=o["cl"])


def _run_stall(plant, cfg):
    """Power-off 1g-ish deceleration: pitch attitude is ramped up slowly (pitch_ramp_dps) through an inner
    pitch-hold loop that saturates at full aft stick, wings held level, until CL has peaked and rolled off."""
    tr = plant.trim(cfg["start_tas_kt"], cfg["alt_ft"], cfg["flaps"])
    pitch = PitchHold(plant, tr["elev_deg_up"])
    theta_trim = tr["theta_deg"]
    plant.set_controls(throttle=0.0)
    wl = WingsLevel(plant)
    dt = plant.dt
    rec = []
    for k in range(int(cfg["max_s"] / dt)):
        o = plant.obs()
        theta_cmd = theta_trim + cfg["pitch_ramp_dps"] * max(0.0, o["t"] - cfg["ramp_start_s"])
        pitch(o, min(theta_cmd, 40.0))
        wl(o)
        rec.append(o)
        plant.step()
        if len(rec) > 100:
            cls = col(rec, "cl")
            pk = int(np.argmax(cls))
            if o["t"] - rec[pk]["t"] > (1.0 if cls[-1] < 0.9 * cls[pk] else 6.0):
                break
            if o["cas_kt"] < 15:
                break
    t, cl = col(rec, "t"), col(rec, "cl")
    pk = int(np.argmax(cl))
    th = col(rec, "theta_deg")
    th_pk = max(th[: pk + 1])
    # post-stall lift retention: CL 4 s after the peak relative to the peak (low = abrupt break)
    after = next((r["cl"] for r in rec if r["t"] >= rec[pk]["t"] + 4.0), rec[-1]["cl"])
    t5 = next((i for i, r in enumerate(rec) if r["t"] >= 5.0), 0)
    span = rec[pk]["t"] - rec[t5]["t"]
    decel = (rec[t5]["cas_kt"] - rec[pk]["cas_kt"]) / span if span > 1 else float("nan")
    return dict(
        cl_max=cl[pk], v_clmax_kcas=rec[pk]["cas_kt"], v_clmax_ktas=rec[pk]["tas_kt"],
        alpha_clmax_deg=rec[pk]["alpha_deg"], decel_kt_per_s=decel,
        cl_ratio_4s_after_peak=after / cl[pk],
        alpha_max_deg=max(col(rec, "alpha_deg")), t_peak_s=rec[pk]["t"],
        theta_peak_deg=th_pk, vz_at_peak_fpm=rec[pk]["vz_fps"] * 60.0)


def run_stall_clean(plant): return _run_stall(plant, SCENARIOS["stall_clean"])
def run_stall_flaps(plant): return _run_stall(plant, SCENARIOS["stall_flaps"])


def run_short_period(plant, cfg=SCENARIOS["short_period"]):
    tr = plant.trim(TRIM_TAS_KT, TRIM_ALT_FT, 0.0)
    e0 = tr["elev_deg_up"]
    dt = plant.dt

    wl = WingsLevel(plant)

    def ctl(o, t):
        wl(o)
        a = cfg["amp_deg"]; h = cfg["half_pulse_s"]; t0 = cfg["pre_s"]
        if t0 <= t < t0 + h: e = e0 + a
        elif t0 + h <= t < t0 + 2 * h: e = e0 - a
        else: e = e0
        plant.set_controls(elev_deg_up=e)
    rec = history(plant, cfg["pre_s"] + 2 * cfg["half_pulse_s"] + cfg["post_s"], ctl)
    res = short_period_metrics(rec, cfg)
    if EMIT_SERIES:
        res["series"] = dict(t=[round(r["t"], 6) for r in rec], q_dps=[r["q_dps"] for r in rec])
    return res


def short_period_metrics(rec, cfg=SCENARIOS["short_period"]):
    """rec: list of dicts with at least t and q_dps (the Swift emitter ships this as `series`)."""
    t0 = cfg["pre_s"] + 2 * cfg["half_pulse_s"]
    sel = [r for r in rec if t0 <= r["t"] <= t0 + cfg["fit_s"]]
    fit = fit_damped([r["t"] for r in sel], [r["q_dps"] for r in sel], (1.0, 9.0), (0.3, 8.0), drift=1)
    q_pk = max(abs(r["q_dps"]) for r in rec if r["t"] >= cfg["pre_s"])
    return dict(wn_rad_s=fit["wn"], zeta=fit["zeta"], wd_rad_s=fit["freq_rad_s"], sigma=fit["sigma"],
                fit_rms_dps=fit["rms"], q_peak_dps=q_pk, q_peak_per_deg=q_pk / cfg["amp_deg"])


def run_aileron_step(plant, cfg=SCENARIOS["aileron_step"]):
    tr = plant.trim(TRIM_TAS_KT, TRIM_ALT_FT, 0.0)
    e0 = tr["elev_deg_up"]
    ail0 = plant.obs()["ail_deg"]

    def ctl(o, t):
        plant.set_controls(elev_deg_up=e0, aileron=cfg["stick"] if t >= cfg["pre_s"] else 0.0)
    rec = history(plant, cfg["pre_s"] + cfg["post_s"], ctl)
    t0 = cfg["pre_s"]
    ts, ps = col(rec, "t"), col(rec, "p_dps")
    base = mean_between(ts, ps, 0.5, t0 - 0.1)
    pss = mean_between(ts, ps, t0 + 1.5, t0 + 3.5) - base
    ail = rec[-1]["ail_deg"] - ail0
    tau = next((r["t"] - t0 for r in rec if r["t"] > t0 and (r["p_dps"] - base) >= 0.632 * pss), float("nan"))
    return dict(p_ss_dps=pss, tau_roll_s=tau, ail_defl_deg=ail,
                p_per_deg_ail=pss / ail if abs(ail) > 1e-6 else float("nan"),
                phi_end_deg=rec[-1]["phi_deg"])


def run_phugoid(plant, cfg=SCENARIOS["phugoid"]):
    tr = plant.trim(TRIM_TAS_KT, TRIM_ALT_FT, 0.0)
    plant.init_flight(TRIM_TAS_KT + cfg["dv_kt"], TRIM_ALT_FT, tr["alpha_deg"], 0.0,
                      tr["elev_deg_up"], tr["throttle"])
    wl = WingsLevel(plant)   # the c172p spiral mode diverges within ~30 s; hold wings level on both sides
    rec = history(plant, cfg["duration_s"], lambda o, _t: wl(o))
    res = phugoid_metrics(rec, plant.dt)
    if EMIT_SERIES:
        sel = rec[:: max(1, int(round(0.25 / plant.dt)))]
        res["series"] = dict(t=[round(r["t"], 6) for r in sel], tas_kt=[r["tas_kt"] for r in sel],
                             alt_ft=[r["alt_ft"] for r in sel])
    return res


def phugoid_metrics(rec, dt, cfg=SCENARIOS["phugoid"]):
    """rec: dicts with t, tas_kt, alt_ft, sampled every dt seconds (Swift ships a 0.25 s series)."""
    sel = rec[:: max(1, int(round(0.25 / dt)))]
    fit = fit_damped([r["t"] for r in sel], [r["tas_kt"] for r in sel], (0.1, 0.7), (0.0, 0.2), drift=1)
    return dict(period_s=fit["period_s"], zeta=fit["zeta"], wn_rad_s=fit["wn"], sigma=fit["sigma"],
                fit_rms_kt=fit["rms"], alt_excursion_ft=max(col(sel, "alt_ft")) - min(col(sel, "alt_ft")))


def run_rudder_step(plant, cfg=SCENARIOS["rudder_step"]):
    tr = plant.trim(TRIM_TAS_KT, TRIM_ALT_FT, 0.0)
    e0 = tr["elev_deg_up"]
    wl = WingsLevel(plant)

    def ctl(o, t):
        plant.set_controls(elev_deg_up=e0, rudder=cfg["stick"] if t >= cfg["pre_s"] else 0.0)
        wl(o)
    rec = history(plant, cfg["pre_s"] + cfg["post_s"], ctl)
    t_end = cfg["pre_s"] + cfg["post_s"]
    ts, bs, rs = col(rec, "t"), col(rec, "beta_deg"), col(rec, "r_dps")
    beta_ss = mean_between(ts, bs, t_end - 2.0, t_end)
    peak = max((b for t, b in zip(ts, bs) if t >= cfg["pre_s"]), key=abs)
    rud = cfg["stick"] * plant.rud_max_deg
    return dict(beta_ss_deg=beta_ss, beta_peak_deg=peak, beta_ss_per_deg_rudder=beta_ss / rud,
                r_ss_dps=mean_between(ts, rs, t_end - 2.0, t_end),
                phi_max_abs_deg=max(abs(p) for p in col(rec, "phi_deg")), rudder_defl_deg=rud)


def run_takeoff(plant, cfg=SCENARIOS["takeoff"]):
    plant.init_ground()
    o0 = plant.obs()
    psi0 = o0["psi_deg"]
    pitch = PitchHold(plant, 0.0)
    wl = WingsLevel(plant)
    plant.set_controls(throttle=cfg["throttle"], brakes=0.0, flaps=0.0)
    state = dict(rotating=False)
    rec = []
    dt = plant.dt
    lift_i = None
    done = None
    for k in range(int(cfg["max_s"] / dt)):
        o = plant.obs()
        dpsi = (o["psi_deg"] - psi0 + 180) % 360 - 180
        rud = clampf(-(0.03 * dpsi + 0.06 * o["r_dps"]), -1, 1)
        plant.set_controls(rudder=rud)
        if o["cas_kt"] >= cfg["vr_kcas"]:
            state["rotating"] = True
        if state["rotating"]:
            pitch(o, cfg["pitch_deg"])
        else:
            plant.set_controls(elev_deg_up=0.0)
        if o["wow_main"] is False:
            wl(o)
        rec.append(o)
        if lift_i is None and not o["wow_main"] and state["rotating"]:
            lift_i = len(rec) - 1
        if o["h_gain_ft"] >= cfg["gain_ft"] and lift_i is not None:
            done = len(rec) - 1
            break
        plant.step()
    if done is None or lift_i is None:
        return dict(completed=False, t_end_s=rec[-1]["t"], dist_end_ft=rec[-1]["dist_ft"],
                    cas_end_kt=rec[-1]["cas_kt"], h_gain_end_ft=rec[-1]["h_gain_ft"])
    return dict(completed=True,
                ground_roll_ft=rec[lift_i]["dist_ft"], liftoff_kcas=rec[lift_i]["cas_kt"], t_liftoff_s=rec[lift_i]["t"],
                dist_to_55ft_ft=rec[done]["dist_ft"], t_to_55ft_s=rec[done]["t"], cas_at_55ft_kt=rec[done]["cas_kt"],
                heading_dev_max_deg=max(abs((r["psi_deg"] - psi0 + 180) % 360 - 180) for r in rec))


RUNNERS = {
    "trim": run_trim,
    "stall_clean": run_stall_clean,
    "stall_flaps": run_stall_flaps,
    "short_period": run_short_period,
    "aileron_step": run_aileron_step,
    "phugoid": run_phugoid,
    "rudder_step": run_rudder_step,
    "takeoff": run_takeoff,
}


def _clean(v):
    """numpy scalars -> plain Python so json.dump and the Swift emitter schema stay identical."""
    if isinstance(v, dict): return {k: _clean(x) for k, x in v.items()}
    if isinstance(v, (np.bool_, bool)): return bool(v)
    if isinstance(v, (np.floating, float)): return float(v)
    if isinstance(v, (np.integer, int)): return int(v)
    return v


def run_all(make_plant, only=None, log=print):
    """make_plant() -> fresh Plant. Each scenario gets a fresh plant. Returns {scenario: metrics}."""
    out = {}
    for name, fn in RUNNERS.items():
        if only and name not in only:
            continue
        p = make_plant()
        try:
            out[name] = _clean(fn(p))
            log(f"  {name}: ok")
        except Exception as e:  # keep going; the comparison marks the scenario as errored
            out[name] = {"error": f"{type(e).__name__}: {e}"}
            log(f"  {name}: ERROR {e}")
    return out
