import Testing
import Foundation
import SFFlightModel
@testable import SFATC
@testable import SFTraffic

/// A north-pointing runway, which the tower calls runway 36.
private let northRunway = TrafficRunway(threshold: SIMD2<Double>(0, 0), heading: 0, length: 2_000, elevation: 0)
private let calm = ATCWind(fromDegrees: 0, knots: 0)
private let takeoffOption = "cleared for takeoff runway three six"
private let landingOption = "cleared to land runway three six"

/// Ownship at a runway-frame position, moving north at `speed`.
private func ownship(onGround: Bool, speed: Double = 0, along: Double, right: Double = 0, height: Double) -> OwnshipReport {
    OwnshipReport(config: AircraftConfig.sf1Trainer,
                  positionNED: northRunway.ned(along: along, right: right, up: height),
                  velocityNED: SIMD3<Double>(speed, 0, 0), onGround: onGround)
}

/// A tower-view snapshot with every field given.
private func snapshot(id: String, callsign: String, kind: TrafficKind, phase: TrafficPhase,
                      clearedToLand: Bool = false, clearedToTakeoff: Bool = false) -> TrafficSnapshot {
    TrafficSnapshot(id: id, callsign: callsign, typeName: "SF-1 Trainer", kind: kind, phase: phase,
                    positionNED: SIMD3<Double>(0, 0, 0), heading: 0, speed: 30,
                    heightAboveRunway: 200, alongRunway: 500, distanceToTouchdown: 2_000,
                    isHeavy: false, clearedToLand: clearedToLand, clearedToTakeoff: clearedToTakeoff)
}

@Suite struct TowerSessionTests {

    /// Steps the session in 0.1 s ticks with ownship held at `report`, and returns every instruction the tower gave.
    private func run(_ tower: inout TowerSession, seconds: Double, report: OwnshipReport) -> [ATCInstruction] {
        var given: [ATCInstruction] = []
        for _ in 0..<Int((seconds / 0.1).rounded()) {
            if let instructions = tower.step(dt: 0.1, ownship: report, wind: calm) {
                given += instructions
            }
        }
        return given
    }

    // MARK: - Takeoff

    @Test func takeoffNeedsTheReadbackBeforeItCounts() throws {
        var tower = TowerSession(runway: northRunway, startsOnRunway: true)
        let hold = ownship(onGround: true, along: 0, height: 0)
        let given = run(&tower, seconds: 1, report: hold)

        let prompt = try #require(tower.prompt)
        #expect(prompt.clearance == .takeoff)
        #expect(given.contains { $0.aircraftID == TrafficOwnship.id && $0.clearance == .takeoff })
        #expect(prompt.options.count == 3)

        let correct = try #require(prompt.options.firstIndex(of: takeoffOption))
        #expect(tower.readback(choice: correct) == true)
        #expect(tower.prompt == nil)
        #expect(tower.status.takeoffCleared)

        // Rolling after a correct readback is clean.
        _ = run(&tower, seconds: 1, report: ownship(onGround: true, speed: 15, along: 300, height: 0))
        #expect(tower.status.unauthorizedTakeoffs == 0)
    }

    @Test func wrongReadbackSaysAgainAndKeepsThePrompt() throws {
        var tower = TowerSession(runway: northRunway, startsOnRunway: true)
        _ = run(&tower, seconds: 1, report: ownship(onGround: true, along: 0, height: 0))

        let prompt = try #require(tower.prompt)
        let correct = try #require(prompt.options.firstIndex(of: takeoffOption))
        let wrong = (correct + 1) % prompt.options.count
        #expect(tower.readback(choice: wrong) == false)
        #expect(tower.prompt != nil)
        #expect(tower.lines.last == "N one zero zero, negative, say again.")
        #expect(!tower.status.takeoffCleared)
    }

