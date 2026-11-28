// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFTutorial

private func snap(ias: Double = 0, gs: Double = 0, agl: Double = 0, vs: Double = 0, pitch: Double = 0,
                  roll: Double = 0, heading: Double = 270, runway: Double = 270, onGround: Bool = true,
                  throttle: Double = 0, flaps: Double = 0) -> TutorialSnapshot {
    TutorialSnapshot(indicatedAirspeedKt: ias, groundSpeedKt: gs, altitudeAGLFt: agl, verticalSpeedFpm: vs,
                     pitchDeg: pitch, rollDeg: roll, headingDeg: heading, runwayHeadingDeg: runway,
                     onGround: onGround, throttle: throttle, flapsFraction: flaps)
}

@Suite struct TutorialRouteTests {
    @Test func lessonsRunInTheIntendedOrder() {
        #expect(TutorialLesson.allCases.first == .controls)
        #expect(TutorialLesson.allCases.last == .landing)
        #expect(TutorialLesson.allCases.count == 11)
        #expect(TutorialEngine().lessons == TutorialLesson.allCases)
    }

    @Test func scriptedFlightCompletesEveryLessonAndHandsOff() {
        var e = TutorialEngine()
        func run(_ frames: [TutorialSnapshot], dt: Double = 1) {
            for f in frames { e.update(f, dt: dt) }
        }
        e.confirm()                                                      // controls
        e.confirm()                                                      // instruments
        run([snap(ias: 5, gs: 12, onGround: true, throttle: 0.5)], dt: 0.1)  // throttle
        run([snap(gs: 10, heading: 0, onGround: true, throttle: 0.4),
             snap(gs: 10, heading: 10, onGround: true, throttle: 0.4),
             snap(gs: 10, heading: 20, onGround: true, throttle: 0.4),
             snap(gs: 10, heading: 30, onGround: true, throttle: 0.4)])  // taxi
        run([snap(ias: 60, agl: 30, onGround: false, throttle: 1)])     // takeoff
        run([snap(ias: 80, agl: 400, vs: 500, pitch: 8, onGround: false, throttle: 1)], dt: 1)
        #expect(e.current == .climb)
        run(Array(repeating: snap(ias: 80, agl: 400, vs: 500, pitch: 8, onGround: false, throttle: 1), count: 4), dt: 1) // 5 s hold
        #expect(e.current == .turn)
        run([snap(ias: 85, agl: 500, heading: 0, onGround: false), snap(ias: 85, agl: 500, heading: 15, onGround: false),
             snap(ias: 85, agl: 500, heading: 30, onGround: false), snap(ias: 85, agl: 500, heading: 45, onGround: false)])
        run([snap(ias: 85, agl: 500, roll: 0, heading: 45, onGround: false)], dt: 2)
        #expect(e.current == .trim)
        run([snap(ias: 90, agl: 500, vs: 0, heading: 45, onGround: false)])
        #expect(e.current == .trim, "trim should not complete on the first frame")
        run([snap(ias: 90, agl: 500, vs: 0, heading: 45, onGround: false)], dt: 4)
        #expect(e.current == .pattern)
        run([snap(ias: 90, agl: 1000, heading: 90, runway: 270, onGround: false)], dt: 4)
        #expect(e.current == .approach)
        run([snap(ias: 75, agl: 600, vs: -500, onGround: false, flaps: 0.5)], dt: 3)
        #expect(e.current == .landing)
        run([snap(ias: 70, agl: 40, vs: -200, onGround: false, flaps: 0.5)])
        run([snap(ias: 20, gs: 20, onGround: true, flaps: 0.5)])
        #expect(e.isFinished)
        #expect(e.handoff == .flightSchool)
        #expect(e.fraction == 1)
        #expect(e.completed == TutorialLesson.allCases)
    }

    @Test func confirmOnlyLessonsIgnoreFlying() {
        var e = TutorialEngine()
        e.update(snap(ias: 80, agl: 400, onGround: false), dt: 10)
        #expect(e.current == .controls)
        e.confirm()
        #expect(e.current == .instruments)
        e.update(snap(ias: 80, agl: 400, onGround: false), dt: 10)
        #expect(e.current == .instruments)
    }

    @Test func customRouteCanBeShorter() {
        var e = TutorialEngine(lessons: [.controls, .throttle])
        e.confirm()
        e.update(snap(gs: 12, onGround: true, throttle: 0.5), dt: 0.1)
        #expect(e.isFinished)
        #expect(e.handoff == .flightSchool)
    }
}

@Suite struct TutorialCheckTests {
    @Test func climbNeedsHoldTimeAndDrainsSlowly() {
        var e = TutorialEngine(lessons: [.climb])
        let climbing = snap(ias: 80, agl: 400, vs: 500, pitch: 8, onGround: false)
        e.update(climbing, dt: 4)
        #expect(!e.isFinished, "4 s of climb is not enough")
        e.update(snap(ias: 80, agl: 400, vs: 0, pitch: 8, onGround: false), dt: 0.5)  // brief wobble
        #expect(e.holdTime > 2, "a brief wobble should not throw away the hold")
        e.update(climbing, dt: 2)
        #expect(e.isFinished)
    }

