"""SF-1 Trainer flight model: a LINE-BY-LINE PYTHON MIRROR of the Swift implementation.

    *** THIS FILE IS A MIRROR. IT MUST MATCH THE SWIFT SOURCE. ***

Ported from (read them side by side when either changes):
    Packages/SkyforgeKit/Sources/SFFlightModel/AircraftConfig.swift   (coefficients, geometry)
    Packages/SkyforgeKit/Sources/SFFlightModel/FlightDynamics.swift   (forcesAndMoments, gearForces,
                                                                       rk4, step, trimLevel)
    Packages/SkyforgeKit/Sources/SFMath/Quaternion.swift              (Quaternion)
    Packages/SkyforgeKit/Sources/SFAtmosphere/ISA.swift               (ISA, Airspeed)

Why a mirror: this sandbox has no Swift toolchain, so the oracle comparison runs on this port today.
The authoritative path is the Swift test in OracleExportTests.swift.txt (see SWIFT_EMITTER.md), which
runs the real FlightModel through the identical scenarios (scenarios.py) and writes the same JSON that
run_sf1.py writes. Once that exists, diff the two JSON files: any difference is a mirror bug.

MIRRORED VERSION: FlightDynamics.swift (389 lines) and AircraftConfig.swift (101 lines) as in git HEAD when this was
written. Later working-tree changes (Mach schedule, engine model, stall behaviour, speed brakes, surface friction)
are NOT mirrored yet; re-port them (and run check_mirror.py against the Swift emitter) before trusting RESULTS.md.

Pure Python, no third-party dependencies. Vectors are 3-tuples.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

# --------------------------------------------------------------------------- vector helpers
def vadd(a, b): return (a[0] + b[0], a[1] + b[1], a[2] + b[2])
def vsub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def vmul(a, s): return (a[0] * s, a[1] * s, a[2] * s)
def vdot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def vcross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def vlen(a): return math.sqrt(vdot(a, a))
def vnorm(a):
    n = vlen(a)
    return (a[0] / n, a[1] / n, a[2] / n) if n > 0 else (0.0, 0.0, 0.0)
def clamp(x, lo, hi): return min(hi, max(lo, x))

DEG = math.pi / 180.0

# --------------------------------------------------------------------------- Quaternion (SFMath)
@dataclass
class Quat:
    w: float
    v: tuple

    @staticmethod
    def from_euler(roll, pitch, yaw):
        cr, sr = math.cos(roll / 2), math.sin(roll / 2)
        cp, sp = math.cos(pitch / 2), math.sin(pitch / 2)
        cy, sy = math.cos(yaw / 2), math.sin(yaw / 2)
        return Quat(cr * cp * cy + sr * sp * sy,
                    (sr * cp * cy - cr * sp * sy,
                     cr * sp * cy + sr * cp * sy,
                     cr * cp * sy - sr * sp * cy))

    def euler(self):
        w, (x, y, z) = self.w, self.v
        roll = math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
        s = max(-1.0, min(1.0, 2 * (w * y - z * x)))
        pitch = math.asin(s)
        yaw = math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        return roll, pitch, yaw

    def mul(self, b: "Quat"):
        return Quat(self.w * b.w - vdot(self.v, b.v),
                    vadd(vadd(vmul(b.v, self.w), vmul(self.v, b.w)), vcross(self.v, b.v)))

    def conjugate(self): return Quat(self.w, vmul(self.v, -1.0))
    def norm(self): return math.sqrt(self.w * self.w + vdot(self.v, self.v))

    def normalized(self):
        n = self.norm()
        return Quat(self.w / n, vmul(self.v, 1.0 / n)) if n > 0 else Quat(1.0, (0.0, 0.0, 0.0))

    def rotate(self, p):
        t = vmul(vcross(self.v, p), 2.0)
        return vadd(vadd(p, vmul(t, self.w)), vcross(self.v, t))

    def derivative(self, omega):
        r = self.mul(Quat(0.0, omega))
        return Quat(0.5 * r.w, vmul(r.v, 0.5))

# --------------------------------------------------------------------------- ISA (SFAtmosphere)
ISA_R = 287.05287
ISA_GAMMA = 1.4
ISA_G0 = 9.80665
ISA_EARTH_R = 6_356_766.0
ISA_T0 = 288.15
ISA_P0 = 101_325.0
ISA_RHO0 = 1.225
_LAYERS = [(0.0, -0.0065), (11_000.0, 0.0), (20_000.0, 0.001), (32_000.0, 0.0028),
           (47_000.0, 0.0), (51_000.0, -0.0028), (71_000.0, -0.002), (84_852.0, 0.0)]


def _isa_bases():
    out = []
    t, p = ISA_T0, ISA_P0
    for i in range(len(_LAYERS)):
        out.append((t, p))
        if i + 1 >= len(_LAYERS):
            break
        dh = _LAYERS[i + 1][0] - _LAYERS[i][0]
        lapse = _LAYERS[i][1]
        t_next = t + lapse * dh
        if lapse == 0:
            p *= math.exp(-ISA_G0 * dh / (ISA_R * t))
        else:
            p *= (t_next / t) ** (-ISA_G0 / (lapse * ISA_R))
        t = t_next
    return out


_BASES = _isa_bases()


@dataclass
class Atmos:
    temperature: float
    pressure: float
    density: float
    speed_of_sound: float


def isa_state(geometric_altitude, temperature_offset=0.0) -> Atmos:
    h = clamp(ISA_EARTH_R * geometric_altitude / (ISA_EARTH_R + geometric_altitude), -5_000.0, 84_852.0)
    i = len(_LAYERS) - 1
    while i > 0 and h < _LAYERS[i][0]:
        i -= 1
    bt, bp = _BASES[i]
    lapse = _LAYERS[i][1]
    dh = h - _LAYERS[i][0]
    t_std = bt + lapse * dh
    p = bp * math.exp(-ISA_G0 * dh / (ISA_R * bt)) if lapse == 0 else bp * (t_std / bt) ** (-ISA_G0 / (lapse * ISA_R))
    t = t_std + temperature_offset
    return Atmos(t, p, p / (ISA_R * t), math.sqrt(ISA_GAMMA * ISA_R * t))


_A0 = math.sqrt(ISA_GAMMA * ISA_R * ISA_T0)


def calibrated_airspeed(tas, atm: Atmos):
    mach = tas / atm.speed_of_sound
    qc = atm.pressure * ((1 + 0.2 * mach * mach) ** 3.5 - 1)
    return _A0 * math.sqrt(5 * ((qc / ISA_P0 + 1) ** (2.0 / 7.0) - 1))

# --------------------------------------------------------------------------- AircraftConfig
@dataclass
class Aero:
    cL0: float = 0.31
    cLAlpha: float = 5.14
    cLQ: float = 3.9
    cLElevator: float = 0.43
    cLFlap: float = 0.55
    cLMaxClean: float = 1.55
    cLMaxFlaps: float = 2.05
    cD0: float = 0.031
    cDFlap: float = 0.045
    cDGear: float = 0.0
    oswald: float = 0.75
    cYBeta: float = -0.31
    cYRudder: float = 0.187
    cm0: float = 0.02
    cmAlpha: float = -0.89
    cmQ: float = -12.4
    cmAlphaDot: float = -5.2   # NOTE: declared in Swift but never used by forcesAndMoments
    cmElevator: float = -1.28
    cmFlap: float = -0.05
    clBeta: float = -0.089
    clP: float = -0.47
    clR: float = 0.096
    clAileron: float = 0.178
    clRudder: float = 0.0147
    cnBeta: float = 0.065
    cnP: float = -0.03
    cnR: float = -0.099
    cnAileron: float = -0.053
    cnRudder: float = -0.0657


@dataclass
class GearLeg:
    position: tuple
    stiffness: float
    damping: float
    steerable: bool
    braked: bool


@dataclass
class Config:
    id: str = "org.skyforge.sf1"
    name: str = "SF-1 Trainer"
    mass: float = 1_000.0
    inertia: tuple = (1_285.0, 1_825.0, 2_667.0)
    ixz: float = 0.0   # declared in Swift, unused by the dynamics
    wing_area: float = 16.2
    wing_span: float = 11.0
    chord: float = 1.49
    aero: Aero = field(default_factory=Aero)
    max_power: float = 120_000.0
    prop_diameter: float = 1.9
    max_rpm: float = 2_700.0
    static_thrust_per_watt: float = 0.020
    stall_alpha: float = 16 * DEG
    elevator_max: float = 25 * DEG
    aileron_max: float = 18 * DEG
    rudder_max: float = 20 * DEG
    flap_max: float = 30 * DEG
    gear: list = field(default_factory=lambda: [
        GearLeg((1.30, 0.0, 1.25), 45_000.0, 4_500.0, True, False),
        GearLeg((-0.30, -1.10, 1.25), 70_000.0, 6_000.0, False, True),
        GearLeg((-0.30, 1.10, 1.25), 70_000.0, 6_000.0, False, True),
    ])

    @property
    def aspect_ratio(self): return self.wing_span * self.wing_span / self.wing_area


SF1 = Config()

# --------------------------------------------------------------------------- state / env / inputs
@dataclass
class Inputs:
    elevator: float = 0.0
    aileron: float = 0.0
    rudder: float = 0.0
    throttle: float = 0.0
    flaps: float = 0.0
    brakes: float = 0.0
    elevator_trim: float = 0.0

    def sanitized(self):
        def c(x, lo, hi): return min(hi, max(lo, x)) if math.isfinite(x) else 0.0
        return Inputs(c(self.elevator, -1, 1), c(self.aileron, -1, 1), c(self.rudder, -1, 1),
                      c(self.throttle, 0, 1), c(self.flaps, 0, 1), c(self.brakes, 0, 1),
                      c(self.elevator_trim, -1, 1))


@dataclass
class Env:
    wind_ned: tuple = (0.0, 0.0, 0.0)
    temperature_offset: float = 0.0
    origin_height: float = 0.0
    terrain_height: float = 0.0   # FlatTerrain(height)

    def elevation(self, north, east): return self.terrain_height


@dataclass
class State:
    pos: tuple            # NED, m
    vel: tuple            # body u, v, w m/s
    att: Quat             # body -> NED
    rates: tuple          # p, q, r rad/s
    time: float = 0.0

    @property
    def altitude(self): return -self.pos[2]

    def is_finite(self):
        vals = list(self.pos) + list(self.vel) + [self.att.w] + list(self.att.v) + list(self.rates)
        return all(math.isfinite(x) for x in vals)


@dataclass
class Outputs:
    true_airspeed: float = 0.0
    calibrated_airspeed: float = 0.0
    alpha: float = 0.0
    beta: float = 0.0
    lift_coefficient: float = 0.0
    thrust: float = 0.0
    weight_on_wheels: bool = False
    stalled: bool = False
    force_body: tuple = (0.0, 0.0, 0.0)
    moment_body: tuple = (0.0, 0.0, 0.0)


@dataclass
class Deriv:
    d_pos: tuple
    d_vel: tuple
    d_q: Quat
    d_rates: tuple

# --------------------------------------------------------------------------- FlightModel
class FlightModel:
    def __init__(self, config: Config = SF1):
        self.config = config

    # ---- forcesAndMoments
    def forces_and_moments(self, s: State, in_raw: Inputs, env: Env):
        c, a = self.config, self.config.aero
        inp = in_raw.sanitized()
        out = Outputs()
        atm = isa_state(env.origin_height + s.altitude, env.temperature_offset)
        wind_body = s.att.conjugate().rotate(env.wind_ned)
        va = vsub(s.vel, wind_body)
        speed = vlen(va)
        fx = fy = fz = 0.0
        mx = my = mz = 0.0

        if speed > 0.5:
            alpha = math.atan2(va[2], va[0])
            beta = math.asin(clamp(va[1] / speed, -1, 1))
            qbar = 0.5 * atm.density * speed * speed
            p, q, r = s.rates
            ph = p * c.wing_span / (2 * speed)
            qh = q * c.chord / (2 * speed)
            rh = r * c.wing_span / (2 * speed)
            de = -(inp.elevator + inp.elevator_trim * 0.5) * c.elevator_max
            da = inp.aileron * c.aileron_max
            dr = -inp.rudder * c.rudder_max
            flaps = inp.flaps

            ground_elev = env.elevation(s.pos[0], s.pos[1])
            h = max(0.1, s.altitude - ground_elev)
            hb = 16 * h / c.wing_span
            phi = (hb * hb) / (1 + hb * hb)

            cl_max = a.cLMaxClean + (a.cLMaxFlaps - a.cLMaxClean) * flaps
            cl_lin = a.cL0 + a.cLAlpha * alpha + a.cLFlap * flaps
            alpha_stall = (cl_max - a.cL0 - a.cLFlap * flaps) / a.cLAlpha
            w = 0.06
            soft = cl_max - w * _log1pexp((cl_max - cl_lin) / w)
            soft_neg = -cl_max + w * _log1pexp((cl_lin + cl_max) / w)
            cl_sat = soft if alpha >= 0 else soft_neg
            break_alpha = alpha_stall + 2.5 * math.pi / 180
            m = 90.0
            e1 = _exp(-m * (alpha - break_alpha))
            e2 = _exp(m * (alpha + break_alpha))
            sigma = (1 + e1 + e2) / ((1 + e1) * (1 + e2))
            sa, ca = math.sin(alpha), math.cos(alpha)
            flat_plate = 2 * (1.0 if alpha >= 0 else -1.0) * sa * sa * ca
            cL = (1 - sigma) * cl_sat + sigma * flat_plate
            cL *= 1 + 0.08 * (1 - phi)
            cL += a.cLQ * qh + a.cLElevator * de
            k = phi / (math.pi * a.oswald * c.aspect_ratio)
            cD = a.cD0 + a.cDFlap * flaps + k * cL * cL + sigma * 1.2 * sa * sa
            cY = a.cYBeta * beta + a.cYRudder * dr
            cl = a.clBeta * beta + a.clP * ph + a.clR * rh + a.clAileron * da + a.clRudder * dr
            cm = a.cm0 + a.cmAlpha * alpha + a.cmQ * qh + a.cmElevator * de + a.cmFlap * flaps
            cn = a.cnBeta * beta + a.cnP * ph + a.cnR * rh + a.cnAileron * da + a.cnRudder * dr

            qs = qbar * c.wing_area
            fx += qs * (-cD * ca + cL * sa)
            fz += qs * (-cD * sa - cL * ca)
            fy += qs * cY
            mx += qs * c.wing_span * cl
            my += qs * c.chord * cm
            mz += qs * c.wing_span * cn

            out.alpha = alpha
            out.beta = beta
            out.lift_coefficient = cL
            out.stalled = alpha > break_alpha

        # Propulsion
        sigma_rho = atm.density / ISA_RHO0
        power = c.max_power * inp.throttle * sigma_rho ** 1.1
        eta_max = 0.80
        v0 = eta_max / c.static_thrust_per_watt
        vx = max(0.0, va[0])
        thrust = eta_max * power / math.sqrt(vx * vx + v0 * v0) if power > 0 else 0.0
        fx += thrust
        out.thrust = thrust

        # Gravity
        g = s.att.conjugate().rotate((0.0, 0.0, c.mass * ISA_G0))
        fx += g[0]; fy += g[1]; fz += g[2]

        # Landing gear
        gf, gm, wow = self.gear_forces(s, inp, env)
        fx += gf[0]; fy += gf[1]; fz += gf[2]
        mx += gm[0]; my += gm[1]; mz += gm[2]
        out.weight_on_wheels = wow

        out.true_airspeed = speed
        out.calibrated_airspeed = calibrated_airspeed(speed, atm)
        force = (fx, fy, fz)
        moment = (mx, my, mz)
        out.force_body = force
        out.moment_body = moment
        return force, moment, out

    # ---- gearForces
    def gear_forces(self, s: State, inp: Inputs, env: Env):
        f = (0.0, 0.0, 0.0)
        m = (0.0, 0.0, 0.0)
        wow = False
        for leg in self.config.gear:
            p_ned = vadd(s.pos, s.att.rotate(leg.position))
            ground_down = -env.elevation(p_ned[0], p_ned[1])
            compression = p_ned[2] - ground_down
            if not compression > 0:
                continue
            wow = True
            vb = vadd(s.vel, vcross(s.rates, leg.position))
            v_ned = s.att.rotate(vb)
            normal = max(0.0, leg.stiffness * min(compression, 0.5) + leg.damping * v_ned[2])
            hd = s.att.rotate((1.0, 0.0, 0.0))
            hd = vnorm((hd[0], hd[1], 0.0))
            if leg.steerable:
                steer = inp.rudder * 10 * DEG
                ch, sh = math.cos(steer), math.sin(steer)
                hd = (hd[0] * ch - hd[1] * sh, hd[0] * sh + hd[1] * ch, 0.0)
            side = (-hd[1], hd[0], 0.0)
            v_long, v_lat = vdot(v_ned, hd), vdot(v_ned, side)
            mu_roll = 0.02 + (0.55 * inp.brakes if leg.braked else 0.0)
            f_long = -mu_roll * normal * math.tanh(v_long / 0.3)
            f_lat = -0.85 * normal * math.tanh(v_lat / 0.15)
            f_ned = vadd(vadd(vmul(hd, f_long), vmul(side, f_lat)), (0.0, 0.0, -normal))
            f_body = s.att.conjugate().rotate(f_ned)
            f = vadd(f, f_body)
            m = vadd(m, vcross(leg.position, f_body))
        return f, m, wow

    # ---- integration
    def derivative(self, s: State, inp: Inputs, env: Env) -> Deriv:
        f, mom, _ = self.forces_and_moments(s, inp, env)
        w, i = s.rates, self.config.inertia
        mass = self.config.mass
        d_vel = vsub(vmul(f, 1.0 / mass), vcross(w, s.vel))
        iw = (i[0] * w[0], i[1] * w[1], i[2] * w[2])
        t = vsub(mom, vcross(w, iw))
        d_rates = (t[0] / i[0], t[1] / i[1], t[2] / i[2])
        return Deriv(s.att.rotate(s.vel), d_vel, s.att.derivative(w), d_rates)

    @staticmethod
    def apply(s: State, d: Deriv, h: float) -> State:
        return State(vadd(s.pos, vmul(d.d_pos, h)), vadd(s.vel, vmul(d.d_vel, h)),
                     Quat(s.att.w + d.d_q.w * h, vadd(s.att.v, vmul(d.d_q.v, h))),
                     vadd(s.rates, vmul(d.d_rates, h)), s.time)

    def rk4(self, s: State, inp: Inputs, env: Env, h: float) -> State:
        k1 = self.derivative(s, inp, env)
        k2 = self.derivative(self.apply(s, k1, h / 2), inp, env)
        k3 = self.derivative(self.apply(s, k2, h / 2), inp, env)
        k4 = self.derivative(self.apply(s, k3, h), inp, env)

        def comb(a, b, c, d):
            return tuple((a[j] + 2 * b[j] + 2 * c[j] + d[j]) * (h / 6) for j in range(3))
        pos = vadd(s.pos, comb(k1.d_pos, k2.d_pos, k3.d_pos, k4.d_pos))
        vel = vadd(s.vel, comb(k1.d_vel, k2.d_vel, k3.d_vel, k4.d_vel))
        rates = vadd(s.rates, comb(k1.d_rates, k2.d_rates, k3.d_rates, k4.d_rates))
        dqw = (k1.d_q.w + 2 * k2.d_q.w + 2 * k3.d_q.w + k4.d_q.w) * (h / 6)
        dqv = comb(k1.d_q.v, k2.d_q.v, k3.d_q.v, k4.d_q.v)
        att = Quat(s.att.w + dqw, vadd(s.att.v, dqv)).normalized()
        return State(pos, vel, att, rates, s.time + h)

    def step(self, s: State, inputs: Inputs, env: Env, dt: float = 1.0 / 120.0) -> State:
        ground_elev = env.elevation(s.pos[0], s.pos[1])
        near_ground = s.altitude - ground_elev < 4
        n = s
        if near_ground:
            for _ in range(4):
                n = self.rk4(n, inputs, env, dt / 4)
        else:
            n = self.rk4(n, inputs, env, dt)
        if not n.is_finite():
            return State(s.pos, s.vel, s.att, (0.0, 0.0, 0.0), s.time + dt)
        return n

    def outputs(self, s: State, inputs: Inputs, env: Env) -> Outputs:
        return self.forces_and_moments(s, inputs, env)[2]

    # ---- trim
    def trim_level(self, tas, altitude, flaps=0.0, env: Env | None = None, warm_start=None):
        env = env or Env()
        cfg = self.config
        rho = isa_state(env.origin_height + altitude, env.temperature_offset).density
        a = cfg.aero
        cl_req = cfg.mass * ISA_G0 / (0.5 * rho * tas * tas * cfg.wing_area)
        alpha0 = clamp((cl_req - a.cL0 - a.cLFlap * flaps) / a.cLAlpha, -0.1, 0.35)
        de0 = (a.cm0 + a.cmAlpha * alpha0 + a.cmFlap * flaps) / a.cmElevator
        x = [alpha0, clamp(-de0 / cfg.elevator_max, -1, 1), 0.5]
        if warm_start is not None and warm_start["converged"]:
            x = [warm_start["alpha"], warm_start["inputs"].elevator, warm_start["inputs"].throttle]

        def make(x):
            st = State((0.0, 0.0, -altitude), (tas * math.cos(x[0]), 0.0, tas * math.sin(x[0])),
                       Quat.from_euler(0.0, x[0], 0.0), (0.0, 0.0, 0.0))
            return st, Inputs(elevator=x[1], throttle=x[2], flaps=flaps)

        def residual(x):
            st, inp = make(x)
            d = self.derivative(st, inp, env)
            return [d.d_vel[0], d.d_vel[2], d.d_rates[1]]

        converged = False
        for _ in range(200):
            r = residual(x)
            if abs(r[0]) < 1e-7 and abs(r[1]) < 1e-7 and abs(r[2]) < 1e-8:
                converged = True
                break
            j = [[0.0] * 3 for _ in range(3)]
            eps = 1e-6
            for col in range(3):
                xp = list(x)
                xp[col] += eps
                rp = residual(xp)
                for row in range(3):
                    j[row][col] = (rp[row] - r[row]) / eps
            dx = _solve3(j, [-r[0], -r[1], -r[2]])
            if dx is None:
                break
            scale = min(1.0, 0.02 / max(abs(dx[0]), 1e-12))
            x = [x[k] + dx[k] * scale for k in range(3)]
            x[1] = clamp(x[1], -1.5, 1.5)
            x[2] = clamp(x[2], -0.5, 1.5)
        st, inp = make(x)
        valid = converged and 0 <= inp.throttle <= 1 and abs(inp.elevator) <= 1
        return {"state": st, "inputs": inp, "alpha": x[0], "converged": valid}

    def design_stall_speed(self, altitude, flaps=0.0):
        rho = isa_state(altitude).density
        a = self.config.aero
        cl_max = a.cLMaxClean + (a.cLMaxFlaps - a.cLMaxClean) * flaps
        return math.sqrt(2 * self.config.mass * ISA_G0 / (rho * self.config.wing_area * cl_max))


def _exp(x):
    # Swift exp() overflows to +inf silently; Python raises. Mirror the IEEE behaviour.
    try:
        return math.exp(x)
    except OverflowError:
        return math.inf


def _log1pexp(x):
    # Swift: log(1 + exp(x)). Plain form kept (overflow -> inf), mirroring Swift exactly.
    e = _exp(x)
    return math.log(1 + e) if e != math.inf else math.inf


def _solve3(a, b):
    m = [row[:] for row in a]
    v = list(b)
    for i in range(3):
        piv = i
        for r in range(i + 1, 3):
            if abs(m[r][i]) > abs(m[piv][i]):
                piv = r
        if not abs(m[piv][i]) > 1e-14:
            return None
        m[i], m[piv] = m[piv], m[i]
        v[i], v[piv] = v[piv], v[i]
        for r in range(i + 1, 3):
            f = m[r][i] / m[i][i]
            for c in range(i, 3):
                m[r][c] -= f * m[i][c]
            v[r] -= f * v[i]
    x = [0.0, 0.0, 0.0]
    for i in (2, 1, 0):
        s = v[i]
        for c in range(i + 1, 3):
            s -= m[i][c] * x[c]
        x[i] = s / m[i][i]
    return x
