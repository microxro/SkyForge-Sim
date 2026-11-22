import Foundation
import SFMath
import SFFlightModel
import SFQuickFlight
@testable import SFGameplay

/// Flat world with a 1,500 m north-pointing runway at 10 m elevation.
struct FlatWorld: FlightWorld {
    var runwayThreshold = SIMD2<Double>(0, 0)
    var runwayHeading = 0.0
    var runwayLengthMetres = 1_500.0
    var runwayElevation = 10.0
    func height(_ x: Double, _ y: Double) -> Double { 10 }
}

let testFrame = RunwayFrame(threshold: .zero, heading: 0, length: 1_500, elevation: 10)

func airborne(_ frame: RunwayFrame = testFrame, along: Double = 0, right: Double = 0, up: Double = 100,
              velocity: SIMD3<Double> = SIMD3(50, 0, 0), t: Double) -> FlightSample {
    FlightSample(time: t, positionNED: frame.ned(along: along, right: right, up: up), velocityNED: velocity,
                 heightAGL: up, onGround: false)
}

func oneObjectiveMission(_ kind: ObjectiveKind, targets: [TargetSpawn] = [], par: Double = 100,
                         limit: Double? = nil, points: Int = 100) -> MissionDefinition {
    MissionDefinition(id: "t", title: "T", category: .training, briefing: "", difficulty: 1,
                      recommendedAircraft: AircraftCatalog.sf1Trainer.id, spawn: MissionSpawn(along: 0, up: 100),
                      targets: targets, objectives: [MissionObjective(id: "o", title: "O", kind: kind, points: points)],
                      parTime: par, timeLimit: limit, areaRadius: nil)
}
