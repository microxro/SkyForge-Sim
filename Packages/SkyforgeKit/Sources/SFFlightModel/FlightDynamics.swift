// SKYFORGE — Apache-2.0
// 6-DOF rigid-body flight dynamics, RK4. Local tangent-plane NED frame (flat-Earth approximation
// re-anchored by the orchestrator; see docs/ARCHITECTURE.md). Pure and deterministic: no wall clock.
import Foundation
import SFMath
import SFAtmosphere

/// Pilot and system control inputs, normalised.
public struct ControlInputs: Sendable, Equatable, Codable {
    public var elevator: Double = 0   // -1 nose down … +1 nose up (stick back)
    public var aileron: Double = 0    // -1 left … +1 right roll
    public var rudder: Double = 0     // -1 left … +1 right yaw
    public var throttle: Double = 0   // 0 … 1
    public var flaps: Double = 0      // 0 … 1
    public var brakes: Double = 0     // 0 … 1
    public var elevatorTrim: Double = 0
    public init() {}
    public init(elevator: Double = 0, aileron: Double = 0, rudder: Double = 0, throttle: Double = 0, flaps: Double = 0, brakes: Double = 0, elevatorTrim: Double = 0) {
        self.elevator = elevator; self.aileron = aileron; self.rudder = rudder
        self.throttle = throttle; self.flaps = flaps; self.brakes = brakes; self.elevatorTrim = elevatorTrim
    }
    /// Inputs clamped to their valid ranges (NaN becomes neutral).
    public var sanitized: ControlInputs {
        func c(_ x: Double, _ lo: Double, _ hi: Double) -> Double { x.isFinite ? min(hi, max(lo, x)) : 0 }
        return ControlInputs(elevator: c(elevator, -1, 1), aileron: c(aileron, -1, 1), rudder: c(rudder, -1, 1),
                             throttle: c(throttle, 0, 1), flaps: c(flaps, 0, 1), brakes: c(brakes, 0, 1),
                             elevatorTrim: c(elevatorTrim, -1, 1))
    }
}

/// Terrain height provider (metres above the local origin's ellipsoid height, positive up).
public protocol TerrainHeightProvider: Sendable {
    func elevation(north: Double, east: Double) -> Double
}

public struct FlatTerrain: TerrainHeightProvider {
    public var height: Double
    public init(height: Double = 0) { self.height = height }
    public func elevation(north: Double, east: Double) -> Double { height }
}

/// Environment for one step.
public struct FlightEnvironment: Sendable {
    public var windNED: SIMD3<Double>
    public var temperatureOffset: Double
    public var originHeight: Double            // ellipsoid height of the local origin (m)
    public var terrain: any TerrainHeightProvider
    public init(windNED: SIMD3<Double> = .zero, temperatureOffset: Double = 0, originHeight: Double = 0,
                terrain: any TerrainHeightProvider = FlatTerrain()) {
        self.windNED = windNED; self.temperatureOffset = temperatureOffset
        self.originHeight = originHeight; self.terrain = terrain
    }
}

/// Rigid-body state.
public struct AircraftState: Sendable, Equatable {
    public var positionNED: SIMD3<Double>     // m
    public var velocityBody: SIMD3<Double>    // u, v, w (m/s)
    public var attitude: Quaternion           // body -> NED
    public var bodyRates: SIMD3<Double>       // p, q, r (rad/s)
    public var time: Double = 0

    public init(positionNED: SIMD3<Double>, velocityBody: SIMD3<Double>, attitude: Quaternion, bodyRates: SIMD3<Double>, time: Double = 0) {
        self.positionNED = positionNED; self.velocityBody = velocityBody
        self.attitude = attitude; self.bodyRates = bodyRates; self.time = time
    }

    public var altitude: Double { -positionNED.z }
    public var velocityNED: SIMD3<Double> { attitude.rotate(velocityBody) }
    public var isFinite: Bool {
        let all = [positionNED.x, positionNED.y, positionNED.z, velocityBody.x, velocityBody.y, velocityBody.z,
                   attitude.w, attitude.v.x, attitude.v.y, attitude.v.z, bodyRates.x, bodyRates.y, bodyRates.z]
        return all.allSatisfy { $0.isFinite }
    }

