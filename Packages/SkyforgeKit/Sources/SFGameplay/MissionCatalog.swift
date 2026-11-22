// SKYFORGE — Apache-2.0
// The built-in campaign: civil training and landing missions that unlock the faster aircraft, then
// a military track (formation, intercept, gunnery, low-level navigation, air combat training).
// All coordinates are runway-frame metres, so the missions run at any airport.
import Foundation

public enum MissionCatalog {
    private static let civil: [AircraftRole] = [.lightTrainer, .tourer, .aerobatic]
    private static let jets: [AircraftRole] = [.jetTrainer, .fighter]

    public static let firstFlight = MissionDefinition(
        id: "first-flight", title: "First Flight", category: .training,
        briefing: "Line up, take off, climb to 1,500 ft above the field and fly to the marker 4.5 km down the extended centreline.",
        difficulty: 1, recommendedAircraft: AircraftCatalog.sf1Trainer.id, allowedRoles: civil,
        spawn: MissionSpawn(along: 60, onRunway: true),
        objectives: [
            MissionObjective(id: "takeoff", title: "Take off", kind: .takeoff(minHeightAGL: 30), points: 100),
            MissionObjective(id: "climb", title: "Climb to 1,500 ft and hold", kind: .reachAltitude(up: 450, tolerance: 60, hold: 8), points: 100),
            MissionObjective(id: "marker", title: "Fly to the marker", kind: .flyTo(MissionWaypoint(4_500, 1_200, 450, radius: 500)), points: 100),
        ],
        parTime: 300, timeLimit: 720, areaRadius: 20_000)

    public static let patternLanding = MissionDefinition(
        id: "pattern-landing", title: "Traffic Pattern", category: .landing,
        briefing: "Fly a left-hand rectangular circuit at 1,000 ft and land on the runway. Capture the three-degree path on final.",
        difficulty: 2, recommendedAircraft: AircraftCatalog.sf1Trainer.id, allowedRoles: civil,
        spawn: MissionSpawn(along: 1_500, up: 280, flaps: 0),
        wind: MissionWind(fromRelativeDegrees: 20, knots: 6),
        objectives: [
            MissionObjective(id: "crosswind", title: "Turn crosswind", kind: .flyTo(MissionWaypoint(3_200, -1_100, 300, radius: 400))),
            MissionObjective(id: "downwind", title: "Fly downwind", kind: .flyTo(MissionWaypoint(1_000, -1_100, 300, radius: 400))),
            MissionObjective(id: "base", title: "Turn base", kind: .flyTo(MissionWaypoint(-1_000, -1_100, 220, radius: 400))),
            MissionObjective(id: "final", title: "Join final", kind: .flyTo(MissionWaypoint(-2_200, 0, 115, radius: 350))),
            MissionObjective(id: "land", title: "Land and stop", kind: .land(aimAlong: 300, zoneHalfLength: 250, maxSinkRate: 3.0), points: 200),
        ],
        parTime: 480, timeLimit: 900, areaRadius: 15_000, unlock: .mission("first-flight"))

    public static let precisionLanding = MissionDefinition(
        id: "precision-landing", title: "Crosswind Precision", category: .landing,
        briefing: "Established on a two-mile final with a 12 knot crosswind from the right. Touch down in the zone, gently.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sf1Trainer.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -2_500, up: 135, speed: .approach, flaps: 0.5),
        wind: MissionWind(fromRelativeDegrees: 80, knots: 12),
        objectives: [
            MissionObjective(id: "land", title: "Land in the touchdown zone", kind: .land(aimAlong: 300, zoneHalfLength: 150, maxSinkRate: 2.5), points: 300),
        ],
        parTime: 150, timeLimit: 420, areaRadius: 10_000, unlock: .mission("pattern-landing"))

    public static let wingman = MissionDefinition(
        id: "wingman-formation", title: "Wingman", category: .military,
        briefing: "Join on lead and hold echelon right through three turns, then line abreast. Keep within 45 m of your slot.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfT1Jet.id, allowedRoles: jets,
        spawn: MissionSpawn(along: 650, right: 90, up: 900, speed: .fixed(150)),
        targets: [
            TargetSpawn(id: "lead", role: .friendly, along: 1_000, right: 0, up: 900, speed: 140,
                        behavior: .route(points: [MissionWaypoint(7_000, 0, 900), MissionWaypoint(9_000, 3_500, 1_000),
                                                   MissionWaypoint(6_000, 7_000, 900), MissionWaypoint(-2_000, 5_000, 900)], loop: false)),
        ],
        objectives: [
            MissionObjective(id: "join", title: "Join echelon right", kind: .formation(leaderID: "lead", slot: .echelonRight, spacing: 60, tolerance: 45, hold: 30), points: 150),
            MissionObjective(id: "abreast", title: "Hold line abreast", kind: .formation(leaderID: "lead", slot: .lineAbreast, spacing: 50, tolerance: 45, hold: 40), points: 150),
        ],
        parTime: 180, timeLimit: 600, areaRadius: 30_000, unlock: .mission("pattern-landing"))

