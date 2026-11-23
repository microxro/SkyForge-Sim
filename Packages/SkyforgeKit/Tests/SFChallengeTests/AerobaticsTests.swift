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

    @Test func steadyLoopIsDetected() {
        var d = FigureDetector()
        // 1 rad/s pitch takes 5.66 s for 324 degrees.
        let r = feed(&d, from: 0, seconds: 7, pitch: 1, roll: 0)
        #expect(r.count == 1)
        #expect(r.first?.kind == .loop)
        #expect(r.first?.direction == 1)
    }

    @Test func negativeLoopHasNegativeDirection() {
        var d = FigureDetector()
        let r = feed(&d, from: 0, seconds: 7, pitch: -1, roll: 0)
        #expect(r.first?.direction == -1)
    }

    @Test func fastAileronRollIsDetected() {
        var d = FigureDetector()
        let r = feed(&d, from: 0, seconds: 4, pitch: 0, roll: 2.5)
        #expect(r.count == 1)
        #expect(r.first?.kind == .aileronRoll)
    }

    @Test func gentleTurnIsNotAFigure() {
        var d = FigureDetector()
        let r = feed(&d, from: 0, seconds: 30, pitch: 0.1, roll: 0.1)
        #expect(r.isEmpty)
    }

    @Test func reversingPitchIsNotALoop() {
        var d = FigureDetector()
        var r = feed(&d, from: 0, seconds: 3, pitch: 1, roll: 0)
        r += feed(&d, from: 3, seconds: 3, pitch: -1, roll: 0)
        #expect(r.isEmpty)
    }

    @Test func loopWithRollWanderIsRejected() {
        var d = FigureDetector()
        // Pitching while banked: the roll integral exceeds 60 degrees, so it is not a clean loop.
        let r = feed(&d, from: 0, seconds: 7, pitch: 1, roll: 0.5)
        #expect(r.isEmpty)
    }

    @Test func scoreFullAtTargetSpeedNoAltitudeLoss() {
        #expect(FigureScoring.basePoints(kind: .loop, minAirspeed: 70, altitudeLoss: 0) == 100)
    }

    @Test func scoreZeroBelowFloorSpeed() {
        #expect(FigureScoring.basePoints(kind: .loop, minAirspeed: 40, altitudeLoss: 0) == 0)
    }

    @Test func altitudeLossHalvesScore() {
        #expect(FigureScoring.basePoints(kind: .loop, minAirspeed: 70, altitudeLoss: 100) == 50)
        #expect(FigureScoring.basePoints(kind: .loop, minAirspeed: 70, altitudeLoss: 500) == 50)
    }

    @Test func linkedFiguresEarnMultiplier() {
        var scorer = AerobaticScorer()
        let a = FigureResult(kind: .loop, startTime: 0, endTime: 6, direction: 1, minAirspeed: 70, altitudeLoss: 0)
        let b = FigureResult(kind: .loop, startTime: 10, endTime: 16, direction: 1, minAirspeed: 70, altitudeLoss: 0)
        let c = FigureResult(kind: .loop, startTime: 60, endTime: 66, direction: 1, minAirspeed: 70, altitudeLoss: 0)
        scorer.record(a)
        let second = scorer.record(b)
        let third = scorer.record(c)
        #expect(abs(second.multiplier - 1.1) < 1e-9)
        #expect(third.multiplier == 1.0)
        #expect(abs(scorer.total - (100 + 110 + 100)) < 1e-6)
    }
}
