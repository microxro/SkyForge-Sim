// SKYFORGE — Apache-2.0
// What the instruments show, and the pitot-static / gyro models that produce it from the
// flight model's truth (§12). Indications lag and err the way the real systems do.
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel

/// Values as indicated in the cockpit (not truth).
public struct InstrumentData: Sendable, Equatable {
    public var indicatedAirspeedKt: Double = 0
    public var trueAirspeedKt: Double = 0
    public var indicatedAltitudeFt: Double = 0
    public var verticalSpeedFpm: Double = 0
    public var pitchDeg: Double = 0
    public var rollDeg: Double = 0
    public var headingDeg: Double = 0          // magnetic = true for now (no variation model yet)
    public var turnRateDegPerSec: Double = 0   // + right
    public var slipBall: Double = 0            // −1 … +1 tube half-width, + ball right
    public var rpm: Double = 0
    public var kollsmanInHg: Double = 29.92
    public var flapsFraction: Double = 0
    public var groundSpeedKt: Double = 0
    public init() {}
}

/// Speed limits drawn on the ASI arcs and the PFD speed tape (KIAS).
public struct VSpeeds: Sendable, Equatable {
    public var vso: Double, vs1: Double, vfe: Double, vno: Double, vne: Double, vx: Double, vy: Double, vr: Double
    /// SF-1 Trainer. Vso/Vs1 follow `FlightModel.designStallSpeed` at sea level (tested);
    /// the structural limits are SKYFORGE design values for this original aircraft.
    public static let sf1Trainer = VSpeeds(vso: 43, vs1: 49, vfe: 95, vno: 125, vne: 158, vx: 60, vy: 72, vr: 55)
}

/// Pitot-static system + gyros with first-order lags.
public struct InstrumentSystem: Sendable {
    public var data = InstrumentData()
    public var kollsmanInHg: Double = 29.92
    /// Blocked static port freezes altimeter and VSI; blocked pitot (with drain) reads zero.
    public var staticBlocked = false
    public var pitotBlocked = false

    private var vsiState: Double = 0
    private var asiState: Double = 0
    private var lastHeading: Double?
    private var turnState: Double = 0
    private var ballState: Double = 0
    private var frozenStatic: Double?
    private var lastAltitudeFt: Double?

    public static let vsiLag = 1.8          // s, diaphragm + calibrated leak
    public static let asiLag = 0.15
    public static let turnLag = 0.8
    public static let ballLag = 0.35

    public init() {}

    public static func inHgToPa(_ v: Double) -> Double { v * 3_386.389 }

    public mutating func update(state s: AircraftState, outputs o: FlightOutputs, environment env: FlightEnvironment,
                                inputs: ControlInputs, rpm: Double, dt: Double,
                                mass: Double = AircraftConfig.sf1Trainer.mass) {
        let alt = s.altitude
        let atm = ISA.state(geometricAltitude: env.originHeight + alt, temperatureOffset: env.temperatureOffset)
        // Static pressure source (blockage freezes it).
        var pStatic = atm.pressure
        if staticBlocked { pStatic = frozenStatic ?? pStatic; frozenStatic = pStatic } else { frozenStatic = nil }
        let indAltM = ISA.indicatedAltitude(staticPressure: pStatic, qnh: Self.inHgToPa(kollsmanInHg))
            + ISA.pressureAltitude(pressure: ISA.seaLevelPressure)
        let indAltFt = indAltM / Units.feetToMetres

        // ASI: impact pressure through the pitot; CAS from the flight model is the clean reading.
        let casKt = pitotBlocked ? 0 : o.calibratedAirspeed / Units.knotsToMps
        let k = dt > 0 ? 1 - exp(-dt / Self.asiLag) : 1
        asiState += (casKt - asiState) * k
        // VSI: rate of indicated altitude through a lag.
        var rate = 0.0
        if let last = lastAltitudeFt, dt > 0 { rate = (indAltFt - last) / dt * 60 }
        lastAltitudeFt = indAltFt
        vsiState += (rate - vsiState) * (dt > 0 ? 1 - exp(-dt / Self.vsiLag) : 1)

        let e = s.attitude.euler
        var hdg = e.yaw * 180 / .pi
        if hdg < 0 { hdg += 360 }
        var turn = 0.0
        if let lh = lastHeading, dt > 0 {
            var d = hdg - lh
            if d > 180 { d -= 360 }; if d < -180 { d += 360 }
            turn = d / dt
        }
        lastHeading = hdg
        turnState += (turn - turnState) * (dt > 0 ? 1 - exp(-dt / Self.turnLag) : 1)
        // Inclinometer: the ball sits along apparent gravity (minus specific force) in the
        // body y-z plane; the tube spans ±16° of that angle.
        let gravityBody = s.attitude.conjugate.rotate(SIMD3(0, 0, mass * ISA.g0))
        let f = (o.forceBody - gravityBody) / mass
        let ballAngle = atan2(-f.y, max(0.05, -f.z)) * 180 / .pi
        let ballTarget = max(-1, min(1, ballAngle / 16))
        ballState += (ballTarget - ballState) * (dt > 0 ? 1 - exp(-dt / Self.ballLag) : 1)

        let vNED = s.velocityNED
        data.indicatedAirspeedKt = max(0, asiState)
        data.trueAirspeedKt = o.trueAirspeed / Units.knotsToMps
        data.indicatedAltitudeFt = indAltFt
        data.verticalSpeedFpm = vsiState
        data.pitchDeg = e.pitch * 180 / .pi
        data.rollDeg = e.roll * 180 / .pi
        data.headingDeg = hdg
        data.turnRateDegPerSec = turnState
        data.slipBall = ballState
        data.rpm = rpm
        data.kollsmanInHg = kollsmanInHg
        data.flapsFraction = inputs.flaps
        data.groundSpeedKt = (vNED.x * vNED.x + vNED.y * vNED.y).squareRoot() / Units.knotsToMps
    }
}

