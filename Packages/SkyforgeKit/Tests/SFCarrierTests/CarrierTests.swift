import Testing
import Foundation
import SFCarrier

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

@Suite struct CarrierDeckTests {
    @Test func calmSeaHeadwindEqualsShipSpeed() {
        let deck = CarrierDeck.standard(heading: 0, speed: 15)
        #expect(near(deck.headwind(trueWind: .zero), 15))
        #expect(near(deck.crosswind(trueWind: .zero), 0))
    }

    @Test func trueWindFromBowAddsToHeadwind() {
        // Air moving south at 10 m/s is a wind from the north. Ship heads north at 15 m/s.
        let deck = CarrierDeck.standard(heading: 0, speed: 15)
        #expect(near(deck.headwind(trueWind: SIMD3(-10, 0, 0)), 25))
    }

    @Test func crosswindPositiveWhenAirMovesToStarboard() {
        let deck = CarrierDeck.standard(heading: 0, speed: 0)
        #expect(near(deck.crosswind(trueWind: SIMD3(0, 10, 0)), 10))
        #expect(near(deck.headwind(trueWind: SIMD3(0, 10, 0)), 0))
    }

    @Test func deckPointIsAftOfRampOnHeading() {
        let deck = CarrierDeck.standard(position: .zero, heading: 0)
        let p = deck.deckPoint(aft: 100, lateral: 0)
        #expect(near(p.x, -100) && near(p.y, 0))
        let q = deck.deckPoint(aft: 0, lateral: 10)
        #expect(near(q.y, 10))
    }

    @Test func wiresAreSortedForwardToAft() {
        let deck = CarrierDeck(position: .zero, heading: 0, speed: 0, length: 230,
                               wires: [ArrestingWire(number: 1, aftDistance: 155),
                                       ArrestingWire(number: 3, aftDistance: 125)])
        #expect(deck.wires.map(\.number) == [3, 1])
    }
}

@Suite struct CatapultTests {
    let takeoff = 70.0

    @Test func requiredSettingGivesFlyingSpeedInCalmAir() {
        let g = CatapultLaunch.requiredSettingG(headwind: 0, takeoffAirspeed: takeoff)
        let shot = CatapultLaunch.fly(settingG: g, headwind: 0, takeoffAirspeed: takeoff)
        #expect(shot.outcome == .safe)
        #expect(near(shot.exitAirspeed, takeoff, 1e-6))
    }

    @Test func headwindLowersTheSettingNeeded() {
        let calm = CatapultLaunch.requiredSettingG(headwind: 0, takeoffAirspeed: takeoff)
        let windy = CatapultLaunch.requiredSettingG(headwind: 25, takeoffAirspeed: takeoff)
        #expect(windy < calm)
        #expect(near(windy, 45 * 45 / (2 * CatapultLaunch.gravity * CatapultLaunch.strokeLength), 1e-9))
    }

    @Test func underSetShotSinks() {
        let g = CatapultLaunch.requiredSettingG(headwind: 0, takeoffAirspeed: takeoff) * 0.8
        #expect(CatapultLaunch.fly(settingG: g, headwind: 0, takeoffAirspeed: takeoff).outcome == .insufficientEnergy)
    }

    @Test func overSetShotIsOverStress() {
        let shot = CatapultLaunch.fly(settingG: 5, headwind: 0, takeoffAirspeed: takeoff)
        #expect(shot.outcome == .overStress)
    }

    @Test func nonFiniteSettingIsTreatedAsNoEnergy() {
        #expect(CatapultLaunch.fly(settingG: .nan, headwind: 0, takeoffAirspeed: takeoff).outcome == .insufficientEnergy)
        #expect(CatapultLaunch.fly(settingG: .infinity, headwind: 0, takeoffAirspeed: takeoff).settingG == 0)
    }
}

@Suite struct ArrestedLandingTests {
    let deck = CarrierDeck.standard()

    private func approach(at x: Double, v: Double = 60, sink: Double = 2, gs: Double = 0.1, lu: Double = 0.2,
                          hookDown: Bool = true, waveOff: Bool = false) -> TrapApproach {
        TrapApproach(touchdownAft: x, groundSpeed: v, sinkRate: sink, glideslopeError: gs, lineupError: lu,
                     hookDown: hookDown, waveOff: waveOff)
    }

    @Test func idealTouchdownCatchesWireThree() {
        let r = ArrestedLanding.trap(approach(at: 118), deck: deck)
        #expect(r.outcome == .wire(3))
        // Stop = wire 3 at 125 m plus v^2 / (2a), with a = 3.5 g.
        let expected = 125 + 60 * 60 / (2 * 3.5 * CatapultLaunch.gravity)
        #expect(near(r.stopAft ?? -1, expected, 1e-6))
    }

    @Test func touchdownBeforeWireFourCatchesWireFour() {
        #expect(ArrestedLanding.trap(approach(at: 40), deck: deck).outcome == .wire(4))
    }

    @Test func touchdownPastLastWireBolters() {
        let r = ArrestedLanding.trap(approach(at: 160), deck: deck)
        #expect(r.outcome == .bolter(.missedWires))
        #expect(r.stopAft == nil)
    }

    @Test func hookUpBolters() {
        #expect(ArrestedLanding.trap(approach(at: 118, hookDown: false), deck: deck).outcome == .bolter(.hookUp))
    }