    @Test func pitchOutsideRangeDoesNotCount() {
        var e = TutorialEngine(lessons: [.climb])
        e.update(snap(ias: 80, agl: 400, vs: 500, pitch: 30, onGround: false), dt: 10)
        #expect(!e.isFinished)
    }

    @Test func taxiNeedsRealTurning() {
        var e = TutorialEngine(lessons: [.taxi])
        e.update(snap(gs: 10, heading: 100, onGround: true), dt: 0.1)
        e.update(snap(gs: 10, heading: 105, onGround: true), dt: 0.1)
        #expect(!e.isFinished, "5 degrees of nose swing is not a turn")
        e.update(snap(gs: 10, heading: 120, onGround: true), dt: 0.1)
        #expect(e.isFinished)
    }

    @Test func headingDeltaWrapsAroundNorth() {
        #expect(TutorialLesson.headingDelta(from: 350, to: 10) == 20)
        #expect(TutorialLesson.headingDelta(from: 10, to: 350) == -20)
        #expect(TutorialLesson.angularDistance(350, 10) == 20)
    }

    @Test func patternAcceptsEitherSideOfReciprocal() {
        // Runway 270, so the downwind heading is 90.
        #expect(TutorialLesson.pattern.isMet(snap(agl: 1000, heading: 95, runway: 270, onGround: false), TutorialProgress()))
        #expect(!TutorialLesson.pattern.isMet(snap(agl: 1000, heading: 200, runway: 270, onGround: false), TutorialProgress()))
        #expect(!TutorialLesson.pattern.isMet(snap(agl: 300, heading: 90, runway: 270, onGround: false), TutorialProgress()))
    }

    @Test func landingOnlyCountsAfterLeavingTheGround() {
        var e = TutorialEngine(lessons: [.landing])
        e.update(snap(gs: 20, onGround: true), dt: 0.1)
        #expect(!e.isFinished, "sitting on the ground at the start is not a landing")
        e.update(snap(agl: 50, vs: -200, onGround: false), dt: 0.1)
        e.update(snap(gs: 20, onGround: true), dt: 0.1)
        #expect(e.isFinished)
    }

    @Test func sinkingTooFastSendsPlayerBackToApproach() {
        var e = TutorialEngine(lessons: [.approach, .landing])
        e.update(snap(ias: 75, agl: 600, vs: -500, onGround: false, flaps: 0.5), dt: 3)
        #expect(e.current == .landing)
        e.update(snap(agl: 100, vs: -1200, onGround: false), dt: 0.1)
        #expect(e.current == .approach)
        #expect(e.recovery?.text.contains("Go around") == true, "the go-around message stays on screen")
        #expect(e.completed == [.approach], "progress already made is kept")
    }

    @Test func recoveryTextAppearsForClimbingTooSlowly() {
        let r = TutorialLesson.climb.recovery(snap(ias: 50, agl: 300, vs: 400, onGround: false))
        #expect(r?.text.contains("Lower the nose") == true)
        #expect(TutorialLesson.climb.recovery(snap(ias: 80, agl: 300, vs: 400, onGround: false)) == nil)
    }
}

@Suite struct TutorialHintTests {
    @Test func hintsEscalateWithTime() {
        var e = TutorialEngine(lessons: [.trim])
        let flying = snap(ias: 60, agl: 500, onGround: false)  // never meets trim
        e.update(flying, dt: 10)
        #expect(e.currentHint == nil)
        e.update(flying, dt: 6)  // 16 s
        #expect(e.currentHint == TutorialLesson.trim.hints[0])
        e.update(flying, dt: 15)  // 31 s
        #expect(e.currentHint == TutorialLesson.trim.hints[1])
        #expect(!e.canSkip)
        e.update(flying, dt: 30)  // 61 s
        #expect(e.canSkip)
        e.skip()
        #expect(e.isFinished)
        #expect(e.completed == [.trim])
    }

    @Test func skipIsRefusedBeforeTheDelay() {
        var e = TutorialEngine(lessons: [.trim])
        e.update(snap(ias: 60, agl: 500, onGround: false), dt: 5)
        e.skip()
        #expect(e.current == .trim)
        #expect(e.completed.isEmpty)
    }

    @Test func badFramesAreIgnored() {
        var e = TutorialEngine(lessons: [.throttle])
        e.update(snap(gs: .nan, onGround: true, throttle: 1), dt: 0.1)
        e.update(snap(gs: 12, onGround: true, throttle: 1), dt: .infinity)
        e.update(snap(gs: 12, onGround: true, throttle: 1), dt: 0)
        #expect(!e.isFinished)
        #expect(e.timeInLesson == 0)
    }
}