    /// Determinism hash over all state bits.
    public func hash(into h: inout FNV1a) {
        for d in [positionNED.x, positionNED.y, positionNED.z, velocityBody.x, velocityBody.y, velocityBody.z,
                  attitude.w, attitude.v.x, attitude.v.y, attitude.v.z, bodyRates.x, bodyRates.y, bodyRates.z, time] {
            h.add(d)
        }
    }
}

/// Derived quantities for instruments and tests.
public struct FlightOutputs: Sendable, Equatable {
    public var trueAirspeed: Double = 0
    public var calibratedAirspeed: Double = 0
    public var alpha: Double = 0
    public var beta: Double = 0
    public var liftCoefficient: Double = 0
    public var thrust: Double = 0
    public var weightOnWheels: Bool = false
    public var stalled: Bool = false
    public var forceBody: SIMD3<Double> = .zero
    public var momentBody: SIMD3<Double> = .zero
}

struct StateDerivative {
    var dPos: SIMD3<Double>
    var dVel: SIMD3<Double>
    var dQ: Quaternion
    var dRates: SIMD3<Double>
}

public struct FlightModel: Sendable {
    public let config: AircraftConfig
    public init(config: AircraftConfig = .sf1Trainer) { self.config = config }

    // MARK: Forces and moments

    /// Computes body forces (N) and moments (N m) and outputs for a state.
    public func forcesAndMoments(_ s: AircraftState, _ inRaw: ControlInputs, _ env: FlightEnvironment) -> (SIMD3<Double>, SIMD3<Double>, FlightOutputs) {
        let c = config, a = c.aero
        let input = inRaw.sanitized
        var out = FlightOutputs()
        let atm = ISA.state(geometricAltitude: env.originHeight + s.altitude, temperatureOffset: env.temperatureOffset)
        let windBody = s.attitude.conjugate.rotate(env.windNED)
        let va = s.velocityBody - windBody
        let speed = length(va)
        var force = SIMD3<Double>(0, 0, 0)
        var moment = SIMD3<Double>(0, 0, 0)

        // Aerodynamics
        if speed > 0.5 {
            let alpha = atan2(va.z, va.x)
            let beta = asin(clamp(va.y / speed, -1, 1))
            let qbar = 0.5 * atm.density * speed * speed
            let p = s.bodyRates.x, q = s.bodyRates.y, r = s.bodyRates.z
            let ph = p * c.wingSpan / (2 * speed), qh = q * c.chord / (2 * speed), rh = r * c.wingSpan / (2 * speed)
            // Surface deflections use the standard sign convention: positive elevator = trailing edge
            // down (nose down), positive rudder = trailing edge left (nose left). Pilot inputs are
            // "stick back = +1" and "right pedal = +1", hence the sign flips.
            let de = -(input.elevator + input.elevatorTrim * 0.5) * c.elevatorMax
            let da = input.aileron * c.aileronMax
            let dr = -input.rudder * c.rudderMax
            let flaps = input.flaps

            // Ground effect (McCormick): reduces induced drag near the ground.
            let groundElev = env.terrain.elevation(north: s.positionNED.x, east: s.positionNED.y)
            let h = max(0.1, s.altitude - groundElev)
            let hb = 16 * h / c.wingSpan
            let phi = (hb * hb) / (1 + hb * hb)

            let cLMax = a.cLMaxClean + (a.cLMaxFlaps - a.cLMaxClean) * flaps
            let cLLin = a.cL0 + a.cLAlpha * alpha + a.cLFlap * flaps
            let alphaStall = (cLMax - a.cL0 - a.cLFlap * flaps) / a.cLAlpha
            // Linear lift softly saturated at CLmax, then blended (Beard & McLain sigmoid) into
            // flat-plate lift just past the peak, so the lift curve rounds over and breaks.
            let w = 0.06
            let soft = cLMax - w * log(1 + exp((cLMax - cLLin) / w))
            let softNeg = -cLMax + w * log(1 + exp((cLLin + cLMax) / w))
            let cLSat = alpha >= 0 ? soft : softNeg
            let breakAlpha = alphaStall + 2.5 * Double.pi / 180
            let m = 90.0
            let e1 = exp(-m * (alpha - breakAlpha)), e2 = exp(m * (alpha + breakAlpha))
            let sigma = (1 + e1 + e2) / ((1 + e1) * (1 + e2))
            let sa = sin(alpha), ca = cos(alpha)
            let flatPlate = 2 * (alpha >= 0 ? 1.0 : -1.0) * sa * sa * ca
            var cL = (1 - sigma) * cLSat + sigma * flatPlate
            cL *= 1 + 0.08 * (1 - phi)
            cL += a.cLQ * qh + a.cLElevator * de
            let k = phi / (Double.pi * a.oswald * c.aspectRatio)
            let cD = a.cD0 + a.cDFlap * flaps + k * cL * cL + sigma * 1.2 * sa * sa
            let cY = a.cYBeta * beta + a.cYRudder * dr
            let cl = a.clBeta * beta + a.clP * ph + a.clR * rh + a.clAileron * da + a.clRudder * dr
            let cm = a.cm0 + a.cmAlpha * alpha + a.cmQ * qh + a.cmElevator * de + a.cmFlap * flaps
            let cn = a.cnBeta * beta + a.cnP * ph + a.cnR * rh + a.cnAileron * da + a.cnRudder * dr

            let sArea = c.wingArea
            // Lift is perpendicular to the airflow in the x-z plane; drag opposes it.
            force.x += qbar * sArea * (-cD * ca + cL * sa)
            force.z += qbar * sArea * (-cD * sa - cL * ca)
            force.y += qbar * sArea * cY
            moment += SIMD3(qbar * sArea * c.wingSpan * cl, qbar * sArea * c.chord * cm, qbar * sArea * c.wingSpan * cn)

            out.alpha = alpha; out.beta = beta; out.liftCoefficient = cL
            out.stalled = alpha > breakAlpha
        }

        // Propulsion: power lapse with density; thrust blends smoothly from the static value
        // (staticThrustPerWatt * P) to eta * P / V: T = eta P / sqrt(V^2 + V0^2), V0 = eta / k_static.
        let sigmaRho = atm.density / ISA.seaLevelDensity
        let power = c.maxPower * input.throttle * pow(sigmaRho, 1.1)
        let etaMax = 0.80
        let v0 = etaMax / c.staticThrustPerWatt
        let vx = max(0, va.x)
        let thrust = power > 0 ? etaMax * power / (vx * vx + v0 * v0).squareRoot() : 0
        force.x += thrust
        out.thrust = thrust

        // Gravity
        force += s.attitude.conjugate.rotate(SIMD3(0, 0, c.mass * ISA.g0))

        // Landing gear
        let (gf, gm, wow) = gearForces(s, input, env)
        force += gf; moment += gm
        out.weightOnWheels = wow

        out.trueAirspeed = speed
        out.calibratedAirspeed = Airspeed.calibratedAirspeed(trueAirspeed: speed, atmosphere: atm)
        out.forceBody = force; out.momentBody = moment
        return (force, moment, out)
    }

