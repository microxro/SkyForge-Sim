// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Testing
import Foundation
import simd
@testable import SFRender
import SFPreview
import SFQuickFlight
import SFInstruments

@Suite struct CockpitRenderTests {
    static func renderer(world: QuickFlightWorld, cameraHeight: Double) throws -> WorldRenderer {
        var d = QuickFlightDetail.phone
        d.objectRadius = 500; d.nearHalfExtent = 900; d.midHalfExtent = 2_500; d.farHalfExtent = 6_000
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cameraHeight))
        try r.setEnvironment(world.buildEnvironment(detail: d))
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        return r
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func cockpitFrameShowsPanelPFDAndOutsideWorld() throws {
        let world = QuickFlightWorld()
        let s = QuickFlightSession(world: world, start: .runway)
        let r = try Self.renderer(world: world, cameraHeight: s.positionENU.z)
        try r.setCockpit(Cockpit.mesh(), screen: Cockpit.pfdCorners.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) })
        let pw = 512, ph = 320
        r.updateCockpitScreen(rgb: Raster2D.render(PFD.draw(s.data, width: Double(pw), height: Double(ph)), width: pw, height: ph).bytes(),
                              width: pw, height: ph)
        r.cockpitView = true
        let ck = s.cockpitCamera()
        let w = 320, h = 180
        let c = s.bodyToENUColumns
        let img = try r.render(width: w, height: h,
                               camera: WorldCamera(position: ck.position, target: ck.target, verticalFOVDeg: 62, up: ck.up, near: 0.05),
                               aircraftPosition: s.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        _ = VisualRegression.check(name: "metal_cockpit_320x180", rgb: img, width: w, height: h, goldenDir: goldenDir)
        func px(_ x: Int, _ y: Int) -> SIMD3<Int> { let i = 3 * (y * w + x); return SIMD3(Int(img[i]), Int(img[i + 1]), Int(img[i + 2])) }
        var skyTop = 0, darkBottom = 0, pfdBlue = 0
        for x in 0..<w {
            for y in 0..<(h / 5) { let p = px(x, y); if p.z > p.x + 15 && p.z > 90 { skyTop += 1 } }
            for y in (h - 12)..<h { let p = px(x, y); if p.x + p.y + p.z < 150 { darkBottom += 1 } }
        }
        // The PFD's attitude sky (saturated blue) sits left of centre on the panel.
        for y in (h / 2)..<h { for x in 0..<(w / 2) { let p = px(x, y); if p.z > 120 && p.z > p.x + 60 { pfdBlue += 1 } } }
        print("cockpit frame: skyTop \(skyTop)/\(w * h / 5), darkBottom \(darkBottom)/\(w * 12), pfdBlue \(pfdBlue)")
        #expect(skyTop > w * h / 5 / 2, "sky through the windscreen (airframe back faces skipped)")
        #expect(darkBottom > w * 12 * 3 / 4, "instrument panel across the bottom")
        #expect(pfdBlue > 150, "live PFD on the panel")
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func skyRollsWithABankedCamera() throws {
        let world = QuickFlightWorld()
        let s = QuickFlightSession(world: world, start: .runway)
        let r = try Self.renderer(world: world, cameraHeight: s.positionENU.z + 300)
        let ck = s.cockpitCamera()
        let eye = ck.position + SIMD3(0, 0, 300)
        let f = simd_normalize(ck.target - ck.position)
        let right = simd_normalize(simd_cross(f, SIMD3<Double>(0, 0, 1)))
        let w = 240, h = 240
        // Camera rolled 90°: the horizon is vertical, sky on one side and terrain on the other.
        let img = try r.render(width: w, height: h, camera: WorldCamera(position: eye, target: eye + f * 100, verticalFOVDeg: 70, up: right))
        _ = VisualRegression.check(name: "metal_roll90_240", rgb: img, width: w, height: h, goldenDir: goldenDir)
        func blue(_ x: Int, _ y: Int) -> Bool { let i = 3 * (y * w + x); return Int(img[i + 2]) > Int(img[i]) + 25 }
        let left = (blue(4, 4), blue(4, h - 5)), rightSide = (blue(w - 5, 4), blue(w - 5, h - 5))
        #expect((left.0 && left.1 && !rightSide.0 && !rightSide.1) || (rightSide.0 && rightSide.1 && !left.0 && !left.1),
                "sky fills one whole side: left \(left) right \(rightSide)")
    }
}
#endif
