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
    case dogfight(DogfightSettings)                     // pursue and attack the threat (see Dogfight.steer)
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

    /// Advance one step. `threat` is the position of whatever the target is avoiding (or, for a dogfight
    /// target, attacking), if any; `threatVelocity` is its velocity NED, used only by `.dogfight`.
    public mutating func step(dt: Double, threat: SIMD3<Double>? = nil, threatVelocity: SIMD3<Double> = .zero) {
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
        case .dogfight(let s):
            // With no threat the aim point is our own position, so the steering law holds heading and
            // flight path (it still commands cruise speed).
            let command: DogfightCommand = Dogfight.steer(own: self, target: threat ?? position,
                                                          targetVelocity: threatVelocity, settings: s, dt: dt)
            heading = command.heading
            flightPath = command.flightPath
            speed = command.speed
        }
        position += velocity * dt
    }
}

// MARK: - Weapons

public enum WeaponKind: String, Sendable, Codable, CaseIterable {
    case cannon, heatMissile, radarMissile

    public var displayName: String {
        switch self {
        case .cannon: return "Cannon"
        case .heatMissile: return "Heat-seeking missile"
        case .radarMissile: return "Radar missile"
        }
    }
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
    public var launchRadarMissile = false       // edge-triggered; needs a radar lock
    public init(fireGun: Bool = false, launchMissile: Bool = false, cycleTarget: Bool = false,
                launchRadarMissile: Bool = false) {
        self.fireGun = fireGun; self.launchMissile = launchMissile; self.cycleTarget = cycleTarget
        self.launchRadarMissile = launchRadarMissile
    }
}

public enum WeaponEvent: Sendable, Equatable {
    case missileLaunched
    case hit(targetID: String, weapon: WeaponKind)
    case destroyed(targetID: String, weapon: WeaponKind)
    case missileMissed
    case lockAcquired(targetID: String)
    case lockLost
    case radarMissileLaunched
    case decoyed(weapon: WeaponKind, decoy: Decoy.Kind)
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
    var kind: WeaponKind = .heatMissile
    /// Set once chaff has blocked this (radar) missile's line of sight and the decoy roll was drawn.
    var chaffChecked = false
}

/// Cannon, missiles and seeker for one aircraft. Rounds and missiles hit any aircraft, friendly or
/// not; the mission fails when a friendly or neutral aircraft is destroyed.
public struct WeaponSystem: Sendable {
    public private(set) var cannonRounds: Int
    public private(set) var missilesRemaining: Int
    public private(set) var radarMissilesRemaining: Int
    public private(set) var lock: LockState = .none
    public private(set) var selectedTarget: String?
    public let kinds: [WeaponKind]
    var projectiles: [Projectile] = []
    var missiles: [Missile] = []
    private var gunAccumulator = 0.0
    private var missileCooldown = 0.0
    private var lockGrace = 0.0
    private var previousCycle = false
    private var radarMissileCooldown = 0.0
    private var previousRadarLaunch = false
    private var rng: UInt64             // gun dispersion only
    private var missileRng: UInt64      // decoy rolls only, so the gun sequence never depends on decoys

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
    public static let missileCoastDrag = 12.0                // m/s^2 after burnout
    public static let missileMinSpeed = 200.0                // m/s; slower than this after burnout is a miss
    public static let missileLaunchCooldown = 1.0            // s between launches of one kind
    public static let missileLaunchSpeed = 50.0              // m/s added along the nose at launch
    public static let missileLaunchDrop = 2.0                // m below the ownship at launch
    // Radar missile: same guidance constants, a longer motor and a 60 km class launch range.
    public static let radarMissileRange = 60_000.0
    public static let radarMissileLife = 25.0
    public static let radarMissileBoostTime = 6.0
    public static let radarMissileMaxSpeed = 1_300.0
    // Decoys.
    public static let chaffBeamHalfAngle = 0.1               // rad
    public static let chaffDecoyChance = 0.75
    /// Offset that seeds the decoy generator from the same seed as the gun, without sharing its sequence.
    static let missileSeedOffset: UInt64 = 0x9E37_79B9_7F4A_7C15

    public init(kinds: [WeaponKind], cannonRounds: Int = 500, missiles: Int = 4, seed: UInt64 = 0x5F3759DF) {
        self.kinds = kinds
        self.cannonRounds = kinds.contains(.cannon) ? cannonRounds : 0
        self.missilesRemaining = kinds.contains(.heatMissile) ? missiles : 0
        self.radarMissilesRemaining = kinds.contains(.radarMissile) ? missiles : 0
        self.rng = seed == 0 ? 1 : seed
        let ms: UInt64 = seed &+ Self.missileSeedOffset
        self.missileRng = ms == 0 ? 1 : ms
    }

