// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFRender
import SFPreview
#if canImport(Metal)
import Metal
#endif

let goldenDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/golden")

func expectGolden(_ name: String, rgb: [UInt8], width: Int, height: Int, tolerance: ImageDiff.Tolerance = .init()) {
    switch VisualRegression.check(name: name, rgb: rgb, width: width, height: height, goldenDir: goldenDir, tolerance: tolerance) {
    case .passed, .blessed: break
    case let .failed(d, artefacts): Issue.record("\(name) differs from golden: \(d); see \(artefacts)")
    case let .missingGolden(path): Issue.record("\(name) has no golden; candidate at \(path) (run with SKYFORGE_BLESS=1 after review)")
    }
}

@Suite struct ImageDiffTests {
    func gradient(_ w: Int, _ h: Int, shift: Int = 0) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { a[3 * (y * w + x) + c] = UInt8(((x + shift) * 4 + y * 2 + c * 40) & 0xFF) } } }
        return a
    }

    @Test func identicalImagesPassExactly() {
        let a = gradient(64, 32)
        let d = ImageDiff.compare(a, a, width: 64, height: 32)
        #expect(d.meanAbsError == 0 && d.maxAbsError == 0 && abs(d.ssim - 1) < 1e-12)
        #expect(d.passes(.exact))
    }

    @Test func shiftedImageFailsDefaultTolerance() {
        let d = ImageDiff.compare(gradient(64, 32), gradient(64, 32, shift: 3), width: 64, height: 32)
        #expect(!d.passes(ImageDiff.Tolerance()))
    }

    @Test func oneLevelNoisePasses() {
        let a = gradient(64, 32)
        let b = a.enumerated().map { $0.offset % 7 == 0 ? UInt8(min(255, Int($0.element) + 1)) : $0.element }
        #expect(ImageDiff.compare(a, b, width: 64, height: 32).passes(ImageDiff.Tolerance()))
    }

    @Test func missingGoldenWritesCandidateAndBlessWritesGolden() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-golden-\(UUID().uuidString)")
        let out = dir.appendingPathComponent("out")
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = gradient(16, 16)
        let env = ["SKYFORGE_VISUAL_OUT": out.path]
        guard case let .missingGolden(p) = VisualRegression.check(name: "g", rgb: img, width: 16, height: 16, goldenDir: dir, environment: env) else {
            Issue.record("expected missingGolden"); return
        }
        #expect(FileManager.default.fileExists(atPath: p))
        guard case .blessed = VisualRegression.check(name: "g", rgb: img, width: 16, height: 16, goldenDir: dir,
                                                     environment: env.merging(["SKYFORGE_BLESS": "1"]) { $1 }) else {
            Issue.record("expected blessed"); return
        }
        guard case .passed = VisualRegression.check(name: "g", rgb: img, width: 16, height: 16, goldenDir: dir, environment: env) else {
            Issue.record("expected pass against blessed golden"); return
        }
        guard case let .failed(_, art) = VisualRegression.check(name: "g", rgb: gradient(16, 16, shift: 5), width: 16, height: 16,
                                                                goldenDir: dir, environment: env) else {
            Issue.record("expected failure"); return
        }
        #expect(art.count == 2 && art.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }
}

@Suite struct SkyRegressionTests {
    @Test func cpuSkyReferenceMatchesGolden() {
        let img = SkyReference.render(width: 192, height: 108)
        expectGolden("sky_reference_192x108", rgb: img, width: 192, height: 108,
                     tolerance: .init(meanAbsError: 0.3, pixelThreshold: 3, fractionOver: 0.001, minSSIM: 0.995))
    }

    @Test func skyReferenceHasHorizonAndSun() {
        let w = 192, h = 108
        let img = SkyReference.render(width: w, height: h)
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = 3 * (y * w + x); return (Int(img[i]), Int(img[i + 1]), Int(img[i + 2])) }
        let top = px(20, 2), bottom = px(20, h - 2)
        #expect(top.2 > top.0)                 // zenith bluer than red
        #expect(bottom.1 > bottom.2 || bottom.0 > bottom.2)  // ground is not sky blue
        var brightest = 0, best = -1
        for i in 0..<(w * h) {
            let v: Int = Int(img[3 * i]) + Int(img[3 * i + 1])
            if v > best { best = v; brightest = i }
        }
        #expect(brightest % w > w / 2)         // sun is right of centre (sunDirection.x > 0)
    }

    #if canImport(Metal)
    static let hasDevice = MTLCreateSystemDefaultDevice() != nil

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func metalOffscreenSkyMatchesCPUReference() throws {
        let w = 192, h = 108
        let gpu = try OffscreenSkyRenderer().render(width: w, height: h)
        let cpu = SkyReference.render(width: w, height: h)
        let d = ImageDiff.compare(gpu, cpu, width: w, height: h, pixelThreshold: 12)
        _ = VisualRegression.check(name: "metal_sky_192x108", rgb: gpu, width: w, height: h, goldenDir: goldenDir)  // artefact for review
        #expect(d.passes(.init(meanAbsError: 1.0, pixelThreshold: 12, fractionOver: 0.005, minSSIM: 0.98)), "\(d)")
    }
    #endif
}

