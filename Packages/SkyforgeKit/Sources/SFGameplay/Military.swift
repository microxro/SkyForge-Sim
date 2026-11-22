// SKYFORGE — Apache-2.0
// Military flight: AI aircraft, a simulated cannon and heat-seeking missile against drones and
// bogeys, target lock, and formation geometry. All of it is deterministic (no wall clock, a seeded
// generator for gun dispersion) so missions replay identically and tests need no tolerances for luck.
// NED axes throughout: x north, y east, z down.
import Foundation
import SFMath
import SFAtmosphere

// MARK: - AI aircraft

public enum TargetBehavior: Sendable, Codable, Equatable {
    case straight                                       // hold heading, speed and altitude
    case orbit(turnRate: Double)                        // constant-rate turn (rad/s, positive = right)
    case route(points: [SIMD3<Double>], loop: Bool)     // fly NED waypoints
    case evade(maxTurnRate: Double)                     // turn hard away from the threat inside 5 km, weaving
}

public enum TargetRole: String, Sendable, Codable {
    case hostile, neutral, friendly
}

public struct AITarget: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var role: TargetRole
    public var position: SIMD3<Double>      // NED, m
    public var heading: Double              // rad from north, clockwise
    public var flightPath: Double = 0       // rad, climb positive
    public var speed: Double                // m/s
    public var radius: Double = 7           // m, hit sphere
    public var health: Double = 10
    public var behavior: TargetBehavior
    public var routeIndex: Int = 0
    public var weavePhase: Double = 0

    public init(id: String, role: TargetRole, position: SIMD3<Double>, heading: Double, speed: Double,
                behavior: TargetBehavior = .straight, health: Double = 10, radius: Double = 7) {
        self.id = id; self.role = role; self.position = position; self.heading = heading
        self.speed = speed; self.behavior = behavior; self.health = health; self.radius = radius
    }

    /// A NaN health counts as destroyed, so corrupt data cannot make an invulnerable target.
    public var destroyed: Bool { !(health > 0) }
    public var altitude: Double { -position.z }

    public var velocity: SIMD3<Double> {
        let c = cos(flightPath)
        return SIMD3(cos(heading) * c * speed, sin(heading) * c * speed, -sin(flightPath) * speed)
    }

    static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x < -.pi { x += 2 * .pi }
        return x
    }

    /// Turn toward `bearing`, limited to `rate` rad/s.
    private mutating func steer(toward bearing: Double, rate: Double, dt: Double) {
        let d = Self.wrap(bearing - heading)
        heading = Self.wrap(heading + max(-rate * dt, min(rate * dt, d)))
    }

    /// Advance one step. `threat` is the position of whatever the target is avoiding, if any.
    public mutating func step(dt: Double, threat: SIMD3<Double>? = nil) {
        guard !destroyed else { return }
        switch behavior {
        case .straight:
            break
        case .orbit(let turnRate):
            heading = Self.wrap(heading + turnRate * dt)
        case .route(let points, let loop):
            if !points.isEmpty {
                let wp = points[max(0, min(routeIndex, points.count - 1))]
                let d = wp - position
                let horizontal = (d.x * d.x + d.y * d.y).squareRoot()
                if horizontal < 400 {
                    if routeIndex + 1 < points.count { routeIndex += 1 } else if loop { routeIndex = 0 }
                }
                steer(toward: atan2(d.y, d.x), rate: 0.12, dt: dt)
                let climbWanted = atan2(-d.z, max(1, horizontal))
                flightPath += max(-0.4 * dt, min(0.4 * dt, max(-0.17, min(0.17, climbWanted)) - flightPath))
            }
        case .evade(let maxTurn):
            weavePhase += dt
            if let t = threat {
                let d = position - t
                if (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() < 5_000 {
                    // Break perpendicular to the line of sight, flipping direction every 6 s.
                    let los = atan2(d.y, d.x)
                    let side: Double = Int(weavePhase / 6) % 2 == 0 ? 1 : -1
                    steer(toward: los + side * .pi / 2, rate: maxTurn, dt: dt)
                }
            }
        }
        position += velocity * dt
    }
}

// MARK: - Weapons

public enum WeaponKind: String, Sendable, Codable, CaseIterable {
    case cannon, heatMissile

