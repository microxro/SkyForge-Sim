import Testing
import Foundation
@testable import SFCareer

@Suite struct TouchdownTests {
    func sample(_ t: Double, _ h: Double, _ sink: Double) -> TouchdownSample {
        TouchdownSample(time: t, heightAGLM: h, sinkMPS: sink, offsetM: 0.4, distancePastThresholdM: 300)
    }
    @Test func detectsContactOnce() {
        var d = TouchdownDetector()
        var events: [TouchdownEvent] = []
        for (i, h) in [20.0, 5, 1, 0.3, 0.2].enumerated() {
            if let e = d.feed(sample(Double(i), h, 1.0)) { events.append(e) }
        }
        #expect(events.count == 1)
        #expect(d.feed(sample(9, 0, 1)) == nil)
    }
    @Test func reportsPeakSinkBeforeContact() {
        var d = TouchdownDetector()
        _ = d.feed(sample(0, 10, 2.0))      // 2 m/s = 394 fpm
        _ = d.feed(sample(0.5, 2, 3.0))     // peak 3 m/s = 591 fpm
        let e = d.feed(sample(1, 0.2, 1.0))
        #expect(e != nil)
        #expect(abs((e?.sinkFPM ?? 0) - 3.0 * 196.850394) < 0.01)
    }
    @Test func startingOnGroundIsNotALanding() {
        var d = TouchdownDetector()
        #expect(d.feed(sample(0, 0, 0)) == nil)
        #expect(d.feed(sample(1, 0.1, 0)) == nil)
    }
    @Test func nonFiniteSamplesAreIgnored() {
        var d = TouchdownDetector()
        _ = d.feed(sample(0, 5, 1))
        #expect(d.feed(TouchdownSample(time: 1, heightAGLM: .nan, sinkMPS: 1, offsetM: 0, distancePastThresholdM: 0)) == nil)
        #expect(d.event == nil)
    }
    @Test func appliesToReport() {
        var r = FlightReport(aircraftID: "org.skyforge.sf1", landed: false)
        r.applyTouchdown(TouchdownEvent(time: 1, sinkFPM: 100, offsetM: 0.4, distancePastThresholdM: 300))
        #expect(r.landed && r.touchdownSinkFPM == 100)
        var c = CareerState()
        CareerEngine.apply(r, to: &c)
        #expect(c.stats.smoothLandings == 1)
    }
}
