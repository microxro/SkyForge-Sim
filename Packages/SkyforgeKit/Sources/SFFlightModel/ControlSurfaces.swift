// SKYFORGE — Apache-2.0
// Control-surface angles for the aircraft model: how far each surface is deflected for the pilot's inputs.
// Pure maths, so the renderer and the tests share one mapping. Angles are radians. Positive means the trailing
// edge goes down (ailerons, elevator, flaps) or to the right (rudder).
import Foundation

public struct ControlSurfaceAngles: Sendable, Equatable {
    public var leftAileron: Double
    public var rightAileron: Double
    public var elevator: Double
    public var rudder: Double
    public var flap: Double

    public static let neutral = ControlSurfaceAngles(leftAileron: 0, rightAileron: 0, elevator: 0, rudder: 0, flap: 0)

    public init(leftAileron: Double, rightAileron: Double, elevator: Double, rudder: Double, flap: Double) {
        self.leftAileron = leftAileron; self.rightAileron = rightAileron
        self.elevator = elevator; self.rudder = rudder; self.flap = flap
    }
}

public enum ControlSurfaces {
    /// The surface angles for `inputs` on `config`. Each input is clamped to its range first, so a stick past
    /// full deflection cannot move a surface past its stop. A non-finite input counts as neutral.
    public static func angles(for inputs: ControlInputs, config: AircraftConfig) -> ControlSurfaceAngles {
        let aileron = clamp(inputs.aileron, -1, 1) * config.aileronMax
        let elevator = clamp(inputs.elevator, -1, 1) * config.elevatorMax
        let rudder = clamp(inputs.rudder, -1, 1) * config.rudderMax
        let flap = clamp(inputs.flaps, 0, 1) * config.flapMax
        return ControlSurfaceAngles(
            // Right roll (+1): the right aileron goes up and the left one goes down.
            leftAileron: aileron,
            rightAileron: -aileron,
            // Stick back (+1) raises the nose, which takes the elevator's trailing edge up.
            elevator: -elevator,
            // Right yaw (+1): the rudder's trailing edge goes left.
            rudder: -rudder,
            flap: flap)
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        x.isFinite ? min(hi, max(lo, x)) : 0
    }
}
