import Testing
@testable import SFChallenge

@Suite struct AerobaticsTests {
    /// Feeds constant rates for `seconds` at 60 Hz, starting from `start`.
    func feed(_ d: inout FigureDetector, from start: Double, seconds: Double,
              pitch: Double, roll: Double, speed: Double = 70, altitude: Double = 1_000) -> [FigureResult] {
        var out: [FigureResult] = []
        var t = start
        while t <= start + seconds + 1e-9 {
            out += d.process(AerobaticSample(time: t, pitchRate: pitch, rollRate: roll,
                                             altitude: altitude, airspeed: speed))
            t += 1.0 / 60
        }
        return out
    }

    @Test func fastAileronRollIsDetected() {
        var d = FigureDetector()
        // 2.5 rad/s takes about 2.26 s for 324 degrees.
        let r = feed(&d, from: 0, seconds: 4, pitch: 0, roll: 2.5)
        #expect(r.count == 1)
        #expect(r.first?.kind == .aileronRoll)
        #expect(r.first?.direction == 1)
    }

    @Test func negativeRollHasNegativeDirection() {
        var d = FigureDetector()
        let r = feed(&d, from: 0, seconds: 4, pitch: 0, roll: -2.5)
        #expect(r.first?.direction == -1)
    }

    @Test func gentleBankIsNotAFigure() {
        var d = FigureDetector()
        let r = feed(&d, from: 0, seconds: 30, pitch: 0.1, roll: 0.1)
        #expect(r.isEmpty)
    }

    @Test func reversingRollIsNotAFigure() {
        var d = FigureDetector()
        var r = feed(&d, from: 0, seconds: 1, pitch: 0, roll: 2.5)
        r += feed(&d, from: 1, seconds: 1, pitch: 0, roll: -2.5)
        #expect(r.isEmpty)
    }

    @Test func rollWithPitchWanderIsRejected() {
        var d = FigureDetector()
        // Rolling while pitching: the pitch integral exceeds 30 degrees, so it is not a clean roll.
        let r = feed(&d, from: 0, seconds: 4, pitch: 0.5, roll: 2.5)
        #expect(r.isEmpty)
    }

    @Test func scoreFullAtTargetSpeedNoAltitudeLoss() {
        #expect(FigureScoring.basePoints(kind: .aileronRoll, minAirspeed: 60, altitudeLoss: 0) == 60)
    }

    @Test func scoreZeroBelowFloorSpeed() {
        #expect(FigureScoring.basePoints(kind: .aileronRoll, minAirspeed: 35, altitudeLoss: 0) == 0)
    }

    @Test func altitudeLossHalvesScore() {
        #expect(FigureScoring.basePoints(kind: .aileronRoll, minAirspeed: 60, altitudeLoss: 100) == 30)
        #expect(FigureScoring.basePoints(kind: .aileronRoll, minAirspeed: 60, altitudeLoss: 500) == 30)
    }

    @Test func linkedFiguresEarnMultiplier() {
        var scorer = AerobaticScorer()
        let a = FigureResult(kind: .aileronRoll, startTime: 0, endTime: 2, direction: 1, minAirspeed: 60, altitudeLoss: 0)
        let b = FigureResult(kind: .aileronRoll, startTime: 5, endTime: 7, direction: 1, minAirspeed: 60, altitudeLoss: 0)
        let c = FigureResult(kind: .aileronRoll, startTime: 60, endTime: 62, direction: 1, minAirspeed: 60, altitudeLoss: 0)
        scorer.record(a)
        let second = scorer.record(b)
        let third = scorer.record(c)
        #expect(abs(second.multiplier - 1.1) < 1e-9)
        #expect(third.multiplier == 1.0)
        #expect(abs(scorer.total - (60 + 66 + 60)) < 1e-6)
    }
}
