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
        let brightest = (0..<(w * h)).max { (Int(img[3 * $0]) + Int(img[3 * $0 + 1])) < (Int(img[3 * $1]) + Int(img[3 * $1 + 1])) }!
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
