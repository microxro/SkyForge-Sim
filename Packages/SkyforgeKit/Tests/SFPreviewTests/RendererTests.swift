import Testing
import Foundation
import SFMath
@testable import SFPreview

@Suite struct RendererTests {
    @Test func groundQuadAndSkyRender() {
        var soup = TriangleSoup(origin: .zero)
        let c = SIMD3<Float>(0.3, 0.4, 0.2)
        soup.addQuad(SIMD3(-500, -500, 0), SIMD3(500, -500, 0), SIMD3(500, 500, 0), SIMD3(-500, 500, 0), colour: c)
        // A box that must cast a shadow onto the ground.
        soup.addQuad(SIMD3(-5, -5, 0), SIMD3(5, -5, 0), SIMD3(5, -5, 20), SIMD3(-5, -5, 20), colour: c)
        let cam = PreviewCamera(position: SIMD3(0, -120, 40), lookAt: SIMD3(0, 0, 0))
        var stats = RenderStats()
        let img = PreviewRenderer.render(soup: soup, camera: cam, lighting: .preset(.midday), width: 64, height: 36,
                                         supersample: 1, shadowCentre: .zero, shadowHalfExtent: 300, stats: &stats)
        #expect(img.rgb.count == 64 * 36 * 3)
        // Top row is sky (bluish), bottom row is ground (not black, not sky-blue).
        let top = (0..<64).map { Int(img.rgb[$0 * 3 + 2]) }.reduce(0, +) / 64
        let bottom = (0..<64).map { Int(img.rgb[(35 * 64 + $0) * 3 + 1]) }.reduce(0, +) / 64
        #expect(top > 100)
        #expect(bottom > 20)
        #expect(stats.triangles == 4)
    }

    @Test func nearPlaneClippingKeepsVisiblePart() {
        var soup = TriangleSoup(origin: .zero)
        // Triangle straddling the camera plane.
        soup.addFlat(SIMD3(-10, -5, -1), SIMD3(10, -5, -1), SIMD3(0, 50, -1), colour: SIMD3(1, 1, 1))
        let tris = Raster.project(soup, cameraOffset: .zero, right: SIMD3(1, 0, 0), up: SIMD3(0, 0, 1), forward: SIMD3(0, 1, 0),
                                  focal: 50, width: 100, height: 100)
        #expect(!tris.isEmpty)
        for t in tris { #expect(t.p0.z > 0 && t.p1.z > 0 && t.p2.z > 0) }
    }
}
