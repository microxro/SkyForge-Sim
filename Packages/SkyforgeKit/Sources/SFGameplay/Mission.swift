// SKYFORGE — Apache-2.0
// Mission data model. Missions are written in the runway frame (metres along the runway from the
// threshold, to the right of the centreline, and up from the runway surface) so the same mission
// runs at any airport the app can fly from.
import Foundation
import SFMath
import SFFlightModel
import SFQuickFlight

/// Runway-aligned coordinates for a `FlightWorld`.
public struct RunwayFrame: Sendable, Codable, Equatable {
    public var threshold: SIMD2<Double>     // world x east, y north (m)
    public var heading: Double              // true heading of the runway (rad)
    public var length: Double               // m
    public var elevation: Double            // m AMSL
    public var halfWidth: Double = 23

    public init(threshold: SIMD2<Double>, heading: Double, length: Double, elevation: Double, halfWidth: Double = 23) {
        self.threshold = threshold; self.heading = heading; self.length = length
        self.elevation = elevation; self.halfWidth = halfWidth
    }

    public init(world: any FlightWorld) {
        self.init(threshold: world.runwayThreshold, heading: world.runwayHeading,
                  length: world.runwayLengthMetres, elevation: world.runwayElevation)
    }

    /// Unit vector along the runway as (east, north).
    public var direction: SIMD2<Double> { SIMD2(sin(heading), cos(heading)) }
    /// Unit vector to the right of the runway direction as (east, north).
    public var rightVector: SIMD2<Double> { SIMD2(direction.y, -direction.x) }

    /// NED position for runway coordinates (`up` is metres above the runway surface).
    public func ned(along: Double, right: Double, up: Double) -> SIMD3<Double> {
        let p = threshold + direction * along + rightVector * right
        return SIMD3(p.y, p.x, -(elevation + up))
    }

    /// Runway coordinates of an NED position.
    public func local(_ ned: SIMD3<Double>) -> (along: Double, right: Double, up: Double) {
        let q = SIMD2(ned.y, ned.x) - threshold
        let along = q.x * direction.x + q.y * direction.y
        let right = q.x * rightVector.x + q.y * rightVector.y
        return (along, right, -ned.z - elevation)
    }
}

public struct MissionWaypoint: Sendable, Codable, Equatable {
    public var along: Double
    public var right: Double
    public var up: Double
    public var radius: Double
    public init(_ along: Double, _ right: Double, _ up: Double, radius: Double = 400) {
        self.along = along; self.right = right; self.up = up; self.radius = radius
    }
    public func ned(_ f: RunwayFrame) -> SIMD3<Double> { f.ned(along: along, right: right, up: up) }
}

public enum ObjectiveKind: Sendable, Codable, Equatable {
    /// Become airborne and reach this height above the ground.
    case takeoff(minHeightAGL: Double)
    /// Hold an altitude above the runway for `hold` seconds.
    case reachAltitude(up: Double, tolerance: Double, hold: Double)
    case flyTo(MissionWaypoint)
    /// Fly through the radius below `maxAGL` at a speed between `minSpeed` and `maxSpeed` (m/s): a water-drop run.
    case dropRun(MissionWaypoint, maxAGL: Double, minSpeed: Double, maxSpeed: Double)
    /// Stop inside the radius at or below `maxSpeed` (m/s), on or near the ground, for `hold` seconds (a rescue pickup).
    case pickup(MissionWaypoint, maxSpeed: Double, hold: Double)
    /// Fly the waypoints in order while staying between the two heights above the ground.
    case lowLevelRoute(points: [MissionWaypoint], minAGL: Double, maxAGL: Double)
    /// Touch down on the runway at an acceptable sink rate, then stop.
    case land(aimAlong: Double, zoneHalfLength: Double, maxSinkRate: Double)
    /// Stay within `within` metres of a target for `hold` seconds.
    case identify(targetID: String, within: Double, hold: Double)
    case destroy(targetIDs: [String])
    /// Hold a slot on a friendly leader for `hold` seconds (the timer decays when out of tolerance).
    case formation(leaderID: String, slot: FormationSlot, spacing: Double, tolerance: Double, hold: Double)
    /// Stay alive and flying for `seconds`. A crash already ends the mission, so this only times the hold.
    case survive(seconds: Double)
    /// Keep the radar locked on a target for `hold` seconds continuously; the timer resets if the lock drops.
    case radarLock(targetID: String, hold: Double)
    /// Turn the velocity vector through one full loop in the vertical plane while staying above `minAGL`
    /// and at or above `minSpeed` (m/s). Fails if the aircraft gets too low or too slow.
    case loop(minAGL: Double, minSpeed: Double)
}

public struct MissionObjective: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var kind: ObjectiveKind
    public var points: Int
    public var timeLimit: Double?
    public init(id: String, title: String, kind: ObjectiveKind, points: Int = 100, timeLimit: Double? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.points = points; self.timeLimit = timeLimit
    }
}

