// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Testing
import Foundation
import Metal
import simd
@testable import SFRender
import SFAtmosphere
import SFPreview
import SFQuickFlight

@Suite struct CloudRenderTests {
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func gpuCloudMarchMatchesCPUReference() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cr = try CloudRenderer(device: device, colorFormat: .rgba8Unorm)
        let layer = CloudLayer(coverage: 0.55)
        let toSun = simd_normalize(SIMD3<Float>(0.4, -0.3, 0.6))
        let sun = SIMD3<Float>(1.0, 0.95, 0.9), sky = SIMD3<Float>(0.18, 0.28, 0.5), ground = SIMD3<Float>(0.04, 0.05, 0.03)
        var o = [SIMD3<Float>](), d = [SIMD3<Float>](), m = [Float](), j = [Float]()
        for i in 0..<512 {
            let a = Float(i) * 0.613, e = 0.05 + Float(i % 23) / 23 * 1.2
            o.append(SIMD3(Float(i % 31) * 157 - 2_400, Float(i / 31) * 211 - 1_700, i % 4 == 0 ? 3_200 : 300))
            let z = i % 4 == 0 ? -sin(e) : sin(e)
            d.append(simd_normalize(SIMD3(cos(a) * cos(e), sin(a) * cos(e), z)))
            m.append(i % 7 == 0 ? 3_000 : .infinity)
            j.append(VolumetricClouds.jitter(x: i, y: i / 3))
        }
        let gpu = try cr.marchRays(origins: o, dirs: d, maxDist: m, jitter: j, layer: layer, toSun: toSun, sun: sun,
                                   skyAmbient: sky, groundAmbient: ground, steps: 64)
        var tErr: [Float] = [], lErr: [Float] = [], cloudy = 0
        for i in 0..<o.count {
            let c = VolumetricClouds.march(origin: o[i], dir: d[i], maxDist: m[i], layer: layer, toSun: toSun, sun: sun,
                                           skyAmbient: sky, groundAmbient: ground, steps: 64, jitter: j[i])
            if c.transmittance < 0.98 { cloudy += 1 }
            tErr.append(abs(gpu[i].transmittance - c.transmittance))
            lErr.append(simd_length(gpu[i].radiance - c.radiance) / max(0.05, simd_length(c.radiance)))
        }
        tErr.sort(); lErr.sort()
        let p95 = Int(Double(o.count) * 0.95)
        print("clouds GPU vs CPU: cloudy \(cloudy)/\(o.count), T err median \(tErr[o.count / 2]) p95 \(tErr[p95]), L rel err median \(lErr[o.count / 2]) p95 \(lErr[p95])")
        #expect(cloudy > 60, "enough rays hit clouds: \(cloudy)")
        #expect(tErr[p95] < 0.02 && lErr[p95] < 0.03)
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func cloudsAppearInSkyAndStayBehindTerrain() throws {
        let world = QuickFlightWorld()
        var dt = QuickFlightDetail.phone
        dt.objectRadius = 500; dt.nearHalfExtent = 900; dt.midHalfExtent = 2_500; dt.farHalfExtent = 6_000
        let soup = world.buildEnvironment(detail: dt)
        let session = QuickFlightSession(world: world, start: .runway)
        let base = session.chaseCamera()
        // Look slightly up so the frame holds both sky (top) and terrain (bottom).
        var f = base.target - base.position; f.z = 0; f = simd_normalize(f)
        let eye = base.position + SIMD3(0, 0, 40)
        let cam = WorldCamera(position: eye, target: eye + f * 1_000 + SIMD3(0, 0, 120))   // ≈ 7° nose-up view
        let lighting = LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z)
        let r = try WorldRenderer(lighting: lighting)
        try r.setEnvironment(soup)
        let w = 320, h = 180
        let clear = try r.render(width: w, height: h, camera: cam)
        r.clouds = CloudLayer(coverage: 0.5)
        let cloudy = try r.render(width: w, height: h, camera: cam)
        _ = VisualRegression.check(name: "metal_clouds_320x180", rgb: cloudy, width: w, height: h, goldenDir: goldenDir)
        func diff(_ y0: Int, _ y1: Int) -> (changed: Int, whiter: Int) {
            // `changed` counts brightening only: cloud shadows may darken terrain, cloud pixels never cover it.
            var changed = 0, whiter = 0
            for y in y0..<y1 { for x in 0..<w {
                let i = 3 * (y * w + x)
                let a = Int(clear[i]) + Int(clear[i + 1]) + Int(clear[i + 2]), b = Int(cloudy[i]) + Int(cloudy[i + 1]) + Int(cloudy[i + 2])
                if b > a + 6 { changed += 1 }
                // Cloud: brighter and greyer than the blue sky behind it.
                if b > a + 30 && Int(cloudy[i + 2]) - Int(cloudy[i]) < Int(clear[i + 2]) - Int(clear[i]) { whiter += 1 }
            } }
            return (changed, whiter)
        }
        let top = diff(0, h / 4), bottom = diff(h - 12, h)
        print("clouds frame: top changed \(top.changed) whiter \(top.whiter); bottom changed \(bottom.changed)")
        #expect(top.whiter > w * h / 4 / 20, "cumulus visible in the upper sky: \(top.whiter)")
        #expect(bottom.changed < w * 12 / 50, "nearby terrain is not covered by clouds: \(bottom.changed)")
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func cloudsCastShadowsOnTheGround() throws {
        let world = QuickFlightWorld()
        var dt = QuickFlightDetail.phone
        dt.objectRadius = 400; dt.nearHalfExtent = 1_500; dt.midHalfExtent = 3_000; dt.farHalfExtent = 6_000
        let lighting = LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: 800)
        let r = try WorldRenderer(lighting: lighting)
        r.shadowsEnabled = false
        try r.setEnvironment(world.buildEnvironment(detail: dt))
        // Below the layer, looking steeply down at the ground: no cloud pixels in view, only their shadows.
        let eye = SIMD3<Double>(0, -400, world.runwayElevation + 800)
        let cam = WorldCamera(position: eye, target: eye + SIMD3(0, 600, -800))
        let w = 240, h = 160
        let clear = try r.render(width: w, height: h, camera: cam)
        r.clouds = CloudLayer(coverage: 0.6)
        let shaded = try r.render(width: w, height: h, camera: cam)
        _ = VisualRegression.check(name: "metal_cloud_shadows_240x160", rgb: shaded, width: w, height: h, goldenDir: goldenDir)
        var darker = 0, brighter = 0
        for p in 0..<(w * h) {
            let a = Int(clear[3 * p]) + Int(clear[3 * p + 1]) + Int(clear[3 * p + 2])
            let b = Int(shaded[3 * p]) + Int(shaded[3 * p + 1]) + Int(shaded[3 * p + 2])
            if b < a - 20 { darker += 1 }
            if b > a + 6 { brighter += 1 }
        }
        print("cloud shadows: darker \(darker)/\(w * h), brighter \(brighter)")
        #expect(darker > w * h / 20, "cloud shadows on the ground: \(darker)")
        #expect(darker < w * h * 95 / 100, "not uniformly dark")
        #expect(brighter < w * h / 100)
    }
}
#endif