    @Test func waveOffWins() {
        #expect(ArrestedLanding.trap(approach(at: 118, waveOff: true), deck: deck).outcome == .waveOff)
    }

    @Test func tooFastOverruns() {
        #expect(ArrestedLanding.trap(approach(at: 118, v: 100), deck: deck).outcome == .overrun)
    }

    @Test func stopPastSternOverruns() {
        // Wire 1 at 155 m plus the stop distance at 90 m/s is past the 230 m stern.
        #expect(ArrestedLanding.trap(approach(at: 150, v: 90), deck: deck).outcome == .overrun)
    }

    @Test func nanTouchdownBoltersInsteadOfTrapping() {
        #expect(ArrestedLanding.trap(approach(at: .nan), deck: deck).outcome == .bolter(.missedWires))
    }
}

@Suite struct LSOGradingTests {
    private func grade(wire: Int, gs: Double = 0.1, lu: Double = 0.2, sink: Double = 2) -> LSOGrade {
        let a = TrapApproach(touchdownAft: 0, groundSpeed: 60, sinkRate: sink, glideslopeError: gs, lineupError: lu)
        return LSO.grade(a, TrapResult(outcome: .wire(wire), stopAft: 0, averageDecelerationG: 3.5))
    }

    @Test func tightIdealTrapIsOK() {
        #expect(grade(wire: 3) == .ok)
    }

    @Test func modestDeviationIsOKMinor() {
        #expect(grade(wire: 3, gs: 0.5, lu: 1.5, sink: 2) == .okMinor)
    }

    @Test func largeDeviationOnTargetWireIsFair() {
        #expect(grade(wire: 3, gs: 1.0, lu: 0.2, sink: 2) == .fair)
    }

    @Test func unsafeApproachIsUnsat() {
        #expect(grade(wire: 3, gs: 2.0) == .unsat)
        #expect(grade(wire: 3, sink: 7) == .unsat)
    }

    @Test func aftMostWireIsNoGrade() {
        #expect(grade(wire: 1) == .noGrade)
    }

    @Test func bolterAndWaveOffAreGraded() {
        let a = TrapApproach(touchdownAft: 0, groundSpeed: 60, sinkRate: 2, glideslopeError: 0, lineupError: 0)
        #expect(LSO.grade(a, TrapResult(outcome: .bolter(.hookUp), stopAft: nil, averageDecelerationG: 0)) == .bolter)
        #expect(LSO.grade(a, TrapResult(outcome: .waveOff, stopAft: nil, averageDecelerationG: 0)) == .waveOff)
    }
}

@Suite struct CarrierQualificationTests {
    private let deck = CarrierDeck.standard()

    /// Run one trap through the model and record it, using a touchdown that gives the wanted wire.
    private func run(_ q: inout CarrierQualification, wire: Int, gs: Double = 0.1, lu: Double = 0.2, sink: Double = 2) {
        let x: Double
        switch wire {
        case 4: x = 100
        case 3: x = 118
        case 2: x = 130
        default: x = 150
        }
        let a = TrapApproach(touchdownAft: x, groundSpeed: 60, sinkRate: sink, glideslopeError: gs, lineupError: lu)
        q.record(a, result: ArrestedLanding.trap(a, deck: deck))
    }

    @Test func threePassesWithNoUnsatQualifies() {
        var q = CarrierQualification()
        run(&q, wire: 3)                 // OK
        run(&q, wire: 3, gs: 1.0)        // Fair
        run(&q, wire: 2)                 // Fair
        run(&q, wire: 1)                 // No Grade
        #expect(q.isFinished)
        #expect(q.qualified)
        #expect(q.score == 5 + 3 + 3 + 1)
    }

    @Test func anyUnsatFailsEvenWithThreePasses() {
        var q = CarrierQualification()
        run(&q, wire: 3)
        run(&q, wire: 3, gs: 1.0)
        run(&q, wire: 2)
        run(&q, wire: 3, sink: 7)        // Unsat
        #expect(q.isFinished)
        #expect(!q.qualified)
    }

    @Test func boltersAreAttemptsNotGradedTraps() {
        var q = CarrierQualification()
        run(&q, wire: 3, gs: 0.1)
        run(&q, wire: 3, gs: 0.1)
        // A bolter from an unlowered hook: an attempt, not a graded trap.
        let bolter = TrapApproach(touchdownAft: 118, groundSpeed: 60, sinkRate: 2, glideslopeError: 0, lineupError: 0, hookDown: false)
        q.record(bolter, result: ArrestedLanding.trap(bolter, deck: deck))
        #expect(q.attempts.count == 3)
        #expect(q.gradedAttempts.count == 2)
        #expect(!q.isFinished)
    }

    @Test func runEndsAfterEightAttemptsWithoutQualifying() {
        var q = CarrierQualification()
        let bolter = TrapApproach(touchdownAft: 118, groundSpeed: 60, sinkRate: 2, glideslopeError: 0, lineupError: 0, hookDown: false)
        for _ in 0..<10 { q.record(bolter, result: ArrestedLanding.trap(bolter, deck: deck)) }
        #expect(q.attempts.count == CarrierQualification.maxAttempts)
        #expect(q.isFinished)
        #expect(!q.qualified)
    }

    @Test func recordingAfterFinishIsIgnored() {
        var q = CarrierQualification()
        for _ in 0..<4 { run(&q, wire: 3) }
        run(&q, wire: 3, sink: 7)
        #expect(q.attempts.count == 4)
    }
}
