// SKYFORGE — Apache-2.0
// AI dogfight steering: a hostile fighter that pursues and attacks the player aircraft. Pure functions
// of the current geometry (no stored state, no wall clock, no randomness), so a fight replays exactly.
// The fighter leads its turns, never turns faster than its turn-rate limit, and overshoots and then
// reverses through the target's tail instead of locking onto a perfect circle.
// NED axes throughout: x north, y east, z down. Heading is from north, clockwise; climb is positive.
import Foundation

public enum DogfightPhase: String, Sendable, Codable, CaseIterable {
    case lead, attack, overshoot
}

public struct DogfightSettings: Sendable, Equatable, Codable {
    public var maxTurnRate: Double          // rad/s, sustained
    public var maxClimbRate: Double         // rad/s of flight path change
    public var cruiseSpeed: Double          // m/s
    public var gunRange: Double             // m
    public var gunHalfAngle: Double         // rad
    public var missileRange: Double         // m
    public var missileHalfAngle: Double     // rad

    public init(maxTurnRate: Double = 0.2, maxClimbRate: Double = 0.1, cruiseSpeed: Double = 180,
                gunRange: Double = 1_200, gunHalfAngle: Double = 5.0 * .pi / 180,
                missileRange: Double = 6_000, missileHalfAngle: Double = 20.0 * .pi / 180) {
        self.maxTurnRate = maxTurnRate
        self.maxClimbRate = maxClimbRate
        self.cruiseSpeed = cruiseSpeed
        self.gunRange = gunRange
        self.gunHalfAngle = gunHalfAngle
        self.missileRange = missileRange
        self.missileHalfAngle = missileHalfAngle
    }
}

public struct DogfightCommand: Sendable, Equatable {
    public var heading: Double              // rad, new heading for the step
    public var flightPath: Double           // rad, new flight path for the step
    public var speed: Double                // m/s, commanded speed
    public var phase: DogfightPhase

    public init(heading: Double, flightPath: Double, speed: Double, phase: DogfightPhase) {
        self.heading = heading
        self.flightPath = flightPath
        self.speed = speed
        self.phase = phase
    }
}

public enum Dogfight {
    // Phase geometry.
    static let overshootRange: Double = 1_500                       // m
    static let overshootAngle: Double = 100.0 * Double.pi / 180     // rad off the nose
    static let attackRange: Double = 3_000                          // m
    static let attackAngle: Double = 60.0 * Double.pi / 180         // rad off the nose
    static let overshootSpeedFactor: Double = 1.25
    /// How far behind the target the overshoot reversal aims, so the fighter comes back through its tail.
    static let tailOffset: Double = 300                             // m
    /// The steepest climb or dive the fighter will command.
    static let maxFlightPathAngle: Double = 60.0 * Double.pi / 180  // rad

    // MARK: Lead point

    /// Where a shooter at `shooterPosition` with speed `shooterSpeed` must aim to hit a target moving at
    /// `targetVelocity` from `target`. Returns `target` when the speed is zero or the solution does not exist.
    public static func leadPoint(shooterPosition: SIMD3<Double>, shooterSpeed: Double,
                                 target: SIMD3<Double>, targetVelocity: SIMD3<Double>) -> SIMD3<Double> {
        guard shooterSpeed.isFinite, shooterSpeed > 0,
              allFinite(shooterPosition), allFinite(target), allFinite(targetVelocity) else { return target }
        // Solve |r + v t| = s t for the smallest t > 0:
        // (v.v - s^2) t^2 + 2 (r.v) t + r.r = 0
        let r: SIMD3<Double> = target - shooterPosition
        let c: Double = dot3(r, r)
        guard c > 1e-12 else { return target }
        let a: Double = dot3(targetVelocity, targetVelocity) - shooterSpeed * shooterSpeed
        let b: Double = 2 * dot3(r, targetVelocity)
        var t: Double = -1
        if abs(a) < 1e-9 {
            // Target as fast as the shot: linear, solvable only while closing.
            if b < 0 { t = -c / b }
        } else {
            let disc: Double = b * b - 4 * a * c
            guard disc >= 0 else { return target }
            let root: Double = disc.squareRoot()
            let t1: Double = (-b - root) / (2 * a)
            let t2: Double = (-b + root) / (2 * a)
            let lo: Double = min(t1, t2)
            let hi: Double = max(t1, t2)
            if lo > 0 { t = lo } else if hi > 0 { t = hi }
        }
        guard t.isFinite, t > 0 else { return target }
        let p: SIMD3<Double> = target + targetVelocity * t
        return allFinite(p) ? p : target
    }

