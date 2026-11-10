// SKYFORGE — Apache-2.0
import Testing
@testable import SFQuickFlight
import SFWorldGen

@Suite struct AircraftMeshNormalsTests {
    /// Skin triangles carry unit smooth normals and the airframe materials the shader paints per pixel.
    @Test func skinHasUnitNormalsAndAirframeMaterials() {
        let m = QuickFlightWorld.aircraftMesh()
        #expect(m.triangleCount > 8_000, "\(m.triangleCount) triangles")
        for n in m.normals { #expect(abs((n * n).sum().squareRoot() - 1) < 1e-3) }
        #expect(m.material.contains(.airframe) && m.material.contains(.airSurface) && m.material.contains(.metal) && m.material.contains(.prop))
    }

    /// Glazing, stripe and anti-glare zones sit where the shader draws them.
    @Test func liveryZones() {
        #expect(AircraftLivery.fuselage(SIMD3(0.9, 0.0, -0.80)) == .glass)        // windscreen
        #expect(AircraftLivery.fuselage(SIMD3(0.0, 0.55, -0.70)) == .glass)       // door window
        #expect(AircraftLivery.fuselage(SIMD3(-0.9, -0.54, -0.70)) == .glass)     // rear side window
        #expect(AircraftLivery.fuselage(SIMD3(0.0, 0.55, 0.20)) == .white)        // lower door skin
        #expect(AircraftLivery.fuselage(SIMD3(1.9, 0.0, -0.50)) == .black)        // anti-glare panel
        #expect(AircraftLivery.fuselage(SIMD3(0.0, 0.56, AircraftLivery.stripeZ(0.0))) == .navy)
        #expect(AircraftLivery.surface(SIMD3(0.0, 5.4, -1.2)) == .navy)           // wing tip
        #expect(AircraftLivery.surface(SIMD3(0.0, 2.0, -1.1)) == .white)
    }

    /// The cockpit view discards back faces by normal, so cabin normals must point out of the fuselage.
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
            // Chord plane: z ≈ −1.05 − |y|·tan(dihedral) at the leading edge (x = 0.25), dropping aft with the
            // incidence (about 1°); the upper skin above it has normals up (−z). The last tenth of the chord,
            // where both skins meet within a centimetre, is left out.
            guard c.x > -1.1 else { continue }
            let mid: Float = -1.05 - abs(c.y) * 0.028 + max(0, 0.25 - c.x) * 0.012
            if (c.z < mid) == (n.z < 0) { out += 1 } else { inward += 1 }
        }
        #expect(out > 20 && inward * 10 < out, "outward \(out) inward \(inward)")
    }
}