    public var displayName: String { self == .cannon ? "Cannon" : "Heat-seeking missile" }
}

/// Ownship kinematics the weapon system needs.
public struct Ownship: Sendable, Equatable {
    public var position: SIMD3<Double>
    public var velocity: SIMD3<Double>
    public var forward: SIMD3<Double>       // unit vector along the nose, NED
    public init(position: SIMD3<Double>, velocity: SIMD3<Double>, forward: SIMD3<Double>) {
        self.position = position; self.velocity = velocity; self.forward = forward
    }
}

public struct WeaponInput: Sendable, Equatable {
    public var fireGun = false
    public var launchMissile = false
    public var cycleTarget = false
    public init(fireGun: Bool = false, launchMissile: Bool = false, cycleTarget: Bool = false) {
        self.fireGun = fireGun; self.launchMissile = launchMissile; self.cycleTarget = cycleTarget
    }
}

public enum WeaponEvent: Sendable, Equatable {
    case missileLaunched
    case hit(targetID: String, weapon: WeaponKind)
    case destroyed(targetID: String, weapon: WeaponKind)
    case missileMissed
    case lockAcquired(targetID: String)
    case lockLost
}

public enum LockState: Sendable, Equatable {
    case none
    case acquiring(targetID: String, progress: Double)    // 0...1
    case locked(targetID: String)
}

struct Projectile: Sendable, Equatable {
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>
    var age = 0.0
}

struct Missile: Sendable, Equatable {
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>
    var targetID: String
    var age = 0.0
}

/// Cannon, missiles and seeker for one aircraft. Rounds and missiles hit any aircraft, friendly or
/// not; the mission fails when a friendly or neutral aircraft is destroyed.
public struct WeaponSystem: Sendable {
    public private(set) var cannonRounds: Int
    public private(set) var missilesRemaining: Int
    public private(set) var lock: LockState = .none
    public private(set) var selectedTarget: String?
    public let kinds: [WeaponKind]
    var projectiles: [Projectile] = []
    var missiles: [Missile] = []
    private var gunAccumulator = 0.0
    private var missileCooldown = 0.0
    private var lockGrace = 0.0
    private var previousCycle = false
    private var rng: UInt64

    // Tuning
    public static let muzzleSpeed = 1_000.0
    public static let roundsPerSecond = 80.0
    public static let gunLife = 2.0
    public static let dispersion = 0.003                     // rad
    public static let seekerHalfAngle = 20.0 * Double.pi / 180
    public static let seekerRange = 8_000.0
    public static let lockTime = 1.5
    public static let missileBoostTime = 3.0
    public static let missileBoostAccel = 200.0
    public static let missileMaxSpeed = 850.0
    public static let missileMaxAccel = 300.0                // lateral, m/s^2 (about 30 g)
    public static let missileLife = 25.0
    public static let fuzeRadius = 15.0
    public static let navigationGain = 4.0
    public static let missileDamage = 10.0
    public static let gunDamage = 1.0

    public init(kinds: [WeaponKind], cannonRounds: Int = 500, missiles: Int = 4, seed: UInt64 = 0x5F3759DF) {
        self.kinds = kinds
        self.cannonRounds = kinds.contains(.cannon) ? cannonRounds : 0
        self.missilesRemaining = kinds.contains(.heatMissile) ? missiles : 0
        self.rng = seed == 0 ? 1 : seed
    }

    public var activeProjectiles: Int { projectiles.count }
    public var missilesInFlight: Int { missiles.count }

    private mutating func nextUnit() -> Double {
        // xorshift64*
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
        let r = rng &* 0x2545F4914F6CDD1D
        return Double(r >> 11) / Double(1 << 53)
    }

    /// Angle (rad) between the nose and the line of sight to a point.
    static func offBoresight(_ own: Ownship, to p: SIMD3<Double>) -> Double {
        let d = p - own.position
        let n = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
        guard n > 1e-6 else { return 0 }
        let c = (d.x * own.forward.x + d.y * own.forward.y + d.z * own.forward.z) / n
        return acos(max(-1, min(1, c)))
    }

    static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    // MARK: Update

