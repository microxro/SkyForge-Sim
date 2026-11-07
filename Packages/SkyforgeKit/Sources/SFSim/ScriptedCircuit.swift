// SKYFORGE — Apache-2.0
// A deterministic scripted traffic circuit flown by the autopilot: takeoff, climb, circuit,
// 3-degree approach, flare, landing and rollout. Used as the P1 integration test and as a demo flight.
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel
import SFSystems

public enum CircuitPhase: String, Sendable {
    case takeoffRoll, rotate, climb, circuit, approach, flare, rollout, stopped
}

public struct CircuitReport: Sendable {
    public var phaseLog: [(time: Double, phase: CircuitPhase)] = []
    public var maxAltitude = 0.0
    public var touchdownVerticalSpeedFPM: Double?
    public var touchdownPosition: SIMD3<Double>?
    public var touchdownTime: Double?
    public var stopPosition: SIMD3<Double>?
    public var finalPhase: CircuitPhase = .takeoffRoll
    public var duration = 0.0
    public var maxBankDegrees = 0.0
    public var finite = true
}

/// Runway along +north starting at the origin (NED), flat terrain at elevation 0.
public struct ScriptedCircuit: Sendable {
    public let model: FlightModel
    public var environment: FlightEnvironment
    public let runwayLength = 1_500.0
    public let runwayWidth = 30.0
    public let patternAltitude = 300.0     // m (~1,000 ft)
    public let approachSpeed = 33.0        // m/s (~64 kt)
    public let cruiseSpeed = 46.0          // m/s (~90 kt)
    let waypoints: [SIMD2<Double>] = [SIMD2(2_800, 0), SIMD2(3_400, -1_600), SIMD2(0, -2_200), SIMD2(-4_200, -2_200), SIMD2(-6_000, -600)]

    public init(model: FlightModel = FlightModel(), environment: FlightEnvironment = FlightEnvironment()) {
        self.model = model
        self.environment = environment
    }

    func sensors(_ s: AircraftState, _ out: FlightOutputs) -> AutopilotSensors {
        let e = s.attitude.euler
        let v = s.velocityNED
        return AutopilotSensors(altitude: s.altitude, heightAboveGround: s.altitude - 1.25, verticalSpeed: -v.z,
                                indicatedAirspeed: out.calibratedAirspeed, groundSpeed: (v.x * v.x + v.y * v.y).squareRoot(),
                                heading: e.yaw, track: atan2(v.y, v.x), pitch: e.pitch, roll: e.roll,
                                pitchRate: s.bodyRates.y, rollRate: s.bodyRates.x, yawRate: s.bodyRates.z)
    }

