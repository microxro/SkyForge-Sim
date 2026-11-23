import Testing
import Foundation
@testable import SFGameplay

@Suite struct TowerScoringTests {

    /// Runs a survive mission to its end with `towerErrors` reported on every sample, and returns the result.
    private func finish(towerErrors: Int) -> MissionResult? {
        var rt = MissionRuntime(mission: oneObjectiveMission(.survive(seconds: 5)), frame: testFrame, aircraftID: "x")
        var step = 0
        while step <= 80 && rt.status == .inProgress {
            rt.update(sample: airborne(t: Double(step) * 0.1), targets: [], towerErrors: towerErrors)
            step += 1
        }
        return rt.result
    }

    @Test func towerErrorsCostPointsOnASuccess() throws {
        let clean = try #require(finish(towerErrors: 0))
        let dirty = try #require(finish(towerErrors: 2))
        #expect(clean.success && dirty.success)
        let penalty = MissionRuntime.towerErrorPoints * 2
        #expect(dirty.breakdown["tower penalty"] == -penalty)
        #expect(clean.score - dirty.score == penalty)
    }

    @Test func aCleanTowerRecordAddsNoPenalty() throws {
        let clean = try #require(finish(towerErrors: 0))
        #expect(clean.breakdown["tower penalty"] == nil)
    }
}