public enum SpawnSpeed: Sendable, Codable, Equatable {
    case cruise, approach
    case fixed(Double)
}

public struct MissionSpawn: Sendable, Codable, Equatable {
    public var along: Double
    public var right: Double
    public var up: Double                   // m above the runway surface (ignored on the runway)
    public var headingOffset: Double        // rad from the runway heading
    public var speed: SpawnSpeed
    public var flaps: Double
    public var onRunway: Bool
    public init(along: Double, right: Double = 0, up: Double = 0, headingOffset: Double = 0,
                speed: SpawnSpeed = .cruise, flaps: Double = 0, onRunway: Bool = false) {
        self.along = along; self.right = right; self.up = up; self.headingOffset = headingOffset
        self.speed = speed; self.flaps = flaps; self.onRunway = onRunway
    }
}

/// Wind relative to the runway heading, so a crosswind stays a crosswind at any airport.
public struct MissionWind: Sendable, Codable, Equatable {
    public var fromRelativeDegrees: Double  // 0 = headwind, 90 = from the right
    public var knots: Double
    public init(fromRelativeDegrees: Double = 0, knots: Double = 0) {
        self.fromRelativeDegrees = fromRelativeDegrees; self.knots = knots
    }
    /// Wind velocity as NED (the direction the air moves toward).
    public func windNED(runwayHeading: Double) -> SIMD3<Double> {
        let from = runwayHeading + fromRelativeDegrees * .pi / 180
        let s = knots * Conv.knotsToMS
        return SIMD3(-cos(from) * s, -sin(from) * s, 0)
    }
}

public enum MissionTargetBehavior: Sendable, Codable, Equatable {
    case straight
    case orbit(turnRate: Double)
    case route(points: [MissionWaypoint], loop: Bool)
    case evade(maxTurnRate: Double)
    case dogfight(DogfightSettings)
}

public struct TargetSpawn: Sendable, Codable, Equatable {
    public var id: String
    public var role: TargetRole
    public var along: Double
    public var right: Double
    public var up: Double
    public var headingOffset: Double
    public var speed: Double
    public var behavior: MissionTargetBehavior
    public var health: Double
    public init(id: String, role: TargetRole, along: Double, right: Double, up: Double, headingOffset: Double = 0,
                speed: Double, behavior: MissionTargetBehavior = .straight, health: Double = 10) {
        self.id = id; self.role = role; self.along = along; self.right = right; self.up = up
        self.headingOffset = headingOffset; self.speed = speed; self.behavior = behavior; self.health = health
    }

    public func makeTarget(frame f: RunwayFrame) -> AITarget {
        let b: TargetBehavior
        switch behavior {
        case .straight: b = .straight
        case .orbit(let r): b = .orbit(turnRate: r)
        case .route(let pts, let loop): b = .route(points: pts.map { $0.ned(f) }, loop: loop)
        case .evade(let r): b = .evade(maxTurnRate: r)
        case .dogfight(let settings): b = .dogfight(settings)
        }
        return AITarget(id: id, role: role, position: f.ned(along: along, right: right, up: up),
                        heading: f.heading + headingOffset, speed: speed, behavior: b, health: health)
    }
}

public enum MissionCategory: String, Sendable, Codable, CaseIterable {
    case training, navigation, landing, military

    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public struct MissionDefinition: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var category: MissionCategory
    public var briefing: String
    public var difficulty: Int                      // 1...5
    public var recommendedAircraft: String          // aircraft id
    public var allowedRoles: [AircraftRole]         // empty = any aircraft
    public var spawn: MissionSpawn
    public var wind: MissionWind
    public var targets: [TargetSpawn]
    public var objectives: [MissionObjective]
    public var parTime: Double                      // seconds for the full time bonus
    public var timeLimit: Double?
    public var areaRadius: Double?                  // fail beyond this distance from the threshold
    public var unlock: UnlockRequirement

    public init(id: String, title: String, category: MissionCategory, briefing: String, difficulty: Int,
                recommendedAircraft: String, allowedRoles: [AircraftRole] = [], spawn: MissionSpawn,
                wind: MissionWind = MissionWind(), targets: [TargetSpawn] = [], objectives: [MissionObjective],
                parTime: Double, timeLimit: Double? = nil, areaRadius: Double? = 40_000, unlock: UnlockRequirement = .none) {
        self.id = id; self.title = title; self.category = category; self.briefing = briefing
        self.difficulty = difficulty; self.recommendedAircraft = recommendedAircraft
        self.allowedRoles = allowedRoles; self.spawn = spawn; self.wind = wind; self.targets = targets
        self.objectives = objectives; self.parTime = parTime; self.timeLimit = timeLimit
        self.areaRadius = areaRadius; self.unlock = unlock
    }

    public var isMilitary: Bool { category == .military }

    public func allows(_ aircraft: PlaneSpec) -> Bool {
        allowedRoles.isEmpty || allowedRoles.contains(aircraft.role)
    }

