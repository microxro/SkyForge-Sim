// SKYFORGE — Apache-2.0
import Testing
@testable import SFQuickFlight
import SFWorldGen

@Suite struct AircraftVariantSoupTests {
    /// Every fleet id builds a renderable soup with unit normals and paint, canopy glass, metal and tyres.
    @Test(arguments: AircraftVariants.ids)
    func variantSoupIsRenderable(id: String) {
        let m = QuickFlightWorld.aircraftMesh(for: id)
        #expect(m.triangleCount > 600, "\(id): \(m.triangleCount) triangles")
        for n in m.normals { #expect(abs((n * n).sum().squareRoot() - 1) < 1e-3) }
        for p in m.positions { #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite) }
        #expect(m.material.contains(.paint) && m.material.contains(.glass) && m.material.contains(.metal) && m.material.contains(.opaque))
        // The SF-1's per-pixel airframe materials are not used by the other types.
        #expect(!m.material.contains(.airframe) && !m.material.contains(.airSurface))
    }

    /// The SF-1 id and unknown ids give the existing SF-1 mesh unchanged.
    @Test func sf1AndUnknownIdsUseTheSF1Mesh() {
        let base = QuickFlightWorld.aircraftMesh()
        #expect(QuickFlightWorld.aircraftMesh(for: "org.skyforge.sf1").triangleCount == base.triangleCount)
        #expect(QuickFlightWorld.aircraftMesh(for: "unknown").triangleCount == base.triangleCount)
    }
}