#if canImport(Metal)
import SFAtmosphere

@Suite struct AtmosphereGPUTests {
    static func relErr(_ gpu: [SIMD3<Float>], _ cpu: [SIMD3<Float>], floor: Float) -> (mean: Float, max: Float) {
        var sum: Float = 0, mx: Float = 0
        for (g, c) in zip(gpu, cpu) {
            for k in 0..<3 {
                let e = abs(g[k] - c[k]) / max(abs(c[k]), floor)
                sum += e; mx = max(mx, e)
            }
        }
        return (sum / Float(gpu.count * 3), mx)
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func gpuLUTsMatchCPUReference() throws {
        let p = AtmosphereParameters()
        let sunZenithCos = sin(10 * Double.pi / 180), h = 0.5
        let gen = try AtmosphereLUTGenerator()
        let tex = try gen.generate(p, viewHeightKm: h, sunZenithCos: sunZenithCos)
        let tCPU = SkyAtmosphere.computeTransmittance(p)
        let msCPU = SkyAtmosphere.computeMultiScattering(p, transmittance: tCPU)
        let svCPU = SkyAtmosphere.computeSkyView(p, transmittance: tCPU, multiScattering: msCPU, viewHeightKm: h, sunZenithCos: sunZenithCos)
        let t = Self.relErr(try gen.readBack(tex.transmittance), tCPU.data, floor: 1e-3)
        let m = Self.relErr(try gen.readBack(tex.multiScattering), msCPU.data, floor: 1e-6)
        let s = Self.relErr(try gen.readBack(tex.skyView), svCPU.data, floor: 1e-5)
        #expect(t.mean < 1e-3 && t.max < 2e-2, "transmittance \(t)")
        #expect(m.mean < 1e-2 && m.max < 5e-2, "multi-scattering \(m)")
        #expect(s.mean < 1e-2 && s.max < 8e-2, "sky-view \(s)")
    }
}
#endif

#if canImport(Metal)
@Suite struct PhysicalSkyPassTests {
    /// CPU oracle: the same camera through SkyModel.radiance and the same tone curve.
    static func cpuSky(_ v: SkyView, width w: Int, height h: Int) -> [UInt8] {
        let m = SkyModel(sunElevationDeg: v.sunElevationDeg, sunAzimuthDeg: v.sunAzimuthDeg, viewHeightKm: v.viewHeightKm)
        let b = v.basis
        let tanX = tan(v.horizontalFOVDeg * .pi / 360), tanY = tanX * Double(h) / Double(w)
        func aces(_ x: Double) -> Double { min(1, max(0, (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14))) }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let nx = (Double(x) + 0.5) / Double(w) * 2 - 1, ny = 1 - (Double(y) + 0.5) / Double(h) * 2
                var d = b.forward + b.right * (nx * tanX) + b.up * (ny * tanY)
                d /= (d * d).sum().squareRoot()
                let L = m.radiance(d)
                for k in 0..<3 { out[3 * (y * w + x) + k] = UInt8((pow(aces(L[k] * v.exposure), 1 / 2.2) * 255).rounded()) }
            }
        }
        return out
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func gpuSkyPassMatchesCPUSkyModel() throws {
        var v = SkyView()
        v.sunElevationDeg = 12; v.sunAzimuthDeg = 30; v.yawDeg = 10; v.pitchDeg = 18; v.exposure = 9
        let w = 192, h = 108
        let gpu = try PhysicalSkyRenderer().render(width: w, height: h, view: v)
        let cpu = Self.cpuSky(v, width: w, height: h)
        _ = VisualRegression.check(name: "metal_physical_sky_192x108", rgb: gpu, width: w, height: h, goldenDir: goldenDir)
        let d = ImageDiff.compare(gpu, cpu, width: w, height: h, pixelThreshold: 16)
        #expect(d.passes(.init(meanAbsError: 2.0, pixelThreshold: 16, fractionOver: 0.01, minSSIM: 0.97)), "\(d)")
    }
}
#endif

