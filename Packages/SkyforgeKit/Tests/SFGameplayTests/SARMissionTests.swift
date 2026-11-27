// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFGameplay

/// One spot objective on a survivor 500 m down the runway, with an optional objective time limit.
private func spotMission(objectiveTimeLimit: Double? = nil) -> MissionDefinition {
    MissionDefinition(
        id: "spot-test", title: "Spot", category: .rescue, briefing: "",
        difficulty: 1, recommendedAircraft: AircraftCatalog.sf1Trainer.id,
        spawn: MissionSpawn(along: 0, up: 100),
        objectives: [MissionObjective(id: "spot", title: "Spot",
                                      kind: .spotSurvivor(survivorID: "s", within: 150, maxAGL: 200, hold: 5),
                                      points: 100, timeLimit: objectiveTimeLimit)],
        parTime: 100, timeLimit: nil, areaRadius: nil,
        survivors: [SurvivorSpawn(id: "s", along: 500, right: 0)])
}

/// Samples every 0.5 s for `seconds`, flying past the survivor at the given height and sideways offset.
private func overflight(height: Double, offset: Double = 0, seconds: Double) -> [FlightSample] {
    stride(from: 0.0, through: seconds, by: 0.5).map { t in
        FlightSample(time: t, positionNED: testFrame.ned(along: 500, right: offset, up: height),
                     velocityNED: SIMD3(50, 0, 0), heightAGL: height, onGround: false)
    }
}

@Suite struct SARMissionTests {
    @Test func holdingOverTheSurvivorInViewCompletesTheSpot() {
        var rt = MissionRuntime(mission: spotMission(), frame: testFrame, aircraftID: "x")
        for s in overflight(height: 150, seconds: 8) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .succeeded)
    }

    @Test func flyingTooHighDoesNotSpotTheSurvivor() {
        var rt = MissionRuntime(mission: spotMission(), frame: testFrame, aircraftID: "x")
        for s in overflight(height: 400, seconds: 20) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .inProgress)
    }

    @Test func aSightingOutsideTheRadiusDoesNotCount() {
        var rt = MissionRuntime(mission: spotMission(), frame: testFrame, aircraftID: "x")
        for s in overflight(height: 150, offset: 300, seconds: 20) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .inProgress)
    }

    @Test func theSpotFailsWhenTheObjectiveRunsOutOfTime() {
        var rt = MissionRuntime(mission: spotMission(objectiveTimeLimit: 3), frame: testFrame, aircraftID: "x")
        for s in overflight(height: 400, seconds: 10) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .failed("Out of time: Spot"))
    }

    @Test func aSpotNeedsAKnownSurvivor() {
        var m = spotMission()
        m.survivors = []
        #expect(m.validationProblems.contains("spot: unknown survivor id"))
    }

    @Test func theSearchAndRescueLineIsSoundAndChained() {
        let missions = [MissionCatalog.sarGridSearch, MissionCatalog.sarMedevacStrip, MissionCatalog.sarTwoSurvivors]
        for m in missions {
            #expect(m.validationProblems.isEmpty, "\(m.id): \(m.validationProblems)")
            #expect(m.category == .rescue, "\(m.id)")
        }
        #expect(MissionCatalog.sarGridSearch.unlock == .mission("rescue-pickup"))
        #expect(MissionCatalog.sarMedevacStrip.unlock == .mission("sar-grid-search"))
        #expect(MissionCatalog.sarTwoSurvivors.unlock == .mission("sar-medevac-strip"))
        #expect(MissionCatalog.missions(in: .rescue).count == 3)
    }
}
