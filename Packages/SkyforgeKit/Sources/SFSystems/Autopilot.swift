// SKYFORGE — Apache-2.0
// Cascaded PID autopilot (ROL/HDG, PIT/VS/ALT, IAS via throttle) with anti-windup.
import Foundation
import SFMath

public struct PID: Sendable {
    public var kp: Double, ki: Double, kd: Double
    public var outputMin: Double, outputMax: Double
    public var integralLimit: Double
    public private(set) var integral = 0.0
    private var lastError: Double?

    public init(kp: Double, ki: Double = 0, kd: Double = 0, outputMin: Double = -1, outputMax: Double = 1, integralLimit: Double = 1) {
        self.kp = kp; self.ki = ki; self.kd = kd
        self.outputMin = outputMin; self.outputMax = outputMax; self.integralLimit = integralLimit
    }

    /// `derivative` may be supplied (e.g. a measured rate) to avoid derivative kick.
    public mutating func update(error e: Double, dt: Double, derivative: Double? = nil) -> Double {
        let d = derivative ?? (lastError.map { (e - $0) / dt } ?? 0)
        lastError = e
        let unclamped = kp * e + ki * integral + kd * d
        // Conditional integration (anti-windup): only integrate when not saturated in the error direction.
        let saturatedHigh = unclamped >= outputMax && e > 0, saturatedLow = unclamped <= outputMin && e < 0
        if !saturatedHigh && !saturatedLow {
            integral = clamp(integral + e * dt, -integralLimit, integralLimit)
        }
        return clamp(kp * e + ki * integral + kd * d, outputMin, outputMax)
    }

    public mutating func reset() { integral = 0; lastError = nil }
}

/// Measurements the autopilot needs (SI units, angles in radians, heading true).
public struct AutopilotSensors: Sendable {
    public var altitude: Double            // m (above datum)
    public var heightAboveGround: Double   // m
    public var verticalSpeed: Double       // m/s, up positive
    public var indicatedAirspeed: Double   // m/s
    public var groundSpeed: Double         // m/s
    public var heading: Double             // rad
    public var track: Double               // rad
    public var pitch: Double, roll: Double // rad
    public var pitchRate: Double, rollRate: Double, yawRate: Double
    public init(altitude: Double, heightAboveGround: Double, verticalSpeed: Double, indicatedAirspeed: Double, groundSpeed: Double,
                heading: Double, track: Double, pitch: Double, roll: Double, pitchRate: Double, rollRate: Double, yawRate: Double) {
        self.altitude = altitude; self.heightAboveGround = heightAboveGround; self.verticalSpeed = verticalSpeed
        self.indicatedAirspeed = indicatedAirspeed; self.groundSpeed = groundSpeed; self.heading = heading; self.track = track
        self.pitch = pitch; self.roll = roll; self.pitchRate = pitchRate; self.rollRate = rollRate; self.yawRate = yawRate
    }
}

public enum LateralMode: Sendable, Equatable {
    case rollHold(Double)
    case headingHold(Double)
    case trackHold(Double)
}

public enum VerticalMode: Sendable, Equatable {
    case pitchHold(Double)
    case verticalSpeed(Double)
    case altitudeHold(Double)
}

public struct AutopilotCommand: Sendable, Equatable {
    public var elevator: Double, aileron: Double, rudder: Double, throttle: Double
}

public struct Autopilot: Sendable {
    public var lateral: LateralMode = .rollHold(0)
    public var vertical: VerticalMode = .pitchHold(0.05)
    /// Target indicated airspeed (m/s); nil = autothrottle off.
    public var targetSpeed: Double? = nil
    public var maxBank = 25 * Units.degToRad
    public var maxVerticalSpeed = 4.0
    public var throttleMin = 0.0

    var rollPID = PID(kp: 1.6, ki: 0.15, kd: 0, outputMin: -1, outputMax: 1, integralLimit: 0.5)
    var pitchPID = PID(kp: 2.4, ki: 0.9, kd: 0, outputMin: -1, outputMax: 1, integralLimit: 0.6)
    var vsPID = PID(kp: 0.045, ki: 0.012, kd: 0, outputMin: -0.20, outputMax: 0.28, integralLimit: 4)
    var speedPID = PID(kp: 0.09, ki: 0.03, kd: 0, outputMin: 0, outputMax: 1, integralLimit: 15)
    var yawDamper = 0.5
    /// Trim pitch attitude used as the VS loop's feed-forward.
    public var pitchBias = 0.04

    public init() {}

    public static func wrapAngle(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

    public mutating func update(_ s: AutopilotSensors, dt: Double) -> AutopilotCommand {
        // Lateral: heading/track error -> bank command -> aileron.
        let bankCmd: Double
        switch lateral {
        case .rollHold(let r): bankCmd = r
        case .headingHold(let h): bankCmd = clamp(1.4 * Self.wrapAngle(h - s.heading), -maxBank, maxBank)
        case .trackHold(let t): bankCmd = clamp(1.4 * Self.wrapAngle(t - s.track), -maxBank, maxBank)
        }
        let aileron = rollPID.update(error: bankCmd - s.roll, dt: dt, derivative: -s.rollRate) - 0.25 * s.rollRate
        // Coordinated turn: rudder from yaw-rate damper plus a small bank feed-forward.
        let rudder = clamp(-yawDamper * (s.yawRate - ISAg0 * tan(s.roll) / max(s.indicatedAirspeed, 15)) * 2, -0.5, 0.5)

        // Vertical: altitude -> VS -> pitch -> elevator.
        var pitchCmd: Double
        switch vertical {
        case .pitchHold(let p): pitchCmd = p
        case .verticalSpeed(let vs):
            pitchCmd = pitchBias + vsPID.update(error: clamp(vs, -maxVerticalSpeed, maxVerticalSpeed) - s.verticalSpeed, dt: dt)
        case .altitudeHold(let alt):
            let vsCmd = clamp(0.12 * (alt - s.altitude), -maxVerticalSpeed, maxVerticalSpeed)
            pitchCmd = pitchBias + vsPID.update(error: vsCmd - s.verticalSpeed, dt: dt)
        }
        // Turn compensation: a little extra pitch in a bank.
        pitchCmd += 0.25 * (1 / max(cos(s.roll), 0.5) - 1)
        let elevator = pitchPID.update(error: pitchCmd - s.pitch, dt: dt, derivative: -s.pitchRate) - 0.35 * s.pitchRate

        var throttle = 0.6
        if let v = targetSpeed {
            throttle = max(throttleMin, speedPID.update(error: v - s.indicatedAirspeed, dt: dt))
        }
        return AutopilotCommand(elevator: elevator, aileron: aileron, rudder: rudder, throttle: throttle)
    }
}

let ISAg0 = 9.806_65
