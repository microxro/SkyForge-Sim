// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Testing
import Foundation
import Metal
import simd
@testable import SFRender
import SFPreview
import SFQuickFlight

@Suite struct FieldPatternRenderTests {
    /// The world shader's field parcels mirror SFPreview.FieldPattern (same parcels, hedges and crops).
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func gpuFieldFactorsMatchCPU() throws {
        let r = try WorldRenderer(lighting: .preset(.midday))
        for pattern in [FieldPattern(seed: 0x00AB_CDEF, autumn: false), FieldPattern(seed: 77, autumn: true)] {
            var pts = [SIMD3<Float>]()
            for i in 0..<4_096 {
                let x = Float(i % 64) * 37.3 - 1_200 + Float(i / 64) * 0.71
                let y = Float(i / 64) * 41.9 - 1_300
                pts.append(SIMD3(x, y, [0.1, 0.6, 2.5, 9][i % 4]))
            }
            let gpu = try r.fieldFactors(points: pts, pattern: pattern)
            var bad = 0
            for (i, p) in pts.enumerated() {
                let c = pattern.factor(p.x, p.y, footprint: p.z)
                if simd_length(gpu[i] - c) > 0.01 { bad += 1 }
            }
            // A handful of points sit exactly on a parcel or hedge edge, where float rounding may differ.
            print("field factors GPU vs CPU: \(bad)/\(pts.count) differ (seed \(pattern.seed))")
            #expect(bad <= pts.count / 200)
        }
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func skyWorldEnvironmentCarriesFields() throws {
        var dt = QuickFlightDetail.phone
        dt.objectRadius = 400; dt.nearHalfExtent = 800; dt.midHalfExtent = 2_000; dt.farHalfExtent = 4_000
        let soup = QuickFlightWorld().buildEnvironment(detail: dt)
        let r = try WorldRenderer(lighting: .preset(.midday))
        try r.setEnvironment(soup)
        #expect(r.fieldPattern != nil)
        #expect(soup.vertexField.contains { $0 > 0.5 })
    }
}
#endif