    // MARK: Steering

    /// One step of pursuit. `own` is the fighter's current state, `target` the player's position NED,
    /// `targetVelocity` the player's velocity NED. Turns are limited to settings.maxTurnRate * dt per step, and
    /// the flight path is limited to settings.maxClimbRate * dt per step. The speed is cruiseSpeed in lead and
    /// attack, and 1.25 x cruiseSpeed in overshoot.
    public static func steer(own: AITarget, target: SIMD3<Double>, targetVelocity: SIMD3<Double>,
                             settings: DogfightSettings, dt: Double) -> DogfightCommand {
        let step: Double = (dt.isFinite && dt > 0) ? dt : 0
        let heading: Double = own.heading.isFinite ? wrapAngle(own.heading) : 0
        let flightPath: Double = own.flightPath.isFinite
            ? clampValue(own.flightPath, -Double.pi / 2, Double.pi / 2) : 0
        let cruise: Double = nonNegative(settings.cruiseSpeed)
        let turnRate: Double = nonNegative(settings.maxTurnRate)
        let climbRate: Double = nonNegative(settings.maxClimbRate)
        let tv: SIMD3<Double> = allFinite(targetVelocity) ? targetVelocity : SIMD3<Double>(0, 0, 0)

        // Nothing sensible to chase: hold the current heading and flight path.
        guard allFinite(own.position), allFinite(target) else {
            return DogfightCommand(heading: heading, flightPath: flightPath, speed: cruise, phase: .lead)
        }

        let nose: SIMD3<Double> = forward(heading: heading, flightPath: flightPath)
        let phase: DogfightPhase = choosePhase(position: own.position, nose: nose, target: target)

        let aim: SIMD3<Double>
        switch phase {
        case .lead:
            // Collision course at our own speed: cut the corner and let the target fly into the attack cone.
            aim = leadPoint(shooterPosition: own.position, shooterSpeed: cruise, target: target, targetVelocity: tv)
        case .attack:
            // Lead pursuit: put the nose where the rounds must go.
            aim = leadPoint(shooterPosition: own.position, shooterSpeed: bulletSpeed(own), target: target, targetVelocity: tv)
        case .overshoot:
            // Reverse hard and come back through the target's tail.
            aim = tailPoint(target: target, targetVelocity: tv)
        }

        let d: SIMD3<Double> = aim - own.position
        let horizontal: Double = (d.x * d.x + d.y * d.y).squareRoot()
        var desiredHeading: Double = heading
        var desiredPath: Double = flightPath
        if horizontal > 1e-6 {
            desiredHeading = atan2(d.y, d.x)
        }
        if horizontal > 1e-6 || abs(d.z) > 1e-6 {
            desiredPath = clampValue(atan2(-d.z, horizontal), -maxFlightPathAngle, maxFlightPathAngle)
        }
        if !desiredHeading.isFinite { desiredHeading = heading }
        if !desiredPath.isFinite { desiredPath = flightPath }

        // Turn the shorter way, no faster than the turn-rate limit.
        let maxTurn: Double = turnRate * step
        let headingError: Double = wrapAngle(desiredHeading - heading)
        var newHeading: Double = wrapAngle(heading + clampValue(headingError, -maxTurn, maxTurn))
        if !newHeading.isFinite { newHeading = heading }

        let maxClimb: Double = climbRate * step
        var newPath: Double = flightPath + clampValue(desiredPath - flightPath, -maxClimb, maxClimb)
        if !newPath.isFinite { newPath = flightPath }
        newPath = clampValue(newPath, -Double.pi / 2, Double.pi / 2)

        var speed: Double = phase == .overshoot ? cruise * overshootSpeedFactor : cruise
        if !speed.isFinite { speed = cruise }

        return DogfightCommand(heading: newHeading, flightPath: newPath, speed: speed, phase: phase)
    }

    // MARK: Firing solutions

    /// True when the target is inside gunRange and gunHalfAngle of the nose at the lead point.
    public static func gunSolution(own: AITarget, target: SIMD3<Double>, targetVelocity: SIMD3<Double>,
                                   settings: DogfightSettings) -> Bool {
        guard let g = solutionGeometry(own: own, target: target, targetVelocity: targetVelocity) else { return false }
        return g.range <= settings.gunRange && g.angle <= settings.gunHalfAngle
    }