    public mutating func update(dt: Double, ownship own: Ownship, input: WeaponInput, targets: inout [AITarget]) -> [WeaponEvent] {
        var events: [WeaponEvent] = []
        updateSelection(input: input, own: own, targets: targets)
        updateLock(dt: dt, own: own, targets: targets, events: &events)
        missileCooldown = max(0, missileCooldown - dt)

        if input.launchMissile, missilesRemaining > 0, missileCooldown == 0, case .locked(let id) = lock {
            missilesRemaining -= 1
            missileCooldown = 1.0
            missiles.append(Missile(position: own.position + SIMD3(0, 0, 2),
                                    velocity: own.velocity + own.forward * 50, targetID: id))
            events.append(.missileLaunched)
        }

        if input.fireGun, cannonRounds > 0 {
            gunAccumulator += Self.roundsPerSecond * dt
            while gunAccumulator >= 1, cannonRounds > 0 {
                gunAccumulator -= 1
                cannonRounds -= 1
                let jx = (nextUnit() - 0.5) * 2 * Self.dispersion, jy = (nextUnit() - 0.5) * 2 * Self.dispersion
                // Perturb the direction in a small cone around the nose.
                var dir = own.forward
                let up = abs(dir.z) < 0.95 ? SIMD3(0.0, 0.0, 1.0) : SIMD3(1.0, 0.0, 0.0)
                let side = normalize(cross(dir, up)), top = cross(side, dir)
                dir = normalize(dir + side * jx + top * jy)
                projectiles.append(Projectile(position: own.position + own.forward * 6,
                                              velocity: own.velocity + dir * Self.muzzleSpeed))
            }
        } else {
            gunAccumulator = 0
        }

        stepProjectiles(dt: dt, targets: &targets, events: &events)
        stepMissiles(dt: dt, targets: &targets, events: &events)
        return events
    }

    private mutating func updateSelection(input: WeaponInput, own: Ownship, targets: [AITarget]) {
        let live = targets.filter { !$0.destroyed && $0.role != .friendly }
        let edge = input.cycleTarget && !previousCycle
        previousCycle = input.cycleTarget
        if let s = selectedTarget, !live.contains(where: { $0.id == s }) { selectedTarget = nil }
        if edge, !live.isEmpty {
            let sorted = live.sorted { Self.distance($0.position, own.position) < Self.distance($1.position, own.position) }
            if let s = selectedTarget, let i = sorted.firstIndex(where: { $0.id == s }) {
                selectedTarget = sorted[(i + 1) % sorted.count].id
            } else {
                selectedTarget = sorted[0].id
            }
        } else if selectedTarget == nil {
            // Default: the live target nearest the nose.
            selectedTarget = live.min { Self.offBoresight(own, to: $0.position) < Self.offBoresight(own, to: $1.position) }?.id
        }
    }

    private mutating func updateLock(dt: Double, own: Ownship, targets: [AITarget], events: inout [WeaponEvent]) {
        guard kinds.contains(.heatMissile), let id = selectedTarget,
              let t = targets.first(where: { $0.id == id }), !t.destroyed else {
            if case .locked = lock { events.append(.lockLost) }
            lock = .none
            return
        }
        let inCone = Self.offBoresight(own, to: t.position) <= Self.seekerHalfAngle
            && Self.distance(own.position, t.position) <= Self.seekerRange
        switch lock {
        case .locked(let lockedID):
            if lockedID != id || !inCone {
                lockGrace += dt
                if lockedID != id || lockGrace > 1.0 {
                    events.append(.lockLost); lock = .none; lockGrace = 0
                }
            } else {
                lockGrace = 0
            }
        case .acquiring(let acquiringID, let p):
            if !inCone || acquiringID != id {
                lock = .none
            } else {
                let np = p + dt / Self.lockTime
                if np >= 1 { lock = .locked(targetID: id); events.append(.lockAcquired(targetID: id)); lockGrace = 0 }
                else { lock = .acquiring(targetID: id, progress: np) }
            }
        case .none:
            if inCone { lock = .acquiring(targetID: id, progress: dt / Self.lockTime) }
        }
    }

