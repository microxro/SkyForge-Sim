// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFGameplay

@Suite struct ScooperMissionTests {
    @Test func theScooperMissionIsSoundAndUsesTheWaterSurface() {
        let m = MissionCatalog.scooperFirefight
        #expect(m.validationProblems.isEmpty, "\(m.validationProblems)")
        #expect(m.surface == .water)
        #expect(m.objectives.count == 2)
    }

    @Test func theScoopStartsEmpty() {
        let s = GameplaySession(world: FlatWorld(), aircraft: AircraftCatalog.sfCruiser, mission: MissionCatalog.scooperFirefight)
        #expect(s.scoop.load == 0, "the tank should start empty before any skim")
    }
}
