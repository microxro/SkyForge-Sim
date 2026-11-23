// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFGameplay

@Suite struct EngineOutTests {
    private let world = FlatWorld()

    @Test func aMissionEngineFailureStopsTheEngineAtItsTime() {
        var m = oneObjectiveMission(.flyTo(MissionWaypoint(9_000, 0, 900, radius: 400)))
        m.engineFailureAt = 1.0
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sfCruiser, mission: m)
        #expect(s.enginesRunning == AircraftCatalog.sfCruiser.config.propulsion?.engineCount ?? 1)
        for _ in 0..<60 { s.update(realDt: 0.05, controls: PilotControls()) }
        #expect(s.enginesRunning == max(0, (AircraftCatalog.sfCruiser.config.propulsion?.engineCount ?? 1) - 1),
                "the first engine did not fail at its set time")
    }

    @Test func aMissionWithoutAnEngineFailureKeepsEveryEngine() {
        let m = oneObjectiveMission(.flyTo(MissionWaypoint(9_000, 0, 900, radius: 400)))
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sfCruiser, mission: m)
        for _ in 0..<60 { s.update(realDt: 0.05, controls: PilotControls()) }
        #expect(s.enginesRunning == (AircraftCatalog.sfCruiser.config.propulsion?.engineCount ?? 1))
    }

    @Test func theDeadStickLandingMissionFailsTheEngineAfterTwentySeconds() {
        #expect(MissionCatalog.engineOutLanding.engineFailureAt == 20)
        #expect(MissionCatalog.engineOutLanding.validationProblems.isEmpty)
    }
}