#if canImport(Metal)
import SFQuickFlight
import simd

@Suite struct WorldRenderTests {
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func quickFlightFrameRenders() throws {
        let world = QuickFlightWorld()
        var d = QuickFlightDetail.phone
        d.objectRadius = 600; d.nearHalfExtent = 1_000; d.midHalfExtent = 3_000; d.farHalfExtent = 8_000
        let soup = world.buildEnvironment(detail: d)
        let session = QuickFlightSession(world: world, start: .final)
        let cam = session.chaseCamera()
        let lighting = LightingSetup.physicalPreset(.goldenHour, azimuthDegrees: 255, cameraHeightMetres: cam.position.z)
        let r = try WorldRenderer(lighting: lighting)
        try r.setEnvironment(soup)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        let c = session.bodyToENUColumns
        let w = 320, h = 180
        let img = try r.render(width: w, height: h, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        _ = VisualRegression.check(name: "metal_quickflight_320x180", rgb: img, width: w, height: h, goldenDir: goldenDir)
        func px(_ x: Int, _ y: Int) -> SIMD3<Int> { let i = 3 * (y * w + x); return SIMD3(Int(img[i]), Int(img[i + 1]), Int(img[i + 2])) }
        let top = px(w / 4, 3), bottom = px(w / 4, h - 3)
        #expect(top.z > top.x, "sky at top is blue: \(top)")
        #expect(bottom.z < bottom.x || bottom.z < bottom.y, "ground at bottom is not sky: \(bottom)")
        // The white aircraft sits in the lower middle of a chase view.
        var bright = 0
        for y in (h / 3)..<h { for x in (w / 3)..<(2 * w / 3) where px(x, y).x > 180 && px(x, y).y > 180 && px(x, y).z > 170 { bright += 1 } }
        #expect(bright > 30, "aircraft pixels \(bright)")
    }
}
#endif

#if canImport(Metal)
@Suite struct WorldShadowTests {
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func sunShadowsDarkenTheScene() throws {
        let world = QuickFlightWorld()
        var d = QuickFlightDetail.phone
        d.objectRadius = 500; d.nearHalfExtent = 900; d.midHalfExtent = 2_500; d.farHalfExtent = 6_000
        let soup = world.buildEnvironment(detail: d)
        // Low chase view over the runway with a low sun: trees and the aircraft cast long shadows.
        let session = QuickFlightSession(world: world, start: .runway)
        let cam = session.chaseCamera(distance: 30, height: 12)
        let lighting = LightingSetup.physicalPreset(.goldenHour, azimuthDegrees: 255, cameraHeightMetres: cam.position.z)
        let r = try WorldRenderer(lighting: lighting)
        try r.setEnvironment(soup)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        let c = session.bodyToENUColumns
        let m = simd_double3x3(columns: (c.0, c.1, c.2))
        let w = 320, h = 180
        let wc = WorldCamera(position: cam.position, target: cam.target)
        let lit = try r.render(width: w, height: h, camera: wc, aircraftPosition: session.positionENU, aircraftBodyToENU: m)
        r.shadowsEnabled = false
        let flat = try r.render(width: w, height: h, camera: wc, aircraftPosition: session.positionENU, aircraftBodyToENU: m)
        _ = VisualRegression.check(name: "metal_shadows_320x180", rgb: lit, width: w, height: h, goldenDir: goldenDir)
        var darker = 0, brighter = 0
        for p in 0..<(w * h) {
            let a = Int(lit[3 * p]) + Int(lit[3 * p + 1]) + Int(lit[3 * p + 2])
            let b = Int(flat[3 * p]) + Int(flat[3 * p + 1]) + Int(flat[3 * p + 2])
            if a < b - 24 { darker += 1 }
            if a > b + 6 { brighter += 1 }
        }
        // Calibrated on CI run 42444704578's frame: runway view where the aircraft's own shadow plus
        // distant tree shadows cover 1.9 % of the frame; 1 % still fails if shadows vanish.
        #expect(darker > w * h / 100, "shadowed pixels \(darker)")
        #expect(brighter < w * h / 200, "shadows never brighten: \(brighter)")
    }
}
#endif