    func gearForces(_ s: AircraftState, _ input: ControlInputs, _ env: FlightEnvironment) -> (SIMD3<Double>, SIMD3<Double>, Bool) {
        var f = SIMD3<Double>(0, 0, 0), m = SIMD3<Double>(0, 0, 0)
        var wow = false
        for leg in config.gear {
            let pNED = s.positionNED + s.attitude.rotate(leg.position)
            let groundDown = -env.terrain.elevation(north: pNED.x, east: pNED.y)
            let compression = pNED.z - groundDown
            guard compression > 0 else { continue }
            wow = true
            let vb = s.velocityBody + cross(s.bodyRates, leg.position)
            let vNED = s.attitude.rotate(vb)
            let normal = max(0, leg.stiffness * min(compression, 0.5) + leg.damping * vNED.z)
            // Wheel rolling direction on the ground plane (flat-ground approximation).
            var heading = s.attitude.rotate(SIMD3(1, 0, 0))
            heading.z = 0
            heading = normalize(heading)
            if leg.steerable {
                let steer = input.rudder * 10 * Units.degToRad
                let ch = cos(steer), sh = sin(steer)
                heading = SIMD3(heading.x * ch - heading.y * sh, heading.x * sh + heading.y * ch, 0)
            }
            let side = SIMD3(-heading.y, heading.x, 0)
            let vLong = dot(vNED, heading), vLat = dot(vNED, side)
            let muRoll = 0.02 + (leg.braked ? 0.55 * input.brakes : 0)
            let fLong = -muRoll * normal * tanh(vLong / 0.3)
            let fLat = -0.85 * normal * tanh(vLat / 0.15)
            let fNED = heading * fLong + side * fLat + SIMD3(0, 0, -normal)
            let fBody = s.attitude.conjugate.rotate(fNED)
            f += fBody
            m += cross(leg.position, fBody)
        }
        return (f, m, wow)
    }

