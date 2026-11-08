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
    func gpuFieldCoverageMatchesCPU() throws {
        let r = try WorldRenderer(lighting: .preset(.midday))
        let pattern = FieldPattern(seed: 4_242, autumn: false)
        var pts = [SIMD3<Float>]()
        for i in 0..<4_096 {
            let x: Float = Float(i % 64) * 61 - 1_900
            let y: Float = Float(i / 64) * 67 - 2_100
            let w: Float = Float(i % 97) / 96
            pts.append(SIMD3(x, y, w))
        }
        let gpu = try r.fieldCoverage(points: pts, pattern: pattern)
        var bad = 0
        for (i, p) in pts.enumerated() where abs(gpu[i] - pattern.coverage(p.x, p.y, weight: p.z)) > 0.01 { bad += 1 }
        print("field coverage GPU vs CPU: \(bad)/\(pts.count) differ")
        #expect(bad <= pts.count / 200)
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func gpuTownImpostorMatchesCPU() throws {
        let r = try WorldRenderer(lighting: .preset(.midday))
        let pattern = FieldPattern(seed: 0x00AB_CDEF, autumn: false)
        let footprints: [Float] = [0.2, 1, 6, 20]
        var pts = [SIMD3<Float>]()
        for i in 0..<4_096 {
            let x: Float = Float(i % 64) * 3.7 - 120
            let y: Float = Float(i / 64) * 4.3 - 140
            pts.append(SIMD3(x, y, footprints[i % 4]))
        }
        let gpu = try r.fieldFactors(points: pts, pattern: pattern, town: true)
        let lawn = SIMD3<Float>(0.10, 0.12, 0.06)
        var bad = 0
        for (i, p) in pts.enumerated() where simd_length(gpu[i] - pattern.town(p.x, p.y, footprint: p.z, lawn: lawn)) > 0.005 { bad += 1 }
        print("town impostor GPU vs CPU: \(bad)/\(pts.count) differ")
        #expect(bad <= pts.count / 200)
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
