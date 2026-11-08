// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Testing
import Foundation
import Metal
import simd
@testable import SFRender
import SFQuickFlight
import SFPreview

/// HDR scene buffer + energy-conserving bloom: looking into a low sun, bloom spreads glare around the
/// disc (brighter ring) while the frame's mean brightness changes only a little.
@Suite struct BloomRenderTests {
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func bloomSpreadsSunGlareWithoutChangingTheFrameMuch() throws {
        let world = QuickFlightWorld()
        var d = QuickFlightDetail.phone
        d.objectRadius = 400; d.nearHalfExtent = 800; d.midHalfExtent = 2_000; d.farHalfExtent = 5_000
        let lighting = LightingSetup.physicalPreset(.goldenHour, azimuthDegrees: 255, cameraHeightMetres: 300)
        let r = try WorldRenderer(lighting: lighting)
        try r.setEnvironment(world.buildEnvironment(detail: d))
        // Look straight at the sun.
        let toSun = simd_normalize(SIMD3<Double>(Double(lighting.toSun.x), Double(lighting.toSun.y), Double(lighting.toSun.z)))
        let eye = SIMD3<Double>(world.runwayCentre.x, world.runwayCentre.y, world.runwayElevation + 300)
        let cam = WorldCamera(position: eye, target: eye + toSun * 1_000)
        let w = 320, h = 180
        r.bloomIntensity = 0
        let off = try r.render(width: w, height: h, camera: cam)
        r.bloomIntensity = 0.05
        let on = try r.render(width: w, height: h, camera: cam)
        _ = VisualRegression.check(name: "metal_bloom_sun_320x180", rgb: on, width: w, height: h, goldenDir: goldenDir)
        func lum(_ img: [UInt8], _ x: Int, _ y: Int) -> Double { let i = 3 * (y * w + x); return Double(img[i]) + Double(img[i + 1]) + Double(img[i + 2]) }
        // Ring 12–30 px from the centre (the sun is at the image centre).
        var ringOn = 0.0, ringOff = 0.0, meanOn = 0.0, meanOff = 0.0, n = 0.0
        for y in 0..<h { for x in 0..<w {
            meanOn += lum(on, x, y); meanOff += lum(off, x, y)
            let dx = Double(x - w / 2), dy = Double(y - h / 2), rr = (dx * dx + dy * dy).squareRoot()
            if rr > 12 && rr < 30 { ringOn += lum(on, x, y); ringOff += lum(off, x, y); n += 1 }
        } }
        meanOn /= Double(w * h); meanOff /= Double(w * h)
        print("bloom: ring \(ringOff / n) → \(ringOn / n), mean \(meanOff) → \(meanOn)")
        #expect(ringOn > ringOff * 1.03, "glare brightens the ring around the sun")
        #expect(abs(meanOn - meanOff) / meanOff < 0.12, "energy-conserving: mean changes < 12 %")
    }
}
#endif