    @Test func rollingWithoutAReadbackIsCounted() {
        var tower = TowerSession(runway: northRunway, startsOnRunway: true)
        _ = run(&tower, seconds: 1, report: ownship(onGround: true, along: 0, height: 0))
        // The pilot rolls without answering the prompt.
        _ = run(&tower, seconds: 1, report: ownship(onGround: true, speed: 15, along: 300, height: 0))
        #expect(tower.status.unauthorizedTakeoffs == 1)
        #expect(tower.lines.contains("N one zero zero, no takeoff clearance read back."))
    }

    @Test func noPromptMeansNoAnswer() {
        var tower = TowerSession(runway: northRunway, startsOnRunway: true)
        #expect(tower.prompt == nil)
        #expect(tower.readback(choice: 0) == nil)
    }

    // MARK: - Landing

    @Test func landingNeedsTheReadbackAndLandingWithoutItIsCounted() throws {
        var tower = TowerSession(runway: northRunway, startsOnRunway: false)
        // On the base leg, airborne: the tower clears the landing.
        _ = run(&tower, seconds: 1, report: ownship(onGround: false, speed: 30, along: -1_000, right: 500, height: 130))
        let prompt = try #require(tower.prompt)
        #expect(prompt.clearance == .land)

        // Touch down without answering.
        _ = run(&tower, seconds: 1, report: ownship(onGround: true, speed: 20, along: 200, height: 0))
        #expect(tower.status.unclearedLandings == 1)
        #expect(!tower.status.landingCleared)
    }

    @Test func landingWithTheReadbackIsClean() throws {
        var tower = TowerSession(runway: northRunway, startsOnRunway: false)
        _ = run(&tower, seconds: 1, report: ownship(onGround: false, speed: 30, along: -1_000, right: 500, height: 130))
        let prompt = try #require(tower.prompt)
        let correct = try #require(prompt.options.firstIndex(of: landingOption))
        #expect(tower.readback(choice: correct) == true)

        _ = run(&tower, seconds: 1, report: ownship(onGround: true, speed: 20, along: 200, height: 0))
        #expect(tower.status.landingCleared)
        #expect(tower.status.unclearedLandings == 0)
    }

    // MARK: - Sequencing

    @Test func ownshipWaitsBehindAnArrivalOnFinal() {
        var atc = ATCController(runwayDesignator: "36")
        let own = snapshot(id: TrafficOwnship.id, callsign: TrafficOwnship.callsign, kind: .departure, phase: .holdShort)
        let arrival = snapshot(id: "A1", callsign: "SKY417", kind: .arrival, phase: .final)
        let given = atc.update(time: 0, traffic: [own, arrival], wind: calm)
        #expect(given.allSatisfy { $0.clearance != .takeoff })
        #expect(atc.ownshipPrompt == nil)
    }

    @Test func readbackOptionsHaveOneCorrectAnswer() throws {
        var atc = ATCController(runwayDesignator: "36")
        let base = snapshot(id: TrafficOwnship.id, callsign: TrafficOwnship.callsign, kind: .arrival, phase: .base)
        let given = atc.update(time: 4, traffic: [base], wind: calm)
        let clearance = try #require(given.first { $0.clearance == .land })
        let readback = try #require(clearance.readback)
        #expect(readback.options.count == 3)
        #expect(Set(readback.options).count == 3)
        #expect(readback.options[readback.correctIndex] == landingOption)
        // The correct place follows the time: 4 s is slot 1.
        #expect(readback.correctIndex == 1)
    }

    @Test func aiClearancesDoNotCarryAReadback() {
        var atc = ATCController(runwayDesignator: "36")
        let base = snapshot(id: "T1", callsign: "SKY417", kind: .arrival, phase: .base)
        let given = atc.update(time: 0, traffic: [base], wind: calm)
        #expect(given.contains { $0.clearance == .land })
        #expect(given.allSatisfy { $0.readback == nil })
        #expect(atc.ownshipPrompt == nil)
    }
}