    public static let intercept = MissionDefinition(
        id: "intercept-bogey", title: "Quick Reaction Alert", category: .military,
        briefing: "Unknown aircraft inbound from the north-east at 10,000 ft. Close to visual range to identify it, then engage the hostile drone with a heat-seeking missile or the cannon.",
        difficulty: 4, recommendedAircraft: AircraftCatalog.sfF1Fighter.id, allowedRoles: jets,
        spawn: MissionSpawn(along: 0, up: 3_000, speed: .fixed(220)),
        targets: [
            TargetSpawn(id: "bogey", role: .hostile, along: 22_000, right: 8_000, up: 3_000, headingOffset: .pi * 1.05,
                        speed: 170, behavior: .route(points: [MissionWaypoint(-8_000, 0, 3_000)], loop: false)),
        ],
        objectives: [
            MissionObjective(id: "identify", title: "Identify the bogey (within 2.5 km)", kind: .identify(targetID: "bogey", within: 2_500, hold: 3), points: 100),
            MissionObjective(id: "engage", title: "Destroy the hostile drone", kind: .destroy(targetIDs: ["bogey"]), points: 200),
        ],
        parTime: 240, timeLimit: 480, areaRadius: 60_000, unlock: .mission("wingman-formation"))

    public static let gunnery = MissionDefinition(
        id: "gunnery-range", title: "Gunnery Range", category: .military,
        briefing: "Three target drones over the range. Cannon or missile, any order. Do not leave the range.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfT1Jet.id, allowedRoles: jets,
        spawn: MissionSpawn(along: 0, up: 1_500, speed: .fixed(150)),
        targets: [
            TargetSpawn(id: "drone-1", role: .hostile, along: 3_000, right: 600, up: 1_500, speed: 90, behavior: .straight, health: 6),
            TargetSpawn(id: "drone-2", role: .hostile, along: 4_500, right: -1_500, up: 1_700, speed: 100, behavior: .orbit(turnRate: 0.05), health: 6),
            TargetSpawn(id: "drone-3", role: .hostile, along: 6_500, right: 1_200, up: 1_400, headingOffset: .pi,
                        speed: 95, behavior: .route(points: [MissionWaypoint(0, 1_200, 1_400)], loop: false), health: 6),
        ],
        objectives: [
            MissionObjective(id: "clear-range", title: "Destroy all three drones", kind: .destroy(targetIDs: ["drone-1", "drone-2", "drone-3"]), points: 300),
        ],
        parTime: 200, timeLimit: 420, areaRadius: 25_000, unlock: .mission("pattern-landing"))

    public static let lowLevel = MissionDefinition(
        id: "low-level-nav", title: "Low-Level Navigation", category: .military,
        briefing: "Fly the four-leg route below 500 ft for full marks. Dropping under 60 ft for more than three seconds ends the sortie.",
        difficulty: 4, recommendedAircraft: AircraftCatalog.sfT1Jet.id, allowedRoles: jets,
        spawn: MissionSpawn(along: 0, up: 120, speed: .fixed(150)),
        objectives: [
            MissionObjective(id: "route", title: "Fly the low-level route", kind: .lowLevelRoute(
                points: [MissionWaypoint(4_000, 1_500, 120, radius: 400), MissionWaypoint(9_000, -1_500, 120, radius: 400),
                         MissionWaypoint(14_000, 2_000, 120, radius: 400), MissionWaypoint(18_000, 0, 120, radius: 400)],
                minAGL: 18, maxAGL: 150), points: 300),
        ],
        parTime: 150, timeLimit: 300, areaRadius: 30_000, unlock: .mission("wingman-formation"))

    public static let dogfight = MissionDefinition(
        id: "air-combat-training", title: "Air Combat Training", category: .military,
        briefing: "A drone with evasive manoeuvres is 3 km ahead. Get behind it and shoot it down inside five minutes.",
        difficulty: 5, recommendedAircraft: AircraftCatalog.sfF1Fighter.id, allowedRoles: [.fighter],
        spawn: MissionSpawn(along: 0, up: 3_000, speed: .fixed(200)),
        targets: [
            TargetSpawn(id: "bandit", role: .hostile, along: 3_000, right: 400, up: 3_000, speed: 150, behavior: .evade(maxTurnRate: 0.14), health: 12),
        ],
        objectives: [
            MissionObjective(id: "kill", title: "Shoot down the bandit", kind: .destroy(targetIDs: ["bandit"]), points: 400),
        ],
        parTime: 120, timeLimit: 300, areaRadius: 40_000, unlock: .mission("intercept-bogey"))

    public static let all: [MissionDefinition] = [firstFlight, patternLanding, precisionLanding, wingman, intercept, gunnery, lowLevel, dogfight]

    public static func mission(id: String) -> MissionDefinition? { all.first { $0.id == id } }
    public static func missions(in category: MissionCategory) -> [MissionDefinition] { all.filter { $0.category == category } }
}
