import Testing
@testable import SFChallenge

@Suite struct RaceAndLandingTests {
    static let gates = [
        RaceGate(center: SIMD3(100, 0, 0), normal: SIMD3(1, 0, 0), radius: 20),
        RaceGate(center: SIMD3(200, 0, 0), normal: SIMD3(1, 0, 0), radius: 20),
        RaceGate(center: SIMD3(300, 0, 0), normal: SIMD3(1, 0, 0), radius: 20),
    ]

    /// Flies from `x0` to `x1` at 10 m/s, sampled every 0.1 s, with a fixed offset from the gate line.
    func fly(_ race: inout AirRace, from x0: Double, to x1: Double, y: Double = 0) {
        var t = 0.0
        var x = x0
        while x <= x1 + 1e-9 {
            race.update(position: SIMD3(x, y, 0), time: t)
            x += 1; t += 0.1
        }
    }

    @Test func straightThroughTimesTheCourse() {
        var race = AirRace(gates: Self.gates)
        fly(&race, from: 0, to: 400)
        #expect(race.isFinished)
        #expect(race.missedCount == 0)
        if let total = race.totalTime { #expect(abs(total - 20) < 0.2, "total \(total)") }
        #expect(race.penalizedTime == race.totalTime)
    }

    @Test func missedGateAddsPenalty() {
        var gates = Self.gates
        gates[1].center = SIMD3(200, 50, 0)   // path at y=0 is 50 m off this gate
        var race = AirRace(gates: gates)
        fly(&race, from: 0, to: 400)
        #expect(race.missedCount == 1)
        if let total = race.totalTime, let penalized = race.penalizedTime {
            #expect(abs(penalized - total - AirRace.missPenalty) < 1e-9)
        } else {
            Issue.record("race should be finished")
        }
    }

    @Test func flyingBackwardsDoesNotPass() {
        var race = AirRace(gates: Self.gates)
        fly(&race, from: 400, to: 0)
        #expect(race.events.isEmpty)
        #expect(race.totalTime == nil)
    }

    @Test func goodLandingScoresFull() {
        var ev = LandingEvaluator()
        ev.process(LandingSample(time: 0, onGround: false, groundSpeed: 40, descentRate: 0.8, along: 200, lateral: 0.5, bank: 0.01))
        ev.process(LandingSample(time: 1, onGround: true, groundSpeed: 35, descentRate: 0.8, along: 250, lateral: 0.5, bank: 0.01))
        ev.process(LandingSample(time: 20, onGround: true, groundSpeed: 0.5, descentRate: 0, along: 500, lateral: 0.5, bank: 0))
        #expect(ev.result?.total == 100)
        #expect(ev.result?.overran == false)
    }

    @Test func longLandingLosesZonePoints() {
        var ev = LandingEvaluator()
        ev.process(LandingSample(time: 1, onGround: true, groundSpeed: 35, descentRate: 0.8, along: 900, lateral: 0, bank: 0))
        ev.process(LandingSample(time: 20, onGround: true, groundSpeed: 0.5, descentRate: 0, along: 1_000, lateral: 0, bank: 0))
        #expect(ev.result?.zonePoints == 0)
        #expect(ev.result?.total == 60)
    }

    @Test func hardLandingLosesDescentPoints() {
        var ev = LandingEvaluator()
        ev.process(LandingSample(time: 1, onGround: true, groundSpeed: 35, descentRate: 4, along: 250, lateral: 0, bank: 0))
        ev.process(LandingSample(time: 20, onGround: true, groundSpeed: 0.5, descentRate: 0, along: 500, lateral: 0, bank: 0))
        #expect(ev.result?.descentPoints == 7.5)
    }

    @Test func overrunScoresZero() {
        var ev = LandingEvaluator()
        ev.process(LandingSample(time: 1, onGround: true, groundSpeed: 35, descentRate: 0.5, along: 250, lateral: 0, bank: 0))
        ev.process(LandingSample(time: 60, onGround: true, groundSpeed: 0.5, descentRate: 0, along: 1_600, lateral: 0, bank: 0))
        #expect(ev.result?.overran == true)
        #expect(ev.result?.total == 0)
    }
}
