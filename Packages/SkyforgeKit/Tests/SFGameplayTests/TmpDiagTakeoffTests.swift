// TEMPORARY diagnostic for the narrowbody takeoff; removed before merge.
import Testing
import Foundation
import SFMath
import SFFlightModel
@testable import SFGameplay

@Suite struct TmpDiagTakeoffTests {
    @Test func narrowbodyTakeoffTrace() {
        let a = AircraftCatalog.sfNarrowbody
        var s = GameplaySession(world: FlatWorld(), aircraft: a)
        var lines: [String] = []
        for step in 0..<(120 * 25) where !s.crashed {
            var c = PilotControls()
            c.flight.throttle = 1
            c.flight.elevator = s.trueAirspeed >= a.rotateSpeed ? 0.15 : 0
            s.step(c)
            if step % 120 == 0 {
                lines.append(String(format: "t=%.0f v=%.1f h=%.2f g=%d z=%.2f vx=%.1f vz=%.2f", s.time, s.trueAirspeed, s.heightAGL, s.onGround ? 1 : 0, s.state.positionNED.z, s.state.velocityBody.x, s.state.velocityBody.z))
            }
        }
        let body = lines.joined(separator: " | ")
        Issue.record("TRACE crashed=\(s.crashed) reason=\(s.crashReason ?? "-") :: \(body)")
    }
}
