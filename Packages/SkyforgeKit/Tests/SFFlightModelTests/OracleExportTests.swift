//
// SKYFORGE — Apache-2.0
// Runs the real `FlightModel` through the oracle scenarios of tools/jsbsim_oracle/scenarios.py and writes the
// JSON described in tools/jsbsim_oracle/SWIFT_EMITTER.md. Skipped unless SF_ORACLE_OUT is set:
//
//   SF_ORACLE_OUT=/tmp/sf1_swift.json swift test --filter OracleExportTests
//   python3 tools/jsbsim_oracle/compare.py --sf1 /tmp/sf1_swift.json --jsbsim tools/jsbsim_oracle/jsbsim_results.json
//   python3 tools/jsbsim_oracle/check_mirror.py /tmp/sf1_swift.json tools/jsbsim_oracle/sf1_results.json
//
// Every number below must stay in step with scenarios.py (control laws, gains, durations). Curve fits are NOT done
// in Swift: short_period and phugoid emit raw `series` and compare.py fits them with the same Python code it uses
// for JSBSim and for the mirror.
import Testing
import Foundation
@testable import SFFlightModel
import SFMath
import SFAtmosphere

private let kt = 0.514444
private let ft = 0.3048
private let d2r = Double.pi / 180

private func clampD(_ x: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, x)) }

private struct Obs {
    var t = 0.0, tasKt = 0.0, casKt = 0.0, altFt = 0.0, hGainFt = 0.0, vzFps = 0.0
    var alphaDeg = 0.0, betaDeg = 0.0, thetaDeg = 0.0, phiDeg = 0.0, psiDeg = 0.0
    var pDps = 0.0, qDps = 0.0, rDps = 0.0, cl = 0.0
    var wowMain = false
    var distFt = 0.0, ailDeg = 0.0, elevDegUp = 0.0
}

private struct TrimInfo {
    var alphaDeg: Double, thetaDeg: Double, elevDegUp: Double, throttle: Double, powerKw: Double, converged: Bool
}

/// Mirrors the Plant interface in scenarios.py.
private final class Plant {
    let fm = FlightModel()
    let env = FlightEnvironment()
    let dt = 1.0 / 120.0
    var s = AircraftState(positionNED: .zero, velocityBody: .zero, attitude: .identity, bodyRates: .zero)
    var inp = ControlInputs()
    var startAlt = 0.0
    var startN = 0.0, startE = 0.0

    var elevMaxDeg: Double { fm.config.elevatorMax / d2r }       // up and down travel are equal
    var ailMaxDeg: Double { fm.config.aileronMax / d2r }
    var rudMaxDeg: Double { fm.config.rudderMax / d2r }

    func trim(tasKt: Double, altFt: Double, flaps: Double) -> TrimInfo {
        let r = fm.trimLevel(trueAirspeed: tasKt * kt, altitude: altFt * ft, flaps: flaps, environment: env)
        s = r.state; inp = r.inputs
        startAlt = s.altitude; startN = s.positionNED.x; startE = s.positionNED.y
        let sigma = ISA.state(geometricAltitude: s.altitude).density / ISA.seaLevelDensity
        return TrimInfo(alphaDeg: r.alpha / d2r, thetaDeg: r.alpha / d2r, elevDegUp: inp.elevator * elevMaxDeg,
                        throttle: inp.throttle,
                        powerKw: fm.config.maxPower * inp.throttle * pow(sigma, 1.1) / 1000, converged: r.converged)
    }

    func initFlight(tasKt: Double, altFt: Double, alphaDeg: Double, flaps: Double, elevDegUp: Double, throttle: Double) {
        let a = alphaDeg * d2r, v = tasKt * kt
        s = AircraftState(positionNED: SIMD3(0, 0, -altFt * ft), velocityBody: SIMD3(v * cos(a), 0, v * sin(a)),
                          attitude: Quaternion(roll: 0, pitch: a, yaw: 0), bodyRates: .zero)
        inp = ControlInputs(elevator: elevDegUp / elevMaxDeg, throttle: throttle, flaps: flaps)
        startAlt = s.altitude; startN = 0; startE = 0
    }

    func initGround() {
        s = AircraftState(positionNED: SIMD3(0, 0, -1.20), velocityBody: .zero,
                          attitude: Quaternion(roll: 0, pitch: 0, yaw: 0), bodyRates: .zero)
        inp = ControlInputs(brakes: 1)
        for _ in 0..<360 { s = fm.step(s, inputs: inp, environment: env, dt: dt) }
        s = AircraftState(positionNED: s.positionNED, velocityBody: .zero, attitude: s.attitude, bodyRates: .zero, time: 0)
        inp = ControlInputs()
        startAlt = s.altitude; startN = s.positionNED.x; startE = s.positionNED.y
    }