/// Fixed-pitch propeller speed: absorbed power P = Cp(J) ρ n³ D⁵ with a linear Cp(J) fit,
/// solved by fixed-point iteration. Idle is modelled as 6 % of rated power.
public enum PropellerRPM {
    public static func rpm(throttle: Double, trueAirspeed v: Double, density rho: Double,
                           config c: AircraftConfig = .sf1Trainer) -> Double {
        let sigma = rho / ISA.seaLevelDensity
        let power = c.maxPower * max(0.06, min(1, throttle)) * pow(sigma, 1.1)
        let d5 = pow(c.propDiameter, 5)
        var n = 40.0  // rev/s
        for _ in 0..<12 {
            let j = max(0, v) / (n * c.propDiameter)
            let cp = max(0.012, 0.065 - 0.03 * j)
            n = pow(power / (rho * cp * d5), 1.0 / 3.0)
        }
        return min(c.maxRPM * 1.08, n * 60)
    }
}

/// The real flight model flown by a small bank/pitch hold into a climbing turn that reverses
/// every 40 s. Drives the committed instrument previews, the tests and the in-app demo, so the
/// instruments always show simulated flight.
public struct InstrumentScenario: Sendable {
    public let model = FlightModel(config: .sf1Trainer)
    public let environment = FlightEnvironment()
    public private(set) var state: AircraftState
    public private(set) var inputs: ControlInputs
    public private(set) var system = InstrumentSystem()
    public var bankDeg: Double
    public var targetPitchDeg = 4.0
    public var reverseEvery: Double?
    private let trimElevator: Double

    public init(bankDeg: Double = 20, kollsmanInHg: Double = 29.92, reverseEvery: Double? = nil) {
        let trim = model.trimLevel(trueAirspeed: 95 * Units.knotsToMps, altitude: 2_500 * Units.feetToMetres, environment: environment)
        state = trim.state
        inputs = trim.inputs
        inputs.throttle = min(1, trim.inputs.throttle + 0.25)
        trimElevator = trim.inputs.elevator
        self.bankDeg = bankDeg
        self.reverseEvery = reverseEvery
        system.kollsmanInHg = kollsmanInHg
    }

    public var data: InstrumentData { system.data }

    public mutating func step(dt: Double = 1.0 / 120) {
        if let period = reverseEvery, period > 0 {
            let phase = Int(state.time / period)
            bankDeg = abs(bankDeg) * (phase % 2 == 0 ? 1 : -1)
        }
        let e = state.attitude.euler
        let roll = e.roll * 180 / .pi, pitch = e.pitch * 180 / .pi
        inputs.aileron = max(-1, min(1, 0.03 * (bankDeg - roll) - 0.15 * state.bodyRates.x))
        inputs.elevator = max(-1, min(1, trimElevator + 0.04 * (targetPitchDeg - pitch) - 0.3 * state.bodyRates.y))
        let out = model.outputs(state, inputs: inputs, environment: environment)
        let rho = ISA.state(geometricAltitude: state.altitude).density
        system.update(state: state, outputs: out, environment: environment, inputs: inputs,
                      rpm: PropellerRPM.rpm(throttle: inputs.throttle, trueAirspeed: out.trueAirspeed, density: rho), dt: dt)
        state = model.step(state, inputs: inputs, environment: environment, dt: dt)
    }

    public static func climbingTurn(seconds: Double = 25, bankDeg: Double = 20, kollsmanInHg: Double = 29.92) -> InstrumentData {
        var s = InstrumentScenario(bankDeg: bankDeg, kollsmanInHg: kollsmanInHg)
        for _ in 0..<Int(seconds * 120) { s.step() }
        return s.data
    }
}