    public var maxBasePoints: Int { objectives.reduce(0) { $0 + $1.points } }

    /// Problems that would make the mission unwinnable or meaningless; empty when it is sound.
    public var validationProblems: [String] {
        var out: [String] = []
        if objectives.isEmpty { out.append("no objectives") }
        let ids = Set(targets.map(\.id))
        if ids.count != targets.count { out.append("duplicate target ids") }
        if Set(objectives.map(\.id)).count != objectives.count { out.append("duplicate objective ids") }
        for o in objectives {
            switch o.kind {
            case .destroy(let t):
                if t.isEmpty { out.append("\(o.id): destroy with no targets") }
                if !Set(t).isSubset(of: ids) { out.append("\(o.id): unknown target id") }
            case .identify(let t, let within, let hold):
                if !ids.contains(t) { out.append("\(o.id): unknown target id") }
                if within <= 0 || hold < 0 { out.append("\(o.id): bad identify range") }
            case .formation(let l, _, let spacing, let tol, let hold):
                if !ids.contains(l) { out.append("\(o.id): unknown leader id") }
                if spacing <= 0 || tol <= 0 || hold <= 0 { out.append("\(o.id): bad formation numbers") }
            case .lowLevelRoute(let pts, let lo, let hi):
                if pts.isEmpty || lo >= hi { out.append("\(o.id): bad low-level route") }
            case .pickup(_, let speed, let hold):
                if speed <= 0 || hold < 0 { out.append("\(o.id): bad pickup limits") }
            case .land(_, let zone, let maxSink):
                if zone <= 0 || maxSink <= 0 { out.append("\(o.id): bad landing limits") }
            case .reachAltitude(_, let tol, let hold):
                if tol <= 0 || hold < 0 { out.append("\(o.id): bad altitude hold") }
            case .survive(let seconds):
                if !(seconds > 0) { out.append("\(o.id): survive time must be above zero") }
            case .radarLock(let t, let hold):
                if !ids.contains(t) { out.append("\(o.id): unknown target id") }
                if !(hold >= 0) { out.append("\(o.id): bad radar lock hold") }
            case .dropRun(_, let maxAGL, let minSpeed, let maxSpeed):
                if maxAGL <= 0 || minSpeed < 0 || maxSpeed <= minSpeed { out.append("\(o.id): bad drop run limits") }
            case .loop(let minAGL, let minSpeed):
                if minAGL <= 0 || minSpeed <= 0 { out.append("\(o.id): bad loop limits") }
            case .takeoff, .flyTo: break
            }
        }
        return out
    }
}

public enum MissionMedal: Int, Sendable, Codable, Comparable, CaseIterable {
    case none = 0, bronze, silver, gold

    public static func < (a: MissionMedal, b: MissionMedal) -> Bool { a.rawValue < b.rawValue }
    public var displayName: String {
        switch self { case .none: return "No medal"; case .bronze: return "Bronze"; case .silver: return "Silver"; case .gold: return "Gold" }
    }
}

public struct MissionResult: Sendable, Codable, Equatable {
    public var missionID: String
    public var aircraftID: String
    public var success: Bool
    public var failureReason: String?
    public var score: Int
    public var medal: MissionMedal
    public var elapsed: Double
    public var objectivesCompleted: Int
    /// Hostile aircraft destroyed during the mission.
    public var kills: Int
    public var breakdown: [String: Int]
    /// Damage taken, countermeasures used and missile accuracy over the sortie.
    public var combat: CombatTally

    public init(missionID: String, aircraftID: String, success: Bool, failureReason: String?, score: Int, medal: MissionMedal,
                elapsed: Double, objectivesCompleted: Int, kills: Int = 0, breakdown: [String: Int],
                combat: CombatTally = CombatTally()) {
        self.missionID = missionID; self.aircraftID = aircraftID; self.success = success
        self.failureReason = failureReason; self.score = score; self.medal = medal; self.elapsed = elapsed
        self.objectivesCompleted = objectivesCompleted; self.kills = kills; self.breakdown = breakdown
        self.combat = combat
    }

    /// Hand-written so results saved before combat existed (no "combat" key) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        missionID = try c.decode(String.self, forKey: .missionID)
        aircraftID = try c.decode(String.self, forKey: .aircraftID)
        success = try c.decode(Bool.self, forKey: .success)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        score = try c.decode(Int.self, forKey: .score)
        medal = try c.decode(MissionMedal.self, forKey: .medal)
        elapsed = try c.decode(Double.self, forKey: .elapsed)
        objectivesCompleted = try c.decode(Int.self, forKey: .objectivesCompleted)
        kills = try c.decode(Int.self, forKey: .kills)
        breakdown = try c.decode([String: Int].self, forKey: .breakdown)
        combat = try c.decodeIfPresent(CombatTally.self, forKey: .combat) ?? CombatTally()
    }
}