    func set(elevDegUp: Double? = nil, aileron: Double? = nil, rudder: Double? = nil,
             throttle: Double? = nil, flaps: Double? = nil, brakes: Double? = nil) {
        if let e = elevDegUp { inp.elevator = clampD(e / elevMaxDeg, -1, 1) }
        if let a = aileron { inp.aileron = clampD(a, -1, 1) }
        if let r = rudder { inp.rudder = clampD(r, -1, 1) }
        if let t = throttle { inp.throttle = clampD(t, 0, 1) }
        if let f = flaps { inp.flaps = clampD(f, 0, 1) }
        if let b = brakes { inp.brakes = clampD(b, 0, 1) }
    }

    func step() { s = fm.step(s, inputs: inp, environment: env, dt: dt) }

    private func mainWheelsOnGround() -> Bool {
        for leg in fm.config.gear where leg.braked {
            let p = s.positionNED + s.attitude.rotate(leg.position)
            if p.z - (-env.terrain.elevation(north: p.x, east: p.y)) > 0 { return true }
        }
        return false
    }

    func obs() -> Obs {
        let o = fm.outputs(s, inputs: inp, environment: env)
        let e = s.attitude.euler
        let vned = s.attitude.rotate(s.velocityBody)
        var yaw = (e.yaw / d2r).truncatingRemainder(dividingBy: 360); if yaw < 0 { yaw += 360 }
        return Obs(t: s.time, tasKt: o.trueAirspeed / kt, casKt: o.calibratedAirspeed / kt, altFt: s.altitude / ft,
                   hGainFt: (s.altitude - startAlt) / ft, vzFps: -vned.z / ft, alphaDeg: o.alpha / d2r, betaDeg: o.beta / d2r,
                   thetaDeg: e.pitch / d2r, phiDeg: e.roll / d2r, psiDeg: yaw,
                   pDps: s.bodyRates.x / d2r, qDps: s.bodyRates.y / d2r, rDps: s.bodyRates.z / d2r, cl: o.liftCoefficient,
                   wowMain: mainWheelsOnGround(),
                   distFt: ((s.positionNED.x - startN) * (s.positionNED.x - startN)
                            + (s.positionNED.y - startE) * (s.positionNED.y - startE)).squareRoot() / ft,
                   ailDeg: inp.aileron * ailMaxDeg, elevDegUp: inp.elevator * elevMaxDeg)
    }
}

// MARK: control laws (scenarios.PitchHold, scenarios.WingsLevel)

private func pitchHold(_ p: Plant, e0: Double, o: Obs, thetaCmd: Double) {
    let e = e0 + 1.0 * (thetaCmd - o.thetaDeg) - 0.4 * o.qDps
    p.set(elevDegUp: clampD(e, -p.elevMaxDeg, p.elevMaxDeg))
}

private func wingsLevel(_ p: Plant, o: Obs) {
    let d = -(0.8 * o.phiDeg + 0.35 * o.pDps)
    p.set(aileron: clampD(d / p.ailMaxDeg, -1, 1))
}

/// scenarios.history: controller(obs, tRel) runs before each step; returns one Obs per step plus the final one.
private func history(_ p: Plant, seconds: Double, _ ctl: ((Obs, Double) -> Void)?) -> [Obs] {
    let n = Int((seconds / p.dt).rounded())
    var rec: [Obs] = []
    for k in 0..<n {
        let o = p.obs()
        ctl?(o, Double(k) * p.dt)
        rec.append(o)
        p.step()
    }
    rec.append(p.obs())
    return rec
}

private func meanBetween(_ rec: [Obs], _ key: KeyPath<Obs, Double>, _ t0: Double, _ t1: Double) -> Double {
    let v = rec.filter { $0.t >= t0 && $0.t <= t1 }.map { $0[keyPath: key] }
    return v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
}

private func wrap180(_ x: Double) -> Double {
    var y = (x + 180).truncatingRemainder(dividingBy: 360); if y < 0 { y += 360 }
    return y - 180
}

// MARK: scenarios (keys must match scenarios.py exactly)

private typealias Metrics = [String: Any]

private func runTrim(_ p: Plant) -> Metrics {
    let t = p.trim(tasKt: 100, altFt: 3000, flaps: 0)
    let o = p.obs()
    return ["converged": t.converged, "alpha_deg": t.alphaDeg, "elevator_deg_up": t.elevDegUp, "throttle": t.throttle,
            "power_kw": t.powerKw, "climb_fpm": o.vzFps * 60, "cas_kt": o.casKt, "cl": o.cl]
}

