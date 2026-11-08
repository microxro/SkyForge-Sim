// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight

@Suite struct CockpitTests {
    @Test func eyeIsInsideTheCabinAndThePFDIsInReach() {
        let e = Cockpit.eye
        #expect(e.z < -0.6 && e.z > -1.0 && abs(e.y) < 0.5 && e.x > -0.5 && e.x < 1.0)
        let c = Cockpit.pfdCorners
        #expect(c.count == 4)
        let centre = c.reduce(SIMD3<Double>.zero, +) / 4
        let d = centre - e
        let dist = (d * d).sum().squareRoot()
        #expect(dist > 0.6 && dist < 1.1, "PFD at \(dist) m")
        #expect(d.z > 0, "PFD is below eye level")
        // Corner order: top-left, top-right, bottom-right, bottom-left as the pilot sees them.
        #expect(c[0].y < c[1].y && c[3].y < c[2].y && c[0].z < c[3].z && c[1].z < c[2].z)
    }

    @Test func interiorMeshIsSane() {
        let m = Cockpit.mesh()
        #expect(m.triangleCount > 100)
        for p in m.positions { #expect(p.x.isFinite && abs(p.x) < 2 && abs(p.y) < 0.7 && p.z > -1.1 && p.z < 0.3) }
    }

    @Test func cockpitCameraLooksDownTheRunway() {
        let s = QuickFlightSession(start: .runway)
        let cam = s.cockpitCamera()
        let f = cam.target - cam.position
        let hdg = atan2(f.x, f.y), rwy = s.world.runwayHeading
        #expect(abs(remainder(hdg - rwy, 2 * .pi)) < 0.03)
        #expect(cam.up.z > 0.95, "level on the ground: up \(cam.up)")
        #expect(cam.position.z > s.positionENU.z + 0.5)
    }
}