    public var activeProjectiles: Int { projectiles.count }
    public var missilesInFlight: Int { missiles.count }

    private mutating func nextUnit() -> Double {
        // xorshift64*
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
        let r = rng &* 0x2545F4914F6CDD1D
        return Double(r >> 11) / Double(1 << 53)
    }

    /// Decoy roll in 0..<1 from the missile generator (same xorshift64*, separate state).
    private mutating func nextMissileUnit() -> Double {
        missileRng = Self.xorshift(missileRng)
        let r: UInt64 = missileRng &* 0x2545F4914F6CDD1D
        return Double(r >> 11) / Double(UInt64(1) << 53)
    }

    static func xorshift(_ state: UInt64) -> UInt64 {
        var s: UInt64 = state
        s ^= s >> 12; s ^= s << 25; s ^= s >> 27
        return s
    }

    static func boostTime(for kind: WeaponKind) -> Double {
        switch kind {
        case .cannon, .heatMissile: return missileBoostTime
        case .radarMissile: return radarMissileBoostTime
        }
    }

    static func maxSpeed(for kind: WeaponKind) -> Double {
        switch kind {
        case .cannon, .heatMissile: return missileMaxSpeed
        case .radarMissile: return radarMissileMaxSpeed
        }
    }

    static func life(for kind: WeaponKind) -> Double {
        switch kind {
        case .cannon, .heatMissile: return missileLife
        case .radarMissile: return radarMissileLife
        }
    }

