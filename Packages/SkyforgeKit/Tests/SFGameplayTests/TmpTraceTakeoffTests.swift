// TEMPORARY diagnostic: records one issue per aircraft with its takeoff result. Remove before merge.
import Testing
import Foundation
import SFMath
import SFFlightModel
@testable import SFGameplay

@Suite struct TmpTraceTakeoffTests {
    @Test func traceEveryAircraftTakeoff() {
        for a in AircraftCatalog.all {
            var s = GameplaySession(world: FlatWorld(), aircraft: a)
            var maxH = 0.0
            var maxV = 0.0
            for _ in 0..<(120 * 25) where !s.crashed {
                var c = PilotControls()
                c.flight.throttle = 1
                c.flight.elevator = s.trueAirspeed >= a.rotateSpeed ? 0.15 : 0
                s.step(c)
                maxH = max(maxH, s.heightAGL)
                maxV = max(maxV, s.trueAirspeed)
            }
            let line = "TRACE \(a.name) crashed=\(s.crashed) reason=\(s.crashReason ?? "-") maxH=\(String(format: "%.2f", maxH)) maxV=\(String(format: "%.1f", maxV)) rot=\(a.rotateSpeed) z=\(String(format: "%.2f", s.state.positionNED.z))"
            Issue.record("\(line)")
        }
    }
}