    // MARK: Integration

    func derivative(_ s: AircraftState, _ input: ControlInputs, _ env: FlightEnvironment) -> StateDerivative {
        let (f, mom, _) = forcesAndMoments(s, input, env)
        let w = s.bodyRates, i = config.inertia
        let dVel = f / config.mass - cross(w, s.velocityBody)
        let iw = SIMD3(i.x * w.x, i.y * w.y, i.z * w.z)
        let dRates = (mom - cross(w, iw)) / i
        return StateDerivative(dPos: s.attitude.rotate(s.velocityBody), dVel: dVel,
                               dQ: s.attitude.derivative(bodyRate: w), dRates: dRates)
    }

    static func apply(_ s: AircraftState, _ d: StateDerivative, _ h: Double) -> AircraftState {
        var n = s
        n.positionNED += d.dPos * h
        n.velocityBody += d.dVel * h
        n.attitude = Quaternion(w: s.attitude.w + d.dQ.w * h, v: s.attitude.v + d.dQ.v * h)
        n.bodyRates += d.dRates * h
        return n
    }

    func rk4(_ s: AircraftState, _ input: ControlInputs, _ env: FlightEnvironment, _ h: Double) -> AircraftState {
        let k1 = derivative(s, input, env)
        let k2 = derivative(Self.apply(s, k1, h / 2), input, env)
        let k3 = derivative(Self.apply(s, k2, h / 2), input, env)
        let k4 = derivative(Self.apply(s, k3, h), input, env)
        var n = s
        n.positionNED += (k1.dPos + 2 * k2.dPos + 2 * k3.dPos + k4.dPos) * (h / 6)
        n.velocityBody += (k1.dVel + 2 * k2.dVel + 2 * k3.dVel + k4.dVel) * (h / 6)
        n.bodyRates += (k1.dRates + 2 * k2.dRates + 2 * k3.dRates + k4.dRates) * (h / 6)
        let dqw = (k1.dQ.w + 2 * k2.dQ.w + 2 * k3.dQ.w + k4.dQ.w) * (h / 6)
        let dqv = (k1.dQ.v + 2 * k2.dQ.v + 2 * k3.dQ.v + k4.dQ.v) * (h / 6)
        n.attitude = Quaternion(w: s.attitude.w + dqw, v: s.attitude.v + dqv).normalized
        n.time = s.time + h
        return n
    }

    /// Advances the state by `dt` (nominally 1/120 s). Uses 4 RK4 substeps (480 Hz) when any
    /// wheel is near the ground, because the gear springs are stiff. Non-finite results are rejected:
    /// the previous state is returned with rates zeroed so the simulation never propagates NaN.
    public func step(_ s: AircraftState, inputs: ControlInputs, environment env: FlightEnvironment, dt: Double = 1.0 / 120.0) -> AircraftState {
        let groundElev = env.terrain.elevation(north: s.positionNED.x, east: s.positionNED.y)
        let nearGround = s.altitude - groundElev < 4
        var n = s
        if nearGround {
            for _ in 0..<4 { n = rk4(n, inputs, env, dt / 4) }
        } else {
            n = rk4(n, inputs, env, dt)
        }
        if !n.isFinite {
            var safe = s
            safe.bodyRates = .zero
            safe.time = s.time + dt
            return safe
        }
        return n
    }

    public func outputs(_ s: AircraftState, inputs: ControlInputs, environment env: FlightEnvironment) -> FlightOutputs {
        forcesAndMoments(s, inputs, env).2
    }

    // MARK: Trim

    public struct TrimResult: Sendable {
        public var state: AircraftState
        public var inputs: ControlInputs
        public var alpha: Double
        public var converged: Bool
    }

