// SKYFORGE — Apache-2.0
// Generated mission library. Four parameterised mission families (scenic tours, touchdown targets,
// freight runs, medevac pickups, drone range shoots) built on the same runway-frame MissionDefinition
// model as MissionCatalog, so every mission runs at any airport. Generation is deterministic: the same
// index always produces the same mission.
import Foundation
import SFFlightModel

public enum MissionLibrary {
    private static let civil: [AircraftRole] = [.lightTrainer, .tourer, .aerobatic]
    private static let jets: [AircraftRole] = [.jetTrainer, .fighter]

    /// Every generated mission, in a stable order.
    public static let generated: [MissionDefinition] = {
        var out: [MissionDefinition] = []
        out += (0..<60).map { MissionLibrary.scenicTour($0) }
        out += (0..<60).map { MissionLibrary.touchdownTarget($0) }
        out += (0..<30).map { MissionLibrary.freightRun($0) }
        out += (0..<30).map { MissionLibrary.medevac($0) }
        out += (0..<40).map { MissionLibrary.droneRange($0) }
        return out
    }()

    /// Handcrafted campaign missions followed by the generated library.
    public static let all: [MissionDefinition] = MissionCatalog.all + generated

    public static func mission(id: String) -> MissionDefinition? { all.first { $0.id == id } }

    // MARK: Scenic tours (civil navigation)

    static func scenicTour(_ i: Int) -> MissionDefinition {
        let legs = 3 + i % 4
        let radius: Double = 3_000 + Double(i % 7) * 800
        var objectives = [MissionObjective(id: "airborne", title: "Take off", kind: .takeoff(minHeightAGL: 30), points: 50)]
        for k in 0..<legs {
            let a = Double(k) / Double(legs) * 2 * Double.pi
            let wp = MissionWaypoint(radius + radius * cos(a), radius * sin(a), 300 + Double(k % 3) * 100, radius: 500)
            objectives.append(MissionObjective(id: "leg-\(k + 1)", title: "Pass point \(k + 1)", kind: .flyTo(wp), points: 100))
        }
        objectives.append(MissionObjective(id: "home", title: "Back over the runway",
                                           kind: .flyTo(MissionWaypoint(60, 0, 250, radius: 400)), points: 100))
        return MissionDefinition(
            id: "tour-\(i + 1)", title: "Scenic Tour \(i + 1)", category: .navigation,
            briefing: "Take off and fly \(legs) points around the field at 1,000 to 1,600 ft, then return over the runway.",
            difficulty: 1 + i % 3, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
            spawn: MissionSpawn(along: 60, onRunway: true), objectives: objectives,
            parTime: 420 + Double(legs) * 60, timeLimit: 900, areaRadius: 30_000)
    }

    // MARK: Touchdown targets (landing)

    static func touchdownTarget(_ i: Int) -> MissionDefinition {
        let zone: Double = max(60, 220 - Double(i % 6) * 25)
        return MissionDefinition(
            id: "touchdown-\(i + 1)", title: "Touchdown Target \(i + 1)", category: .landing,
            briefing: "Land inside a \(Int(zone * 2)) m touchdown zone with a gentle sink rate. Gusty wind comes through the approach.",
            difficulty: 2 + i % 3, recommendedAircraft: AircraftCatalog.sf1Trainer.id, allowedRoles: civil,
            spawn: MissionSpawn(along: -1_500 - Double(i % 4) * 300, up: 200, speed: .approach, flaps: 0.5),
            wind: MissionWind(fromRelativeDegrees: Double((i * 37) % 360), knots: Double(i % 5) * 3),
            objectives: [MissionObjective(id: "land", title: "Land in the zone",
                                          kind: .land(aimAlong: 300, zoneHalfLength: zone, maxSinkRate: 2.5), points: 300)],
            parTime: 150, timeLimit: 420, areaRadius: 10_000, traffic: i % 2 == 0)
    }