    public func fly(maxSeconds: Double = 900, dt: Double = 1.0 / 120) -> CircuitReport {
        var report = CircuitReport()
        var s = AircraftState(positionNED: SIMD3(0, 0, -1.20), velocityBody: .zero, attitude: .identity, bodyRates: .zero)
        var ap = Autopilot()
        var phase = CircuitPhase.takeoffRoll
        var wp = 0
        var inputs = ControlInputs()
        var onGroundTime = 0.0
        func setPhase(_ p: CircuitPhase, _ t: Double) { phase = p; report.phaseLog.append((t, p)) }
        report.phaseLog.append((0, phase))
        var steps = 0
        let maxSteps = Int(maxSeconds / dt)
        while steps < maxSteps && phase != .stopped {
            steps += 1
            let out = model.outputs(s, inputs: inputs, environment: environment)
            let sen = sensors(s, out)
            let t = s.time
            switch phase {
            case .takeoffRoll:
                inputs = ControlInputs(elevator: 0, aileron: 0, rudder: clamp(-2 * s.positionNED.y - 0.5 * s.velocityNED.y, -1, 1) * 0.3, throttle: 1, flaps: 0.3)
                if out.calibratedAirspeed > 27 { setPhase(.rotate, t) }
            case .rotate:
                ap.lateral = .headingHold(0); ap.vertical = .pitchHold(9 * Units.degToRad); ap.targetSpeed = nil
                let c = ap.update(sen, dt: dt)
                inputs = ControlInputs(elevator: c.elevator, aileron: c.aileron, rudder: c.rudder, throttle: 1, flaps: 0.3)
                if sen.heightAboveGround > 15 { setPhase(.climb, t) }
            case .climb:
                ap.lateral = .headingHold(0); ap.vertical = .verticalSpeed(3.5); ap.targetSpeed = nil
                let c = ap.update(sen, dt: dt)
                inputs = ControlInputs(elevator: c.elevator, aileron: c.aileron, rudder: c.rudder, throttle: 1, flaps: sen.heightAboveGround > 120 ? 0 : 0.3)
                if sen.altitude > patternAltitude * 0.6 { setPhase(.circuit, t) }
            case .circuit:
                let target = waypoints[wp]
                let d = target - SIMD2(s.positionNED.x, s.positionNED.y)
                if (d * d).sum().squareRoot() < 350 {
                    wp += 1
                    if wp == waypoints.count { setPhase(.approach, t); ap = Autopilot(); break }
                }
                let tgt = waypoints[min(wp, waypoints.count - 1)] - SIMD2(s.positionNED.x, s.positionNED.y)
                ap.lateral = .trackHold(atan2(tgt.y, tgt.x))
                ap.vertical = .altitudeHold(patternAltitude)
                ap.targetSpeed = wp >= 3 ? approachSpeed + 5 : cruiseSpeed
                let c = ap.update(sen, dt: dt)
                inputs = ControlInputs(elevator: c.elevator, aileron: c.aileron, rudder: c.rudder, throttle: c.throttle, flaps: wp >= 3 ? 0.5 : 0)
            case .approach:
                // Localizer: track toward the extended centre-line with cross-track correction.
                let crossTrack = s.positionNED.y               // east of centre-line positive
                let trackCmd = clamp(-crossTrack * 0.004 - s.velocityNED.y * 0.0, -0.6, 0.6)
                ap.lateral = .trackHold(trackCmd)
                // Glide path: 3° to an aim point 250 m past the threshold.
                let distToAim = 250 - s.positionNED.x
                let pathAlt = max(0, distToAim) * tan(3 * Units.degToRad) + 1.25
                let vsCmd = -sen.groundSpeed * tan(3 * Units.degToRad) + 0.25 * (pathAlt - sen.altitude)
                ap.vertical = .verticalSpeed(vsCmd)
                ap.targetSpeed = approachSpeed
                ap.pitchBias = 0.0
                let c = ap.update(sen, dt: dt)
                inputs = ControlInputs(elevator: c.elevator, aileron: c.aileron, rudder: c.rudder, throttle: c.throttle, flaps: 1)
                if sen.heightAboveGround < 9 && s.positionNED.x > -400 { setPhase(.flare, t) }
            case .flare:
                ap.lateral = .trackHold(clamp(-s.positionNED.y * 0.004, -0.3, 0.3))
                ap.vertical = .verticalSpeed(max(-0.9, -0.12 * sen.heightAboveGround - 0.3))
                ap.targetSpeed = nil
                let c = ap.update(sen, dt: dt)
                inputs = ControlInputs(elevator: c.elevator, aileron: c.aileron, rudder: c.rudder, throttle: 0, flaps: 1)
                if out.weightOnWheels {
                    report.touchdownVerticalSpeedFPM = sen.verticalSpeed / Units.fpmToMps
                    report.touchdownPosition = s.positionNED
                    report.touchdownTime = t
                    setPhase(.rollout, t)
                }
            case .rollout:
                let yawErr = Autopilot.wrapAngle(0 - sen.heading)
                let steer = clamp(2.5 * yawErr - 0.02 * s.positionNED.y, -1, 1)
                inputs = ControlInputs(elevator: -0.2, aileron: 0, rudder: steer, throttle: 0, flaps: 1, brakes: out.calibratedAirspeed < 25 ? 1 : 0.4)
                if (s.velocityNED * s.velocityNED).sum().squareRoot() < 0.3 { onGroundTime += dt } else { onGroundTime = 0 }
                if onGroundTime > 1 { setPhase(.stopped, t); report.stopPosition = s.positionNED }
            case .stopped:
                break
            }
            s = model.step(s, inputs: inputs, environment: environment, dt: dt)
            report.maxAltitude = max(report.maxAltitude, s.altitude)
            report.maxBankDegrees = max(report.maxBankDegrees, abs(s.attitude.euler.roll) * Units.radToDeg)
            if !s.isFinite { report.finite = false; break }
        }
        report.finalPhase = phase
        report.duration = s.time
        return report
    }
}
