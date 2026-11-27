// SKYFORGE — Apache-2.0
// The built-in campaign: civil training and landing missions that unlock the faster aircraft, then
// a military track (formation, intercept, gunnery, low-level navigation, air combat training).
// All coordinates are runway-frame metres, so the missions run at any airport.
import Foundation
import SFFlightModel

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
        parTime: 480, timeLimit: 900, areaRadius: 15_000, unlock: .mission("first-flight"), traffic: true)

    public static let precisionLanding = MissionDefinition(
        id: "precision-landing", title: "Crosswind Precision", category: .landing,
        briefing: "Established on a two-mile final with a 12 knot crosswind from the right. Touch down in the zone, gently.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sf1Trainer.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -2_500, up: 135, speed: .approach, flaps: 0.5),
        wind: MissionWind(fromRelativeDegrees: 80, knots: 12),
        objectives: [
            MissionObjective(id: "land", title: "Land in the touchdown zone", kind: .land(aimAlong: 300, zoneHalfLength: 150, maxSinkRate: 2.5), points: 300),
        ],
        parTime: 150, timeLimit: 420, areaRadius: 10_000, unlock: .mission("pattern-landing"), traffic: true)

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

    public static let coastalSurvey = MissionDefinition(
        id: "coastal-survey", title: "Coastal Survey", category: .navigation,
        briefing: "Survey the coast: climb to 2,000 ft, fly to the north headland, then turn back to the survey point to the south.",
        difficulty: 2, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: 0, up: 600, speed: .cruise),
        wind: MissionWind(fromRelativeDegrees: 45, knots: 8),
        objectives: [
            MissionObjective(id: "headland", title: "Reach the north headland", kind: .flyTo(MissionWaypoint(6_000, 2_500, 600, radius: 600)), points: 150),
            MissionObjective(id: "survey", title: "Return to the survey point", kind: .flyTo(MissionWaypoint(1_500, -1_000, 500, radius: 500)), points: 150),
        ],
        parTime: 300, timeLimit: 600, areaRadius: 40_000, unlock: .mission("pattern-landing"))

    public static let twinBandits = MissionDefinition(
        id: "twin-bandits", title: "Twin Bandits", category: .military,
        briefing: "Two drones are patrolling 4 km ahead, one evading and one orbiting. Shoot both down inside seven minutes.",
        difficulty: 5, recommendedAircraft: AircraftCatalog.sfF1Fighter.id, allowedRoles: [.fighter],
        spawn: MissionSpawn(along: 0, up: 3_000, speed: .fixed(220)),
        targets: [
            TargetSpawn(id: "bandit-a", role: .hostile, along: 4_000, right: -600, up: 3_000, speed: 160, behavior: .evade(maxTurnRate: 0.12), health: 12),
            TargetSpawn(id: "bandit-b", role: .hostile, along: 5_000, right: 800, up: 2_500, speed: 140, behavior: .orbit(turnRate: 0.08), health: 12),
        ],
        objectives: [
            MissionObjective(id: "bandits", title: "Shoot down both bandits", kind: .destroy(targetIDs: ["bandit-a", "bandit-b"]), points: 500),
        ],
        parTime: 240, timeLimit: 420, areaRadius: 40_000, unlock: .mission("air-combat-training"))

    public static let radarIntercept = MissionDefinition(
        id: "radar-intercept", title: "Radar Intercept", category: .military,
        briefing: "A hostile fighter is 12 km ahead and will manoeuvre to escape. Use the radar to hold a lock on it for two seconds, then shoot it down.",
        difficulty: 4, recommendedAircraft: AircraftCatalog.sfF1Fighter.id, allowedRoles: [.fighter],
        spawn: MissionSpawn(along: 0, up: 3_000, speed: .cruise),
        targets: [
            TargetSpawn(id: "bandit", role: .hostile, along: 12_000, right: 500, up: 3_000, speed: 170, behavior: .evade(maxTurnRate: 0.12), health: 12),
        ],
        objectives: [
            MissionObjective(id: "lock", title: "Hold a radar lock on the bandit", kind: .radarLock(targetID: "bandit", hold: 2), points: 150),
            MissionObjective(id: "kill", title: "Shoot down the bandit", kind: .destroy(targetIDs: ["bandit"]), points: 250),
        ],
        parTime: 240, timeLimit: 480, areaRadius: 50_000, unlock: .mission("air-combat-training"))

    public static let twoShipDefence = MissionDefinition(
        id: "two-ship-defence", title: "Two-Ship Defence", category: .military,
        briefing: "Two hostile fighters are closing from 4 km ahead, one either side. The bandits fight back: they will turn onto your tail and fire. Survive the first minute, then shoot both down.",
        difficulty: 5, recommendedAircraft: AircraftCatalog.sfF1Fighter.id, allowedRoles: [.fighter],
        spawn: MissionSpawn(along: 0, up: 3_000, speed: .cruise),
        targets: [
            TargetSpawn(id: "bandit-a", role: .hostile, along: 4_000, right: -1_500, up: 3_000, headingOffset: .pi,
                        speed: 180, behavior: .dogfight(DogfightSettings()), health: 12),
            TargetSpawn(id: "bandit-b", role: .hostile, along: 4_000, right: 1_500, up: 3_100, headingOffset: .pi,
                        speed: 180, behavior: .dogfight(DogfightSettings()), health: 12),
        ],
        objectives: [
            MissionObjective(id: "survive", title: "Survive the first minute", kind: .survive(seconds: 60), points: 150),
            MissionObjective(id: "kill", title: "Shoot down both bandits", kind: .destroy(targetIDs: ["bandit-a", "bandit-b"]), points: 300),
        ],
        parTime: 240, timeLimit: 480, areaRadius: 50_000, unlock: .mission("radar-intercept"))

    public static let bushStrip = MissionDefinition(
        id: "bush-strip", title: "Bush Strip", category: .landing,
        briefing: "Come in low over the trees and land in the first 200 m of the strip. Short fields reward a slow, steady approach.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfAerobat.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -1_500, up: 120, speed: .approach),
        objectives: [
            MissionObjective(id: "short-land", title: "Land in the first 200 m", kind: .land(aimAlong: 120, zoneHalfLength: 80, maxSinkRate: 2.2), points: 300),
        ],
        parTime: 180, timeLimit: 420, areaRadius: 10_000, unlock: .mission("pattern-landing"))

    public static let airportTour = MissionDefinition(
        id: "airport-tour", title: "Airport Tour", category: .navigation,
        briefing: "Take off and fly a loop around the field: four legs at 1,000 to 1,500 ft, then back over the runway.",
        difficulty: 2, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: 60, onRunway: true),
        objectives: [
            MissionObjective(id: "airborne", title: "Take off", kind: .takeoff(minHeightAGL: 30), points: 50),
            MissionObjective(id: "leg-1", title: "Pass the first point", kind: .flyTo(MissionWaypoint(3_000, 3_000, 300, radius: 500)), points: 100),
            MissionObjective(id: "leg-2", title: "Pass the far point", kind: .flyTo(MissionWaypoint(6_000, 0, 350, radius: 500)), points: 100),
            MissionObjective(id: "leg-3", title: "Pass the south point", kind: .flyTo(MissionWaypoint(3_000, -3_000, 300, radius: 500)), points: 100),
            MissionObjective(id: "leg-4", title: "Back over the runway", kind: .flyTo(MissionWaypoint(0, 0, 250, radius: 400)), points: 100),
        ],
        parTime: 420, timeLimit: 900, areaRadius: 20_000, unlock: .mission("coastal-survey"))

    public static let valleyRun = MissionDefinition(
        id: "valley-run", title: "Valley Run", category: .navigation,
        briefing: "Follow the valley at 80 to 350 ft above the ground, through three gates. Dropping under 80 ft for more than three seconds ends the run.",
        difficulty: 4, recommendedAircraft: AircraftCatalog.sfAerobat.id, allowedRoles: civil,
        spawn: MissionSpawn(along: 0, up: 110, speed: .fixed(70)),
        objectives: [
            MissionObjective(id: "valley", title: "Fly the valley route", kind: .lowLevelRoute(
                points: [MissionWaypoint(4_000, 800, 110, radius: 400), MissionWaypoint(8_000, -900, 100, radius: 400),
                         MissionWaypoint(12_000, 600, 110, radius: 400)],
                minAGL: 25, maxAGL: 110), points: 300),
        ],
        parTime: 200, timeLimit: 420, areaRadius: 25_000, unlock: .mission("coastal-survey"))

    public static let waterDropRun = MissionDefinition(
        id: "water-drop-run", title: "Water Drop Run", category: .training,
        briefing: "A grass fire is burning 3 km out. Fly to the fire line, then make a low, steady run through it at 30 m or less and 45 to 70 m/s.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfAerobat.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -1_000, up: 300, speed: .cruise),
        objectives: [
            MissionObjective(id: "approach", title: "Fly to the fire line", kind: .flyTo(MissionWaypoint(3_000, 0, 150, radius: 500)), points: 150),
            MissionObjective(id: "drop", title: "Make the drop run", kind: .dropRun(MissionWaypoint(3_000, 0, 30, radius: 250), maxAGL: 30, minSpeed: 45, maxSpeed: 70), points: 350),
        ],
        parTime: 240, timeLimit: 480, areaRadius: 20_000, unlock: .mission("pattern-landing"))

    public static let airshowLoop = MissionDefinition(
        id: "airshow-loop", title: "Airshow Loop", category: .training,
        briefing: "Set up on the display line at 2 km, then fly one clean loop. Keep at least 150 m of height and 40 m/s of speed the whole way round.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfAerobat.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -1_000, up: 300, speed: .cruise),
        objectives: [
            MissionObjective(id: "setup", title: "Set up on the display line", kind: .flyTo(MissionWaypoint(2_000, 0, 300, radius: 400)), points: 150),
            MissionObjective(id: "loop", title: "Fly one full loop", kind: .loop(minAGL: 150, minSpeed: 40), points: 350),
        ],
        parTime: 240, timeLimit: 480, areaRadius: 20_000, unlock: .mission("valley-run"))

    public static let ifrApproach = MissionDefinition(
        id: "ifr-approach", title: "Instrument Approach", category: .landing,
        briefing: "Join the final approach 4 km out at the glideslope. Hold the centreline and the 3 degree path to the threshold. Stray more than 30 m for longer than 3 seconds and the approach fails.",
        difficulty: 4, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -5_000, up: 262, speed: .approach),
        objectives: [
            MissionObjective(id: "glidepath", title: "Fly the glidepath to the threshold", kind: .ifrApproach(gateDistance: 4_000, glideslopeDeg: 3, tolerance: 30, graceTime: 3), points: 500),
        ],
        parTime: 180, timeLimit: 420, areaRadius: 20_000, unlock: .mission("airshow-loop"))

    public static let rescuePickup = MissionDefinition(
        id: "rescue-pickup", title: "Rescue Pickup", category: .navigation,
        briefing: "A hiker is waiting on a meadow strip about 1.5 km down the field. Land, stop beside them for three seconds, then fly the casualty to the hospital at the far end.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -2_000, up: 150, speed: .approach),
        objectives: [
            MissionObjective(id: "pickup", title: "Land and stop beside the hiker", kind: .pickup(MissionWaypoint(1_500, 120, 0, radius: 60), maxSpeed: 8, hold: 3), points: 250),
            MissionObjective(id: "hospital", title: "Fly to the hospital", kind: .flyTo(MissionWaypoint(7_000, -600, 400, radius: 500)), points: 250),
        ],
        parTime: 300, timeLimit: 600, areaRadius: 30_000, unlock: .mission("bush-strip"))

    public static let cargoRun = MissionDefinition(
        id: "cargo-run", title: "Cargo Run", category: .navigation,
        briefing: "Load 180 kg of freight in the rear hold and fly it 4 km out to the grass strip. The load moves the centre of gravity aft, so keep the approach gentle.",
        difficulty: 2, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: 0, onRunway: true),
        objectives: [
            MissionObjective(id: "deliver", title: "Fly the freight to the grass strip", kind: .flyTo(MissionWaypoint(4_000, 0, 60, radius: 400)), points: 300),
        ],
        parTime: 300, timeLimit: 600, areaRadius: 20_000, unlock: .mission("airshow-loop"),
        payload: [PayloadStation(name: "Rear hold", mass: 180, arm: -0.3)], surface: .grass)
    public static let engineOutLanding = MissionDefinition(
        id: "engine-out-landing", title: "Dead-Stick Landing", category: .landing,
        briefing: "The engine quits 20 seconds into a 3 km glide from 900 m. Stay on the airfield and land within 250 m of the threshold with the engine failed.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -3_000, up: 900, speed: .cruise),
        objectives: [
            MissionObjective(id: "land", title: "Land on the runway", kind: .land(aimAlong: 300, zoneHalfLength: 250, maxSinkRate: 3.0), points: 500),
        ],
        parTime: 240, timeLimit: 420, areaRadius: 20_000, unlock: .mission("ifr-approach"),
        engineFailureAt: 20)

    public static let scooperFirefight = MissionDefinition(
        id: "scooper-firefight", title: "Lake Scoop Firefight", category: .training,
        briefing: "A grass fire is burning 3 km out. Skim the lake at planing speed with the door open to take water, then make a low drop run over the fire line at 30 m or less and 45 to 70 m/s.",
        difficulty: 4, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -1_000, up: 300, speed: .cruise),
        objectives: [
            MissionObjective(id: "lake", title: "Set up on the lake", kind: .flyTo(MissionWaypoint(1_500, -800, 60, radius: 400)), points: 150),
            MissionObjective(id: "drop", title: "Drop on the fire line", kind: .dropRun(MissionWaypoint(3_000, 0, 30, radius: 250), maxAGL: 30, minSpeed: 45, maxSpeed: 70), points: 350),
        ],
        parTime: 300, timeLimit: 600, areaRadius: 20_000, unlock: .mission("engine-out-landing"),
        surface: .water)

    public static let gateRun = MissionDefinition(
        id: "gate-run", title: "Gate Run", category: .training,
        briefing: "Fly three gates in order. Pass through each ring at height; missing a gate ends the run.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfAerobat.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -1_000, up: 300, speed: .cruise),
        objectives: [
            MissionObjective(id: "gate-1", title: "Gate 1", kind: .gate(MissionWaypoint(2_000, 0, 300, radius: 150), headingDeg: 0), points: 150),
            MissionObjective(id: "gate-2", title: "Gate 2", kind: .gate(MissionWaypoint(3_000, 600, 350, radius: 150), headingDeg: 20), points: 150),
            MissionObjective(id: "gate-3", title: "Gate 3", kind: .gate(MissionWaypoint(4_000, -300, 300, radius: 150), headingDeg: -20), points: 200),
        ],
        parTime: 240, timeLimit: 480, areaRadius: 20_000, unlock: .mission("airshow-loop"))

    public static let aileronRollPractice = MissionDefinition(
        id: "aileron-roll", title: "Aileron Roll", category: .training,
        briefing: "Set up on the display line at 2 km, then fly one aileron roll. Keep at least 150 m of height and 40 m/s of speed through it.",
        difficulty: 2, recommendedAircraft: AircraftCatalog.sfAerobat.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -1_000, up: 300, speed: .cruise),
        objectives: [
            MissionObjective(id: "setup", title: "Set up on the display line", kind: .flyTo(MissionWaypoint(2_000, 0, 300, radius: 400)), points: 150),
            MissionObjective(id: "roll", title: "Fly one aileron roll", kind: .aileronRoll(minAGL: 150, minSpeed: 40), points: 300),
        ],
        parTime: 240, timeLimit: 480, areaRadius: 20_000, unlock: .mission("airshow-loop"))

    /// Search and rescue line: find a missing hiker, bring a casualty off a field strip, then find two people in one sortie.
    public static let sarGridSearch = MissionDefinition(
        id: "sar-grid-search", title: "Grid Search", category: .rescue,
        briefing: "A hiker is missing in the hills 3 km out. Sweep the search box at 150 to 400 m, get down to 200 m over the hiker for five seconds, then land back at the field. The hiker is in view only inside 150 m horizontally.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -3_000, up: 600, speed: .cruise),
        objectives: [
            MissionObjective(id: "search", title: "Fly the search pattern", kind: .lowLevelRoute(
                points: [MissionWaypoint(2_000, 2_000, 0, radius: 300), MissionWaypoint(2_000, -2_000, 0, radius: 300),
                         MissionWaypoint(4_000, -2_000, 0, radius: 300), MissionWaypoint(4_000, 2_000, 0, radius: 300)],
                minAGL: 150, maxAGL: 400), points: 200),
            MissionObjective(id: "spot", title: "Spot the hiker below 200 m", kind: .spotSurvivor(survivorID: "hiker", within: 150, maxAGL: 200, hold: 5), points: 400, timeLimit: 300),
            MissionObjective(id: "land", title: "Land back at the field", kind: .land(aimAlong: 300, zoneHalfLength: 250, maxSinkRate: 3.0), points: 200),
        ],
        parTime: 420, timeLimit: 900, areaRadius: 30_000, unlock: .mission("rescue-pickup"),
        survivors: [SurvivorSpawn(id: "hiker", along: 3_000, right: 0)])

    public static let sarMedevacStrip = MissionDefinition(
        id: "sar-medevac-strip", title: "Medevac from the Strip", category: .rescue,
        briefing: "A climber with a broken leg is on a grass strip 2.5 km out, 300 m right of the centreline. Land off-field, stop beside the casualty for three seconds, then fly them to the hospital at the far end. The casualty must be off the strip within four minutes.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -2_500, up: 200, speed: .approach),
        objectives: [
            MissionObjective(id: "strip", title: "Land and stop beside the casualty", kind: .pickup(MissionWaypoint(2_500, 300, 0, radius: 60), maxSpeed: 8, hold: 3), points: 300, timeLimit: 240),
            MissionObjective(id: "hospital", title: "Fly to the hospital", kind: .flyTo(MissionWaypoint(8_000, -600, 400, radius: 500)), points: 300, timeLimit: 300),
        ],
        parTime: 300, timeLimit: 600, areaRadius: 30_000, unlock: .mission("sar-grid-search"), surface: .grass)

    public static let sarTwoSurvivors = MissionDefinition(
        id: "sar-two-survivors", title: "Two Survivors", category: .rescue,
        briefing: "A ridge walker and a hiker are down in separate spots. Each spot must be made within four minutes of the last objective. Then land on the creek meadow to collect the hiker and fly them to the hospital. A spot needs 150 m or less horizontally and 200 m or below.",
        difficulty: 4, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
        spawn: MissionSpawn(along: -3_000, up: 500, speed: .cruise),
        objectives: [
            MissionObjective(id: "spot-ridge", title: "Spot the ridge walker", kind: .spotSurvivor(survivorID: "ridge", within: 150, maxAGL: 200, hold: 5), points: 300, timeLimit: 240),
            MissionObjective(id: "spot-creek", title: "Spot the hiker at the creek", kind: .spotSurvivor(survivorID: "creek", within: 150, maxAGL: 200, hold: 5), points: 300, timeLimit: 240),
            MissionObjective(id: "pickup", title: "Land and stop beside the hiker", kind: .pickup(MissionWaypoint(4_500, -2_000, 0, radius: 80), maxSpeed: 8, hold: 3), points: 300, timeLimit: 300),
            MissionObjective(id: "hospital", title: "Fly to the hospital", kind: .flyTo(MissionWaypoint(9_000, 0, 400, radius: 500)), points: 250),
        ],
        parTime: 420, timeLimit: 900, areaRadius: 40_000, unlock: .mission("sar-medevac-strip"), surface: .grass,
        survivors: [SurvivorSpawn(id: "ridge", along: 2_000, right: 2_500), SurvivorSpawn(id: "creek", along: 4_500, right: -2_000)])

    public static let boomRefuel = MissionDefinition(
        id: "boom-refuel", title: "Boom Refuel", category: .military,
        briefing: "Catch the tanker on its racetrack and hold the boom envelope behind it until 800 kg has transferred. Stable contact only: a relative speed above 2 m/s drops the connection.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfT1Jet.id, allowedRoles: jets,
        spawn: MissionSpawn(along: 2_000, up: 3_000, speed: .fixed(170)),
        targets: [
            TargetSpawn(id: "tanker", role: .friendly, along: 6_000, right: -2_500, up: 3_000, speed: 150,
                        behavior: .route(points: [MissionWaypoint(6_000, -2_500, 3_000), MissionWaypoint(12_000, -2_500, 3_000),
                                                   MissionWaypoint(12_000, 2_500, 3_000), MissionWaypoint(6_000, 2_500, 3_000)],
                                         loop: true)),
        ],
        objectives: [
            MissionObjective(id: "boom", title: "Take 800 kg on the boom", kind: .refuel(tankerID: "tanker", method: .boom, kilograms: 800), points: 400),
        ],
        parTime: 300, timeLimit: 900, areaRadius: 40_000, unlock: .mission("wingman-formation"))

    public static let formationEscort = MissionDefinition(
        id: "formation-escort", title: "Formation Escort", category: .military,
        briefing: "Your flight lead and two AI wingmen fly the route. Join echelon right on the lead, then hold that slot through the turns. The AI wingmen keep their own slots.",
        difficulty: 3, recommendedAircraft: AircraftCatalog.sfT1Jet.id, allowedRoles: jets,
        spawn: MissionSpawn(along: 650, right: 90, up: 900, speed: .fixed(150)),
        targets: [
            TargetSpawn(id: "lead", role: .friendly, along: 1_000, right: 0, up: 900, speed: 140,
                        behavior: .route(points: [MissionWaypoint(7_000, 0, 900), MissionWaypoint(9_000, 3_500, 1_000),
                                                   MissionWaypoint(6_000, 7_000, 900), MissionWaypoint(-2_000, 5_000, 900)], loop: false)),
            TargetSpawn(id: "wing-left", role: .friendly, along: 940, right: -60, up: 900, speed: 140,
                        behavior: .follow(leaderID: "lead", slot: .echelonLeft, spacing: 60)),
            TargetSpawn(id: "wing-trail", role: .friendly, along: 910, right: 0, up: 900, speed: 140,
                        behavior: .follow(leaderID: "lead", slot: .trail, spacing: 60)),
        ],
        objectives: [
            MissionObjective(id: "join", title: "Join echelon right", kind: .formation(leaderID: "lead", slot: .echelonRight, spacing: 60, tolerance: 45, hold: 30), points: 150),
            MissionObjective(id: "turns", title: "Hold through the turns", kind: .formation(leaderID: "lead", slot: .echelonRight, spacing: 60, tolerance: 45, hold: 60), points: 250),
        ],
        parTime: 240, timeLimit: 600, areaRadius: 30_000, unlock: .mission("wingman-formation"))


    public static func mission(id: String) -> MissionDefinition? { all.first { $0.id == id } }
    public static func missions(in category: MissionCategory) -> [MissionDefinition] { all.filter { $0.category == category } }

    public static let all: [MissionDefinition] = [firstFlight, patternLanding, precisionLanding, wingman, intercept, gunnery, lowLevel, dogfight, coastalSurvey, twinBandits, bushStrip, airportTour, valleyRun, waterDropRun, rescuePickup, airshowLoop, radarIntercept, twoShipDefence, ifrApproach, cargoRun, engineOutLanding, scooperFirefight, gateRun, aileronRollPractice, sarGridSearch, sarMedevacStrip, sarTwoSurvivors, boomRefuel, formationEscort]
}