    private mutating func stepProjectiles(dt: Double, targets: inout [AITarget], events: inout [WeaponEvent]) {
        var alive: [Projectile] = []
        for var p in projectiles {
            let old = p.position
            p.velocity.z += ISA.g0 * dt
            p.position += p.velocity * dt
            p.age += dt
            var hit = false
            for i in targets.indices where !targets[i].destroyed {
                if Self.segmentDistance(old, p.position, targets[i].position) <= targets[i].radius {
                    targets[i].health -= Self.gunDamage
                    events.append(.hit(targetID: targets[i].id, weapon: .cannon))
                    if targets[i].destroyed { events.append(.destroyed(targetID: targets[i].id, weapon: .cannon)) }
                    hit = true
                    break
                }
            }
            if !hit && p.age < Self.gunLife { alive.append(p) }
        }
        projectiles = alive
    }

    /// Distance from point `c` to the segment a-b.
    static func segmentDistance(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z
        let t = len2 > 1e-12 ? max(0, min(1, dot(c - a, ab) / len2)) : 0
        return distance(a + ab * t, c)
    }

    private mutating func stepMissiles(dt: Double, targets: inout [AITarget], events: inout [WeaponEvent]) {
        var alive: [Missile] = []
        for var m in missiles {
            guard let ti = targets.firstIndex(where: { $0.id == m.targetID }), !targets[ti].destroyed else {
                events.append(.missileMissed); continue
            }
            let target = targets[ti]
            let r = target.position - m.position
            let rn = max(1.0, (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot())
            let rv = target.velocity - m.velocity
            // Proportional navigation: a = N * Vc * (Omega x v_hat).
            let omega = cross(r, rv) / (rn * rn)
            let closing = max(0, -dot(r / rn, rv))
            let speed = max(1.0, length(m.velocity))
            var accel = cross(omega, m.velocity / speed) * (Self.navigationGain * closing)
            let an = length(accel)
            if an > Self.missileMaxAccel { accel *= Self.missileMaxAccel / an }
            // Motor: boost along the velocity vector, then coast with drag.
            let along = m.velocity / speed
            if m.age < Self.missileBoostTime {
                if speed < Self.missileMaxSpeed { accel += along * Self.missileBoostAccel }
            } else {
                accel -= along * 12
            }
            let old = m.position
            m.velocity += accel * dt
            m.position += m.velocity * dt
            m.age += dt
            // Proximity fuze on the closest approach during this step.
            let miss = Self.segmentDistance(old, m.position, target.position)
            if miss <= Self.fuzeRadius {
                targets[ti].health -= Self.missileDamage
                events.append(.hit(targetID: target.id, weapon: .heatMissile))
                if targets[ti].destroyed { events.append(.destroyed(targetID: target.id, weapon: .heatMissile)) }
                continue
            }
            if m.age > Self.missileLife || (length(m.velocity) < 200 && m.age > Self.missileBoostTime) {
                events.append(.missileMissed); continue
            }
            alive.append(m)
        }
        missiles = alive
    }
}

// MARK: - Formation

public enum FormationSlot: String, Sendable, Codable, CaseIterable {
    case echelonRight, echelonLeft, lineAbreast, trail

    /// Offset from the leader in the leader's frame: x forward, y right, z down (m), for a given spacing.
    public func offset(spacing s: Double) -> SIMD3<Double> {
        switch self {
        case .echelonRight: return SIMD3(-s, s, 0)
        case .echelonLeft: return SIMD3(-s, -s, 0)
        case .lineAbreast: return SIMD3(0, s * 1.5, 0)
        case .trail: return SIMD3(-s * 1.5, 0, 0)
        }
    }
}

public enum FormationGeometry {
    /// World (NED) position of a slot behind a leader flying heading `heading`.
    public static func slotPosition(leaderPosition: SIMD3<Double>, heading: Double, slot: FormationSlot, spacing: Double) -> SIMD3<Double> {
        let o = slot.offset(spacing: spacing)
        let c = cos(heading), s = sin(heading)
        // forward = (c, s), right = (-s, c) in (north, east).
        return leaderPosition + SIMD3(o.x * c - o.y * s, o.x * s + o.y * c, o.z)
    }

    public static func error(ownship: SIMD3<Double>, leader: AITarget, slot: FormationSlot, spacing: Double) -> Double {
        WeaponSystem.distance(ownship, slotPosition(leaderPosition: leader.position, heading: leader.heading, slot: slot, spacing: spacing))
    }
}
