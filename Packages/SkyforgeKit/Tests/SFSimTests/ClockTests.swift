import Testing
@testable import SFSim

@Suite struct ClockTests {
    @Test func stepsAccumulate() {
        var c = FixedStepClock()
        var steps = 0
        for _ in 0..<60 { steps += c.advance(frameTime: 1.0 / 60.0) }
        #expect(steps == 120 || steps == 119)
        #expect(c.alpha >= 0 && c.alpha < 1)
    }

    @Test func spiralGuard() {
        var c = FixedStepClock()
        #expect(c.advance(frameTime: 0.2) == 8)
        #expect(c.accumulator < c.dt)
    }

    @Test func tripleBufferLatest() {
        let b = TripleBuffer(initial: 0)
        for i in 1...10 { b.publish(i) }
        let r = b.read()
        #expect(r.value == 10 && r.sequence == 10)
    }
}