private func runStall(_ p: Plant, startTas: Double, flaps: Double) -> Metrics {
    let tr = p.trim(tasKt: startTas, altFt: 3000, flaps: flaps)
    p.set(throttle: 0)
    var rec: [Obs] = []
    let maxS = 150.0, ramp = 1.0, rampStart = 3.0
    for _ in 0..<Int(maxS / p.dt) {
        let o = p.obs()
        let thetaCmd = tr.thetaDeg + ramp * max(0, o.t - rampStart)
        pitchHold(p, e0: tr.elevDegUp, o: o, thetaCmd: min(thetaCmd, 40))
        wingsLevel(p, o: o)
        rec.append(o)
        p.step()
        if rec.count > 100 {
            var pk = 0
            for (i, r) in rec.enumerated() where r.cl > rec[pk].cl { pk = i }   // first maximum, like numpy argmax
            let limit = rec.last!.cl < 0.9 * rec[pk].cl ? 1.0 : 6.0
            if o.t - rec[pk].t > limit { break }
            if o.casKt < 15 { break }
        }
    }
    var pk = 0
    for (i, r) in rec.enumerated() where r.cl > rec[pk].cl { pk = i }
    let thPk = rec[0...pk].map(\.thetaDeg).max()!
    let after = rec.first(where: { $0.t >= rec[pk].t + 4 })?.cl ?? rec.last!.cl
    let i5 = rec.firstIndex(where: { $0.t >= 5 }) ?? 0
    let span = rec[pk].t - rec[i5].t
    let decel = span > 1 ? (rec[i5].casKt - rec[pk].casKt) / span : Double.nan
    return ["cl_max": rec[pk].cl, "v_clmax_kcas": rec[pk].casKt, "v_clmax_ktas": rec[pk].tasKt,
            "alpha_clmax_deg": rec[pk].alphaDeg, "decel_kt_per_s": decel, "cl_ratio_4s_after_peak": after / rec[pk].cl,
            "alpha_max_deg": rec.map(\.alphaDeg).max()!, "t_peak_s": rec[pk].t, "theta_peak_deg": thPk,
            "vz_at_peak_fpm": rec[pk].vzFps * 60]
}

private func runShortPeriod(_ p: Plant) -> Metrics {
    let amp = 2.5, half = 0.5, pre = 2.0, post = 8.0
    let tr = p.trim(tasKt: 100, altFt: 3000, flaps: 0)
    let e0 = tr.elevDegUp
    let rec = history(p, seconds: pre + 2 * half + post) { o, t in
        wingsLevel(p, o: o)
        let e: Double
        if t >= pre && t < pre + half { e = e0 + amp }
        else if t >= pre + half && t < pre + 2 * half { e = e0 - amp }
        else { e = e0 }
        p.set(elevDegUp: e)
    }
    // Raw series only: compare.py fits wn/zeta (scenarios.short_period_metrics).
    return ["series": ["t": rec.map(\.t), "q_dps": rec.map(\.qDps)]]
}

private func runAileronStep(_ p: Plant) -> Metrics {
    let stick = 0.5, pre = 2.0, post = 5.0
    let tr = p.trim(tasKt: 100, altFt: 3000, flaps: 0)
    let ail0 = p.obs().ailDeg
    let rec = history(p, seconds: pre + post) { _, t in
        p.set(elevDegUp: tr.elevDegUp, aileron: t >= pre ? stick : 0)
    }
    let base = meanBetween(rec, \.pDps, 0.5, pre - 0.1)
    let pss = meanBetween(rec, \.pDps, pre + 1.5, pre + 3.5) - base
    let ail = rec.last!.ailDeg - ail0
    let tau = rec.first(where: { $0.t > pre && ($0.pDps - base) >= 0.632 * pss }).map { $0.t - pre } ?? Double.nan
    return ["p_ss_dps": pss, "tau_roll_s": tau, "ail_defl_deg": ail,
            "p_per_deg_ail": abs(ail) > 1e-6 ? pss / ail : Double.nan, "phi_end_deg": rec.last!.phiDeg]
}

private func runPhugoid(_ p: Plant) -> Metrics {
    let dv = 8.0, duration = 150.0
    let tr = p.trim(tasKt: 100, altFt: 3000, flaps: 0)
    p.initFlight(tasKt: 100 + dv, altFt: 3000, alphaDeg: tr.alphaDeg, flaps: 0, elevDegUp: tr.elevDegUp, throttle: tr.throttle)
    let rec = history(p, seconds: duration) { o, _ in wingsLevel(p, o: o) }
    let stride = max(1, Int((0.25 / p.dt).rounded()))
    let sel = rec.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
    return ["series": ["t": sel.map(\.t), "tas_kt": sel.map(\.tasKt), "alt_ft": sel.map(\.altFt)]]
}