    /// One step of a proportional-navigation missile with a boost-then-coast motor. Shared by the
    /// player's heat and radar missiles and by hostile missiles. Returns the new position and velocity.
    static func guidedStep(position: SIMD3<Double>, velocity: SIMD3<Double>, age: Double,
                           targetPosition: SIMD3<Double>, targetVelocity: SIMD3<Double>,
                           boostTime: Double, maxSpeed: Double, dt: Double)
        -> (position: SIMD3<Double>, velocity: SIMD3<Double>) {
        let r: SIMD3<Double> = targetPosition - position
        let rn: Double = max(1.0, (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot())
        let rv: SIMD3<Double> = targetVelocity - velocity
        // Proportional navigation: a = N * Vc * (Omega x v_hat).
        let omega: SIMD3<Double> = cross(r, rv) / (rn * rn)
        let closing: Double = max(0, -dot(r / rn, rv))
        let speed: Double = max(1.0, length(velocity))
        var accel: SIMD3<Double> = cross(omega, velocity / speed) * (navigationGain * closing)
        let an: Double = length(accel)
        if an > missileMaxAccel { accel *= missileMaxAccel / an }
        // Motor: boost along the velocity vector, then coast with drag.
        let along: SIMD3<Double> = velocity / speed
        if age < boostTime {
            if speed < maxSpeed { accel += along * missileBoostAccel }
        } else {
            accel -= along * missileCoastDrag
        }
        let newVelocity: SIMD3<Double> = velocity + accel * dt
        let newPosition: SIMD3<Double> = position + newVelocity * dt
        return (position: newPosition, velocity: newVelocity)
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

    /// Steps the guns, seeker and missiles. `radarLockID` is the radar's locked target (RadarSet.lockedTargetID),
    /// needed to launch a radar missile. `decoys` are the live flares and chaff that can decoy missiles in flight.
    public mutating func update(dt: Double, ownship own: Ownship, input: WeaponInput, targets: inout [AITarget],
                                radarLockID: String? = nil, decoys: [Decoy] = []) -> [WeaponEvent] {
        var events: [WeaponEvent] = []
        updateSelection(input: input, own: own, targets: targets)
        updateLock(dt: dt, own: own, targets: targets, events: &events)
        missileCooldown = max(0, missileCooldown - dt)
        radarMissileCooldown = max(0, radarMissileCooldown - dt)

        if input.launchMissile, missilesRemaining > 0, missileCooldown == 0, case .locked(let id) = lock {
            missilesRemaining -= 1
            missileCooldown = Self.missileLaunchCooldown
            missiles.append(Missile(position: own.position + SIMD3(0, 0, Self.missileLaunchDrop),
                                    velocity: own.velocity + own.forward * Self.missileLaunchSpeed, targetID: id))
            events.append(.missileLaunched)
        }

        // Radar missile: rising edge only, with a radar lock on a live target inside launch range.
        let radarEdge: Bool = input.launchRadarMissile && !previousRadarLaunch
        previousRadarLaunch = input.launchRadarMissile
        if radarEdge, radarMissilesRemaining > 0, radarMissileCooldown == 0, let id = radarLockID,
           let t = targets.first(where: { $0.id == id }), !t.destroyed,
           Self.distance(own.position, t.position) <= Self.radarMissileRange {
            radarMissilesRemaining -= 1
            radarMissileCooldown = Self.missileLaunchCooldown
            missiles.append(Missile(position: own.position + SIMD3(0, 0, Self.missileLaunchDrop),
                                    velocity: own.velocity + own.forward * Self.missileLaunchSpeed,
                                    targetID: id, kind: .radarMissile))
            events.append(.radarMissileLaunched)
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
        stepMissiles(dt: dt, targets: &targets, decoys: decoys, events: &events)
        return events
    }

    private mutating func updateSelection(input: WeaponInput, own: Ownship, targets: [AITarget]) {
        let edge = input.cycleTarget && !previousCycle
        previousCycle = input.cycleTarget
        // Runs every frame: only build the filtered list when the selection can change.
        if let s = selectedTarget, !targets.contains(where: { $0.id == s && !$0.destroyed && $0.role != .friendly }) {
            selectedTarget = nil
        }
        guard edge || selectedTarget == nil else { return }
        let live = targets.filter { !$0.destroyed && $0.role != .friendly }
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

    private mutating func stepMissiles(dt: Double, targets: inout [AITarget], decoys: [Decoy], events: inout [WeaponEvent]) {
        var alive: [Missile] = []
        let inFlight: [Missile] = missiles
        for var m in inFlight {
            guard let ti = targets.firstIndex(where: { $0.id == m.targetID }), !targets[ti].destroyed else {
                events.append(.missileMissed); continue
            }
            let target: AITarget = targets[ti]

            // Decoys. Rolls come from the missile generator and only when decoys exist.
            if !decoys.isEmpty {
                switch m.kind {
                case .heatMissile, .cannon:
                    let speed: Double = length(m.velocity)
                    if speed.isFinite, speed > 0 {
                        let roll: Double = nextMissileUnit()
                        let captured: Int? = CountermeasureSystem.flareCapture(
                            seeker: m.position, seekerForward: m.velocity / speed, target: target.position,
                            decoys: decoys, roll: roll, seekerHalfAngle: Self.seekerHalfAngle)
                        if captured != nil {
                            events.append(.decoyed(weapon: .heatMissile, decoy: .flare))
                            continue
                        }
                    }
                case .radarMissile:
                    if !m.chaffChecked,
                       CountermeasureSystem.chaffBlocks(radar: m.position, target: target.position, decoys: decoys,
                                                        beamHalfAngle: Self.chaffBeamHalfAngle) {
                        m.chaffChecked = true
                        let roll: Double = nextMissileUnit()
                        if roll < Self.chaffDecoyChance {
                            events.append(.decoyed(weapon: .radarMissile, decoy: .chaff))
                            continue
                        }
                    }
                }
            }

            let boost: Double = Self.boostTime(for: m.kind)
            let old: SIMD3<Double> = m.position
            let next = Self.guidedStep(position: m.position, velocity: m.velocity, age: m.age,
                                       targetPosition: target.position, targetVelocity: target.velocity,
                                       boostTime: boost, maxSpeed: Self.maxSpeed(for: m.kind), dt: dt)
            m.position = next.position
            m.velocity = next.velocity
            m.age += dt
            // Proximity fuze on the closest approach during this step.
            let miss: Double = Self.segmentDistance(old, m.position, target.position)
            if miss <= Self.fuzeRadius {
                targets[ti].health -= Self.missileDamage
                events.append(.hit(targetID: target.id, weapon: m.kind))
                if targets[ti].destroyed { events.append(.destroyed(targetID: target.id, weapon: m.kind)) }
                continue
            }
            if m.age > Self.life(for: m.kind) || (length(m.velocity) < Self.missileMinSpeed && m.age > boost) {
                events.append(.missileMissed); continue
            }
            alive.append(m)
        }
        missiles = alive
    }
}

// MARK: - Hostile fire

public enum HostileWeaponEvent: Sendable, Equatable {
    case cannonHit(sourceID: String)
    case missileLaunched(sourceID: String)
    case missileHit(sourceID: String)
    case missileDecoyed(sourceID: String, decoy: Decoy.Kind)
    case missileMissed(sourceID: String)
}

struct HostileRound: Sendable, Equatable {
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>
    var sourceID: String
    var age = 0.0
}

struct HostileMissile: Sendable, Equatable {
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>
    var sourceID: String
    var age = 0.0
    var chaffChecked = false
}

/// Cannon bursts and missiles fired by hostile dogfight AI at the player. Only targets whose role is
/// .hostile, whose behavior is .dogfight and which are not destroyed fire. Targets are read, never changed;
/// per-shooter state is kept by target id. Hostile missiles carry a dual seeker: flares and chaff both
/// apply, by the same rules as the player's heat and radar missiles. Deterministic: decoy rolls come from
/// a fixed-seed generator that is drawn only when decoys are present.
public struct HostileWeapons: Sendable {
    // Cannon.
    public static let burstDuration = 0.5                    // s
    public static let burstRoundsPerSecond = 20.0
    public static let burstCooldown = 4.0                    // s from the start of one burst to the next
    public static let roundLife = 2.0                        // s
    public static let roundHitRadius = 8.0                   // m, segment test against the player position
    // Missiles.
    public static let missileStock = 2
    public static let missileCooldown = 12.0                 // s
    public static let missileLaunchSpeed = 50.0              // m/s added along the shooter's nose
    public static let missileFuzeRadius = 15.0               // m
    public static let missileLife = 25.0                     // s
    public static let missileMinSpeed = 200.0                // m/s; slower after burnout is a miss
    // Decoys.
    public static let chaffBeamHalfAngle = 0.1               // rad
    public static let chaffDecoyChance = 0.75
    static let seed: UInt64 = 0xC0FF_EE15_BAD5_EED5

    var gunCooldowns: [String: Double] = [:]
    var burstTimeLeft: [String: Double] = [:]
    var burstAccumulators: [String: Double] = [:]
    var missileCooldowns: [String: Double] = [:]
    var missileStocks: [String: Int] = [:]
    var rounds: [HostileRound] = []
    var missiles: [HostileMissile] = []
    private var rng: UInt64

    public init() {
        rng = Self.seed
    }

    public var activeRounds: Int { rounds.count }
    public var missilesInFlight: Int { missiles.count }

    /// Missiles a shooter still carries.
    public func missilesRemaining(for id: String) -> Int { missileStocks[id] ?? Self.missileStock }

    private mutating func nextUnit() -> Double {
        rng = WeaponSystem.xorshift(rng)
        let r: UInt64 = rng &* 0x2545F4914F6CDD1D
        return Double(r >> 11) / Double(UInt64(1) << 53)
    }

    static func nose(of t: AITarget) -> SIMD3<Double> {
        let c: Double = cos(t.flightPath)
        return SIMD3<Double>(cos(t.heading) * c, sin(t.heading) * c, -sin(t.flightPath))
    }

    static func finite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    public mutating func update(dt: Double, targets: [AITarget], player: Ownship, decoys: [Decoy]) -> [HostileWeaponEvent] {
        guard dt.isFinite, dt > 0, Self.finite(player.position), Self.finite(player.velocity) else { return [] }
        var events: [HostileWeaponEvent] = []

        gunCooldowns = gunCooldowns.mapValues { max(0, $0 - dt) }
        missileCooldowns = missileCooldowns.mapValues { max(0, $0 - dt) }

        for t in targets {
            guard t.role == .hostile, !t.destroyed, case .dogfight(let s) = t.behavior,
                  Self.finite(t.position), t.heading.isFinite, t.flightPath.isFinite, t.speed.isFinite else { continue }
            let id: String = t.id
            fireGun(shooter: t, settings: s, player: player, dt: dt)

            let stock: Int = missileStocks[id] ?? Self.missileStock
            if stock > 0, (missileCooldowns[id] ?? 0) == 0,
               Dogfight.missileSolution(own: t, target: player.position, targetVelocity: player.velocity, settings: s) {
                missileStocks[id] = stock - 1
                missileCooldowns[id] = Self.missileCooldown
                missiles.append(HostileMissile(position: t.position,
                                               velocity: t.velocity + Self.nose(of: t) * Self.missileLaunchSpeed,
                                               sourceID: id))
                events.append(.missileLaunched(sourceID: id))
            }
        }

        stepRounds(dt: dt, player: player, events: &events)
        stepMissiles(dt: dt, player: player, decoys: decoys, events: &events)
        return events
    }

    private mutating func fireGun(shooter t: AITarget, settings s: DogfightSettings, player: Ownship, dt: Double) {
        let id: String = t.id
        var left: Double = burstTimeLeft[id] ?? 0
        if left <= 0, (gunCooldowns[id] ?? 0) == 0,
           Dogfight.gunSolution(own: t, target: player.position, targetVelocity: player.velocity, settings: s) {
            left = Self.burstDuration
            gunCooldowns[id] = Self.burstCooldown
            burstAccumulators[id] = 0
        }
        guard left > 0 else { burstTimeLeft[id] = 0; return }

        var acc: Double = (burstAccumulators[id] ?? 0) + Self.burstRoundsPerSecond * dt
        if acc >= 1 {
            // Rounds leave at muzzle speed on top of the shooter's velocity, aimed at the lead point
            // computed for the round's real speed over the ground.
            let shooterSpeed: Double = max(0, t.speed)
            let aim: SIMD3<Double> = Dogfight.leadPoint(shooterPosition: t.position,
                                                        shooterSpeed: shooterSpeed + WeaponSystem.muzzleSpeed,
                                                        target: player.position, targetVelocity: player.velocity)
            let d: SIMD3<Double> = aim - t.position
            let n: Double = length(d)
            let dir: SIMD3<Double> = (n.isFinite && n > 1e-6) ? d / n : Self.nose(of: t)
            while acc >= 1 {
                acc -= 1
                rounds.append(HostileRound(position: t.position, velocity: t.velocity + dir * WeaponSystem.muzzleSpeed,
                                           sourceID: id))
            }
        }
        burstAccumulators[id] = acc
        burstTimeLeft[id] = left - dt
    }

    private mutating func stepRounds(dt: Double, player: Ownship, events: inout [HostileWeaponEvent]) {
        var alive: [HostileRound] = []
        for var r in rounds {
            let old: SIMD3<Double> = r.position
            r.velocity.z += ISA.g0 * dt
            r.position += r.velocity * dt
            r.age += dt
            if WeaponSystem.segmentDistance(old, r.position, player.position) <= Self.roundHitRadius {
                events.append(.cannonHit(sourceID: r.sourceID))
                continue
            }
            if r.age < Self.roundLife { alive.append(r) }
        }
        rounds = alive
    }

    private mutating func stepMissiles(dt: Double, player: Ownship, decoys: [Decoy], events: inout [HostileWeaponEvent]) {
        var alive: [HostileMissile] = []
        let inFlight: [HostileMissile] = missiles
        for var m in inFlight {
            if !decoys.isEmpty {
                let speed: Double = length(m.velocity)
                if speed.isFinite, speed > 0 {
                    let roll: Double = nextUnit()
                    let captured: Int? = CountermeasureSystem.flareCapture(
                        seeker: m.position, seekerForward: m.velocity / speed, target: player.position,
                        decoys: decoys, roll: roll, seekerHalfAngle: WeaponSystem.seekerHalfAngle)
                    if captured != nil {
                        events.append(.missileDecoyed(sourceID: m.sourceID, decoy: .flare))
                        continue
                    }
                }
                if !m.chaffChecked,
                   CountermeasureSystem.chaffBlocks(radar: m.position, target: player.position, decoys: decoys,
                                                    beamHalfAngle: Self.chaffBeamHalfAngle) {
                    m.chaffChecked = true
                    let roll: Double = nextUnit()
                    if roll < Self.chaffDecoyChance {
                        events.append(.missileDecoyed(sourceID: m.sourceID, decoy: .chaff))
                        continue
                    }
                }
            }

            let old: SIMD3<Double> = m.position
            let next = WeaponSystem.guidedStep(position: m.position, velocity: m.velocity, age: m.age,
                                               targetPosition: player.position, targetVelocity: player.velocity,
                                               boostTime: WeaponSystem.missileBoostTime,
                                               maxSpeed: WeaponSystem.missileMaxSpeed, dt: dt)
            m.position = next.position
            m.velocity = next.velocity
            m.age += dt
            if WeaponSystem.segmentDistance(old, m.position, player.position) <= Self.missileFuzeRadius {
                events.append(.missileHit(sourceID: m.sourceID))
                continue
            }
            if m.age > Self.missileLife
                || (length(m.velocity) < Self.missileMinSpeed && m.age > WeaponSystem.missileBoostTime) {
                events.append(.missileMissed(sourceID: m.sourceID))
                continue
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