    /// True when the target is inside missileRange and missileHalfAngle of the nose.
    public static func missileSolution(own: AITarget, target: SIMD3<Double>, targetVelocity: SIMD3<Double>,
                                       settings: DogfightSettings) -> Bool {
        guard let g = solutionGeometry(own: own, target: target, targetVelocity: targetVelocity) else { return false }
        return g.range <= settings.missileRange && g.angle <= settings.missileHalfAngle
    }

    // MARK: Helpers

    /// Phase from geometry alone: overshoot, then attack, then lead.
    static func choosePhase(position: SIMD3<Double>, nose: SIMD3<Double>, target: SIMD3<Double>) -> DogfightPhase {
        let range: Double = norm3(target - position)
        let angle: Double = offAngle(nose: nose, from: position, to: target)
        if range < overshootRange && angle > overshootAngle { return .overshoot }
        if range < attackRange || angle <= attackAngle { return .attack }
        return .lead
    }

    /// Range to the target and the angle between the nose and the gun lead point, or nil when the
    /// shooter is destroyed or the geometry is not finite.
    private static func solutionGeometry(own: AITarget, target: SIMD3<Double>,
                                         targetVelocity: SIMD3<Double>) -> (range: Double, angle: Double)? {
        guard !own.destroyed, own.heading.isFinite, own.flightPath.isFinite,
              allFinite(own.position), allFinite(target) else { return nil }
        let tv: SIMD3<Double> = allFinite(targetVelocity) ? targetVelocity : SIMD3<Double>(0, 0, 0)
        let nose: SIMD3<Double> = forward(heading: own.heading, flightPath: own.flightPath)
        let aim: SIMD3<Double> = leadPoint(shooterPosition: own.position, shooterSpeed: bulletSpeed(own),
                                           target: target, targetVelocity: tv)
        let range: Double = norm3(target - own.position)
        let angle: Double = offAngle(nose: nose, from: own.position, to: aim)
        guard range.isFinite, angle.isFinite else { return nil }
        return (range: range, angle: angle)
    }

    /// Speed of a cannon round over the ground: the fighter's speed plus the muzzle speed.
    private static func bulletSpeed(_ own: AITarget) -> Double {
        let ownSpeed: Double = nonNegative(own.speed)
        let s: Double = ownSpeed + WeaponSystem.muzzleSpeed
        return s.isFinite ? s : WeaponSystem.muzzleSpeed
    }

    /// A point `tailOffset` behind the target along its velocity, or the target itself when it is stopped.
    private static func tailPoint(target: SIMD3<Double>, targetVelocity: SIMD3<Double>) -> SIMD3<Double> {
        let speed: Double = norm3(targetVelocity)
        guard speed.isFinite, speed > 1e-6 else { return target }
        let p: SIMD3<Double> = target - targetVelocity * (tailOffset / speed)
        return allFinite(p) ? p : target
    }

    /// Unit vector along the nose, NED, for a heading and a flight path (climb positive, so z is negative).
    private static func forward(heading: Double, flightPath: Double) -> SIMD3<Double> {
        let c: Double = cos(flightPath)
        return SIMD3<Double>(cos(heading) * c, sin(heading) * c, -sin(flightPath))
    }

    /// Angle (rad) between the unit `nose` and the line of sight from `from` to `to`. Zero when the
    /// points coincide; pi when the geometry is not finite, so a bad input never reads as "on the nose".
    private static func offAngle(nose: SIMD3<Double>, from: SIMD3<Double>, to: SIMD3<Double>) -> Double {
        let d: SIMD3<Double> = to - from
        let n: Double = norm3(d)
        guard n.isFinite else { return Double.pi }
        guard n > 1e-6 else { return 0 }
        let c: Double = dot3(d, nose) / n
        guard c.isFinite else { return Double.pi }
        return acos(clampValue(c, -1, 1))
    }

    /// Wrap an angle into -pi...pi. A non-finite angle becomes 0.
    private static func wrapAngle(_ a: Double) -> Double {
        guard a.isFinite else { return 0 }
        var x: Double = a.truncatingRemainder(dividingBy: 2 * Double.pi)
        if x > Double.pi { x -= 2 * Double.pi }
        if x < -Double.pi { x += 2 * Double.pi }
        return x
    }

    private static func clampValue(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, x))
    }

    /// A finite, non-negative value, or 0.
    private static func nonNegative(_ x: Double) -> Double {
        (x.isFinite && x > 0) ? x : 0
    }

    private static func dot3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func norm3(_ a: SIMD3<Double>) -> Double {
        (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
    }

    private static func allFinite(_ a: SIMD3<Double>) -> Bool {
        a.x.isFinite && a.y.isFinite && a.z.isFinite
    }
}
