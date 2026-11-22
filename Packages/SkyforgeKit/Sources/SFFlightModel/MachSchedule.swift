// SKYFORGE — Apache-2.0
// Compressibility effects as a piecewise-linear schedule over Mach number: lift-curve slope, CLmax,
// wave drag, aerodynamic-centre (pitch stability) and control power multipliers. An empty schedule is
// incompressible flow, so low-speed aircraft are unchanged.
import Foundation

public struct MachSchedule: Sendable, Codable, Equatable {
    public struct Point: Sendable, Codable, Equatable {
        public var mach: Double
        public var liftSlope: Double       // multiplies CL-alpha
        public var clMax: Double           // multiplies CLmax
        public var waveDrag: Double        // added to CD
        public var pitchStability: Double  // multiplies Cm-alpha
        public var controlPower: Double    // multiplies elevator CL and Cm effectiveness
        public init(mach: Double, liftSlope: Double = 1, clMax: Double = 1, waveDrag: Double = 0,
                    pitchStability: Double = 1, controlPower: Double = 1) {
            self.mach = mach; self.liftSlope = liftSlope; self.clMax = clMax; self.waveDrag = waveDrag
            self.pitchStability = pitchStability; self.controlPower = controlPower
        }
    }

    /// Points sorted by ascending Mach.
    public var points: [Point]
    public init(points: [Point]) { self.points = points.sorted { $0.mach < $1.mach } }
    public static let incompressible = MachSchedule(points: [])

    public func evaluate(_ m: Double) -> Point {
        guard let first = points.first, let last = points.last else { return Point(mach: m) }
        if !m.isFinite || m <= first.mach { return first }
        if m >= last.mach { return last }
        var i = 1
        while i < points.count - 1 && points[i].mach < m { i += 1 }
        let a = points[i - 1], b = points[i]
        let t = (m - a.mach) / max(b.mach - a.mach, 1e-9)
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return Point(mach: m, liftSlope: l(a.liftSlope, b.liftSlope), clMax: l(a.clMax, b.clMax),
                     waveDrag: l(a.waveDrag, b.waveDrag), pitchStability: l(a.pitchStability, b.pitchStability),
                     controlPower: l(a.controlPower, b.controlPower))
    }
}

/// Post-stall behaviour. Defaults are neutral; light aircraft get a wing drop and mild autorotation,
/// swept-wing jets a stronger nose drop.
public struct StallBehavior: Sendable, Codable, Equatable {
    /// Fraction of the roll-damping derivative reversed past the stall (>1 drives autorotation).
    public var autorotation: Double
    /// Rolling-moment coefficient per rad of sideslip past the stall (wing drop).
    public var wingDropGain: Double
    /// Nose-down pitching-moment coefficient added past the stall.
    public var noseDrop: Double
    /// Angle (rad) before the stall break at which buffet and stall warning begin.
    public var buffetStartMargin: Double
    public init(autorotation: Double = 0, wingDropGain: Double = 0, noseDrop: Double = 0,
                buffetStartMargin: Double = 4 * Double.pi / 180) {
        self.autorotation = autorotation; self.wingDropGain = wingDropGain
        self.noseDrop = noseDrop; self.buffetStartMargin = buffetStartMargin
    }
    public static let neutral = StallBehavior()
}