    /// Wings-level, straight and level trim at a true airspeed and altitude (Newton iteration on
    /// alpha, elevator and throttle so that u-dot, w-dot and q-dot vanish).
    public func trimLevel(trueAirspeed v: Double, altitude: Double, flaps: Double = 0,
                          environment env: FlightEnvironment = FlightEnvironment(),
                          warmStart: TrimResult? = nil) -> TrimResult {
        // Analytic initial guess: alpha from the required lift coefficient, elevator from Cm = 0.
        let rho = ISA.state(geometricAltitude: env.originHeight + altitude, temperatureOffset: env.temperatureOffset).density
        let a = config.aero
        let cLReq = config.mass * ISA.g0 / (0.5 * rho * v * v * config.wingArea)
        let alpha0 = clamp((cLReq - a.cL0 - a.cLFlap * flaps) / a.cLAlpha, -0.1, 0.35)
        let de0 = (a.cm0 + a.cmAlpha * alpha0 + a.cmFlap * flaps) / a.cmElevator   // deflection (rad)
        var x = SIMD3<Double>(alpha0, clamp(-de0 / config.elevatorMax, -1, 1), 0.5) // alpha, elevator, throttle
        if let w = warmStart, w.converged { x = SIMD3(w.alpha, w.inputs.elevator, w.inputs.throttle) }
        func make(_ x: SIMD3<Double>) -> (AircraftState, ControlInputs) {
            let st = AircraftState(positionNED: SIMD3(0, 0, -altitude),
                                   velocityBody: SIMD3(v * cos(x.x), 0, v * sin(x.x)),
                                   attitude: Quaternion(roll: 0, pitch: x.x, yaw: 0), bodyRates: .zero)
            return (st, ControlInputs(elevator: x.y, throttle: x.z, flaps: flaps))
        }
        func residual(_ x: SIMD3<Double>) -> SIMD3<Double> {
            let (st, inp) = make(x)
            let d = derivative(st, inp, env)
            return SIMD3(d.dVel.x, d.dVel.z, d.dRates.y)
        }
        var converged = false
        for _ in 0..<200 {
            let r = residual(x)
            if abs(r.x) < 1e-7 && abs(r.y) < 1e-7 && abs(r.z) < 1e-8 { converged = true; break }
            // Numeric Jacobian
            var j = [[Double]](repeating: [0, 0, 0], count: 3)
            let eps = 1e-6
            for col in 0..<3 {
                var xp = x
                xp[col] += eps
                let rp = residual(xp)
                for row in 0..<3 { j[row][col] = (rp[row] - r[row]) / eps }
            }
            guard let dx = Self.solve3(j, [-r.x, -r.y, -r.z]) else { break }
            // Damped Newton step: limit alpha changes to 0.05 rad per iteration.
            let scale = min(1, 0.02 / max(abs(dx[0]), 1e-12))
            x += SIMD3(dx[0], dx[1], dx[2]) * scale
            x.y = clamp(x.y, -1.5, 1.5)
            x.z = clamp(x.z, -0.5, 1.5)
        }
        let (st, inp) = make(x)
        let valid = converged && inp.throttle >= 0 && inp.throttle <= 1 && abs(inp.elevator) <= 1
        return TrimResult(state: st, inputs: inp, alpha: x.x, converged: valid)
    }

    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        for i in 0..<3 {
            var piv = i
            for r in (i + 1)..<3 where abs(m[r][i]) > abs(m[piv][i]) { piv = r }
            guard abs(m[piv][i]) > 1e-14 else { return nil }
            m.swapAt(i, piv); v.swapAt(i, piv)
            for r in (i + 1)..<3 {
                let f = m[r][i] / m[i][i]
                for c in i..<3 { m[r][c] -= f * m[i][c] }
                v[r] -= f * v[i]
            }
        }
        var x = [0.0, 0.0, 0.0]
        for i in stride(from: 2, through: 0, by: -1) {
            var s = v[i]
            for c in (i + 1)..<3 { s -= m[i][c] * x[c] }
            x[i] = s / m[i][i]
        }
        return x
    }

    /// Design 1-g stall speed (TAS, m/s) at an altitude from CLmax.
    public func designStallSpeed(altitude: Double, flaps: Double = 0) -> Double {
        let rho = ISA.state(geometricAltitude: altitude).density
        let a = config.aero
        let cLMax = a.cLMaxClean + (a.cLMaxFlaps - a.cLMaxClean) * flaps
        return (2 * config.mass * ISA.g0 / (rho * config.wingArea * cLMax)).squareRoot()
    }
}
