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
            let line = String(format: "TRACE %@ crashed=%d reason=%@ maxH=%.2f maxV=%.1f rot=%.1f z=%.2f", a.name, s.crashed ? 1 : 0, s.crashReason ?? "-", maxH, maxV, a.rotateSpeed, s.state.positionNED.z)
            Issue.record(line)
        }
    }
}
