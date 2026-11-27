import Testing
import Foundation
@testable import SFGameplay

@Suite struct MissionLibraryTests {
    @Test func generatedCountMatchesFamilies() {
        #expect(MissionLibrary.generated.count == 220)
    }

    @Test func idsAreUniqueAndDoNotClashWithCatalog() {
        let ids = MissionLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyGeneratedMissionIsSound() {
        for m in MissionLibrary.generated {
            #expect(m.validationProblems.isEmpty, "\(m.id): \(m.validationProblems)")
            #expect(!m.briefing.isEmpty, "\(m.id)")
            #expect((1...5).contains(m.difficulty), "\(m.id)")
            #expect(m.maxBasePoints > 0, "\(m.id)")
        }
    }

    @Test func recommendedAircraftExistsAndIsAllowed() {
        for m in MissionLibrary.generated {
            guard let spec = AircraftCatalog.spec(id: m.recommendedAircraft) else {
                Issue.record("\(m.id): unknown aircraft \(m.recommendedAircraft)")
                continue
            }
            #expect(m.allows(spec), "\(m.id)")
        }
    }

    @Test func generationIsDeterministic() {
        #expect(MissionLibrary.scenicTour(7) == MissionLibrary.scenicTour(7))
        #expect(MissionLibrary.droneRange(3) == MissionLibrary.droneRange(3))
    }
}
