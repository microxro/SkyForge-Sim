// SKYFORGE — Apache-2.0
import Testing
@testable import SFQuickFlight
import SFWorldGen

@Suite struct AircraftMeshNormalsTests {
    /// The cockpit view discards back faces by normal, so cabin normals must point out of the fuselage.
    @Test func hingeSeamsAreLightOnTheRenderedAircraft() {
        let m = QuickFlightWorld.aircraftMesh()
        let dark = SFWorldGen.srgb(70, 72, 76), light = SFWorldGen.srgb(150, 152, 152)
        #expect(!m.albedo.contains(dark), "dark sub-pixel seams alias into dashes at chase distance")
        #expect(m.albedo.contains(light))
    }

    @Test func cabinNormalsPointOutward() {
        let m = QuickFlightWorld.aircraftMesh()
        var out = 0, inward = 0
        for t in 0..<m.triangleCount {
            let c = (m.positions[3 * t] + m.positions[3 * t + 1] + m.positions[3 * t + 2]) / 3
            guard c.x > -0.2 && c.x < 1.9 && abs(c.y) > 0.3 && c.z > -1.0 && c.z < 0.1 else { continue }   // cabin sides
            let n = m.normals[3 * t]
            let radial = SIMD3<Float>(0, c.y, c.z + 0.35)
            if (n * radial).sum() > 0 { out += 1 } else { inward += 1 }
        }
        #expect(out > 10 && inward * 10 < out, "outward \(out) inward \(inward)")
    }

    @Test func wingNormalsPointAwayFromTheWingCore() {
        let m = QuickFlightWorld.aircraftMesh()
        var out = 0, inward = 0
        for t in 0..<m.triangleCount {
            let c = (m.positions[3 * t] + m.positions[3 * t + 1] + m.positions[3 * t + 2]) / 3
            guard abs(c.y) > 1.5 && abs(c.y) < 5 && c.z < -0.9 && c.z > -1.3 else { continue }   // wing panels
            let n = m.normals[3 * t]
            guard abs(n.z) > 0.7 else { continue }
            // Wing mean surface z ≈ −1.05 − |y|·tan(dihedral); upper skin above it has normals up (−z).
            let mid: Float = -1.05 - abs(c.y) * 0.028
            if (c.z < mid) == (n.z < 0) { out += 1 } else { inward += 1 }
        }
        #expect(out > 20 && inward * 10 < out, "outward \(out) inward \(inward)")
    }
}