private func runRudderStep(_ p: Plant) -> Metrics {
    let stick = 0.5, pre = 3.0, post = 12.0
    let tr = p.trim(tasKt: 100, altFt: 3000, flaps: 0)
    let rec = history(p, seconds: pre + post) { o, t in
        p.set(elevDegUp: tr.elevDegUp, rudder: t >= pre ? stick : 0)
        wingsLevel(p, o: o)
    }
    let tEnd = pre + post
    let beta = meanBetween(rec, \.betaDeg, tEnd - 2, tEnd)
    let peak = rec.filter { $0.t >= pre }.map(\.betaDeg).max(by: { abs($0) < abs($1) })!
    let rud = stick * p.rudMaxDeg
    return ["beta_ss_deg": beta, "beta_peak_deg": peak, "beta_ss_per_deg_rudder": beta / rud,
            "r_ss_dps": meanBetween(rec, \.rDps, tEnd - 2, tEnd), "phi_max_abs_deg": rec.map { abs($0.phiDeg) }.max()!,
            "rudder_defl_deg": rud]
}

private func runTakeoff(_ p: Plant) -> Metrics {
    let vr = 55.0, pitchDeg = 9.0, gainFt = 55.0, maxS = 90.0
    p.initGround()
    let psi0 = p.obs().psiDeg
    p.set(throttle: 1, flaps: 0, brakes: 0)
    var rec: [Obs] = []
    var rotating = false
    var liftI: Int? = nil
    var done: Int? = nil
    for _ in 0..<Int(maxS / p.dt) {
        let o = p.obs()
        let dpsi = wrap180(o.psiDeg - psi0)
        p.set(rudder: clampD(-(0.03 * dpsi + 0.06 * o.rDps), -1, 1))
        if o.casKt >= vr { rotating = true }
        if rotating { pitchHold(p, e0: 0, o: o, thetaCmd: pitchDeg) } else { p.set(elevDegUp: 0) }
        if !o.wowMain { wingsLevel(p, o: o) }
        rec.append(o)
        if liftI == nil && !o.wowMain && rotating { liftI = rec.count - 1 }
        if o.hGainFt >= gainFt && liftI != nil { done = rec.count - 1; break }
        p.step()
    }
    guard let d = done, let l = liftI else {
        return ["completed": false, "t_end_s": rec.last!.t, "dist_end_ft": rec.last!.distFt,
                "cas_end_kt": rec.last!.casKt, "h_gain_end_ft": rec.last!.hGainFt]
    }
    return ["completed": true, "ground_roll_ft": rec[l].distFt, "liftoff_kcas": rec[l].casKt, "t_liftoff_s": rec[l].t,
            "dist_to_55ft_ft": rec[d].distFt, "t_to_55ft_s": rec[d].t, "cas_at_55ft_kt": rec[d].casKt,
            "heading_dev_max_deg": rec.map { abs(wrap180($0.psiDeg - psi0)) }.max()!]
}

// MARK: JSON helpers

/// JSON has no NaN/Infinity: emit null (compare.py reports the row as MISSING).
private func jsonSafe(_ v: Any) -> Any {
    if let d = v as? Double { return d.isFinite ? (d as Any) : (NSNull() as Any) }
    if let a = v as? [Double] { return a.map { (x: Double) -> Any in x.isFinite ? x : NSNull() } }
    if let m = v as? [String: Any] { return m.mapValues(jsonSafe) }
    return v
}

@Suite("JSBSim oracle export")
struct OracleExportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SF_ORACLE_OUT"] != nil))
    func exportOracleJSON() throws {
        let path = ProcessInfo.processInfo.environment["SF_ORACLE_OUT"]!
        var scenarios: [String: Any] = [:]
        scenarios["trim"] = runTrim(Plant())
        scenarios["stall_clean"] = runStall(Plant(), startTas: 80, flaps: 0)
        scenarios["stall_flaps"] = runStall(Plant(), startTas: 65, flaps: 1)
        scenarios["short_period"] = runShortPeriod(Plant())
        scenarios["aileron_step"] = runAileronStep(Plant())
        scenarios["phugoid"] = runPhugoid(Plant())
        scenarios["rudder_step"] = runRudderStep(Plant())
        scenarios["takeoff"] = runTakeoff(Plant())
        let doc: [String: Any] = [
            "meta": ["source": "swift", "model": "SF-1 Trainer", "mass_kg": FlightModel().config.mass,
                     "schema_version": 1],
            "scenarios": jsonSafe(scenarios),
        ]
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))

        // Sanity so the export itself guards against a broken flight model.
        let trim = scenarios["trim"] as! Metrics
        #expect(trim["converged"] as? Bool == true)
        let takeoff = scenarios["takeoff"] as! Metrics
        #expect(takeoff["completed"] as? Bool == true)
    }
}