    // MARK: Freight runs (cargo with payload)

    static func freightRun(_ i: Int) -> MissionDefinition {
        let kg: Double = 120 + Double(i % 6) * 40
        let distance: Double = 2_000 + Double(i % 5) * 700
        let grass = i % 2 == 1
        return MissionDefinition(
            id: "freight-\(i + 1)", title: "Freight Run \(i + 1)", category: .navigation,
            briefing: "Load \(Int(kg)) kg of freight in the rear hold and fly it \(Int(distance)) m out to the \(grass ? "grass strip" : "paved field"). The load moves the centre of gravity aft, so keep the approach gentle.",
            difficulty: 2, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
            spawn: MissionSpawn(along: 0, onRunway: true),
            objectives: [MissionObjective(id: "deliver", title: "Fly the freight to the strip",
                                          kind: .flyTo(MissionWaypoint(distance, 0, 60, radius: 400)), points: 300)],
            parTime: 300, timeLimit: 600, areaRadius: 20_000,
            payload: [PayloadStation(name: "Rear hold", mass: kg, arm: -0.3)],
            surface: grass ? .grass : .paved)
    }

    // MARK: Medevac pickups (rescue)

    static func medevac(_ i: Int) -> MissionDefinition {
        let pickupAlong: Double = 1_000 + Double(i % 6) * 250
        let hospital: Double = 6_000 + Double(i % 4) * 500
        return MissionDefinition(
            id: "medevac-\(i + 1)", title: "Medevac \(i + 1)", category: .navigation,
            briefing: "A patient is waiting \(Int(pickupAlong)) m down a meadow strip. Land, stop beside them for three seconds, then fly them to the hospital.",
            difficulty: 3 + i % 2, recommendedAircraft: AircraftCatalog.sfCruiser.id, allowedRoles: civil,
            spawn: MissionSpawn(along: -2_000, up: 150, speed: .approach),
            objectives: [
                MissionObjective(id: "pickup", title: "Land and stop beside the patient",
                                 kind: .pickup(MissionWaypoint(pickupAlong, 120, 0, radius: 60), maxSpeed: 8, hold: 3), points: 250),
                MissionObjective(id: "hospital", title: "Fly to the hospital",
                                 kind: .flyTo(MissionWaypoint(hospital, -600, 400, radius: 500)), points: 250),
            ],
            parTime: 300, timeLimit: 600, areaRadius: 30_000, surface: .grass)
    }

    // MARK: Drone range (military)

    static func droneRange(_ i: Int) -> MissionDefinition {
        let count = 2 + i % 3
        let range: Double = 3_000 + Double(i % 5) * 600
        var targets: [TargetSpawn] = []
        for k in 0..<count {
            let right: Double = (k % 2 == 0 ? -1 : 1) * (400 + Double(k) * 350)
            let behavior: MissionTargetBehavior = k % 2 == 0 ? .straight : .orbit(turnRate: 0.05)
            targets.append(TargetSpawn(id: "drone-\(k + 1)", role: .hostile, along: range + Double(k) * 900,
                                       right: right, up: 1_500 + Double(k % 2) * 200, speed: 90 + Double(k) * 5,
                                       behavior: behavior, health: 6))
        }
        return MissionDefinition(
            id: "range-\(i + 1)", title: "Drone Range \(i + 1)", category: .military,
            briefing: "\(count) target drones are spread over the range. Destroy all of them with cannon or missiles.",
            difficulty: 2 + i % 3, recommendedAircraft: AircraftCatalog.sfT1Jet.id, allowedRoles: jets,
            spawn: MissionSpawn(along: 0, up: 1_500, speed: .fixed(150)),
            targets: targets,
            objectives: [MissionObjective(id: "clear", title: "Destroy all \(count) drones",
                                          kind: .destroy(targetIDs: targets.map(\.id)), points: 300)],
            parTime: 200, timeLimit: 420, areaRadius: 25_000)
    }
}
