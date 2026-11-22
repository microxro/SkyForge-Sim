// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFRender

@Suite struct AAShadowMathTests {
    @Test func haltonKnownValues() {
        #expect(TAAJitter.halton(1, base: 2) == 0.5)
        #expect(TAAJitter.halton(2, base: 2) == 0.25)
        #expect(TAAJitter.halton(3, base: 2) == 0.75)
        #expect(abs(TAAJitter.halton(1, base: 3) - 1.0 / 3.0) < 1e-6)
        #expect(abs(TAAJitter.halton(2, base: 3) - 2.0 / 3.0) < 1e-6)
    }

    @Test func jitterIsInRangeDistinctAndCycles() {
        var seen = Set<[Float]>()
        for f in 0..<16 {
            let j = TAAJitter.pixelJitter(frame: f, length: 16)
            #expect(abs(j.x) < 0.5 && abs(j.y) < 0.5)
            seen.insert([j.x, j.y])
            #expect(j == TAAJitter.pixelJitter(frame: f + 16, length: 16))
        }
        #expect(seen.count == 16)
        #expect(TAAJitter.pixelJitter(frame: 5, length: 1) == .zero)
        let mean = (0..<16).map { TAAJitter.pixelJitter(frame: $0, length: 16) }.reduce(SIMD2<Float>.zero, +) / 16
        #expect(abs(mean.x) < 0.05 && abs(mean.y) < 0.05)
    }

    @Test func ndcOffsetScalesWithResolutionAndFlipsY() {
        let o = TAAJitter.ndcOffset(pixelJitter: SIMD2(0.5, 0.25), width: 1000, height: 500)
        #expect(abs(o.x - 0.001) < 1e-7 && abs(o.y + 0.001) < 1e-7)
    }

    @Test func ycocgRoundTripsAndClipStaysInBox() {
        let c = SIMD3<Float>(0.8, 0.3, 0.1)
        let r = TAAMath.yCoCgToRGB(TAAMath.rgbToYCoCg(c))
        #expect(abs(r.x - c.x) < 1e-6 && abs(r.y - c.y) < 1e-6 && abs(r.z - c.z) < 1e-6)
        let lo = SIMD3<Float>(0, -0.1, -0.1), hi = SIMD3<Float>(1, 0.1, 0.1)
        let inside = SIMD3<Float>(0.5, 0, 0)
        #expect(TAAMath.clipToAABB(history: inside, centre: inside, lo: lo, hi: hi) == inside)
        let out = TAAMath.clipToAABB(history: SIMD3(0.5, 0.5, 0), centre: SIMD3(0.5, 0, 0), lo: lo, hi: hi)
        #expect(out.y <= 0.1 + 1e-4 && out.y > 0)
        #expect(TAAMath.blendWeight(clipDistance: 0, historyValid: false) == 1)
        #expect(TAAMath.blendWeight(clipDistance: 0, historyValid: true) == 0.1)
    }

    @Test func varianceBoundsContainMean() {
        let s: [SIMD3<Float>] = [SIMD3(0.2, 0, 0), SIMD3(0.4, 0.1, 0), SIMD3(0.6, -0.1, 0.05)]
        let b = TAAMath.neighbourhoodBounds(s)
        #expect(b.lo.x < 0.4 && b.hi.x > 0.4)
    }

    @Test func reprojectionOfStaticCameraIsIdentity() {
        let id = AAMat4.identity
        let r = TAAReprojection.previousUV(uv: SIMD2(0.3, 0.7), depth: 0.5, inverseCurrent: id, previous: id)
        #expect(abs(r.uv.x - 0.3) < 1e-6 && abs(r.uv.y - 0.7) < 1e-6 && r.onScreen)
    }

    @Test func reprojectionTracksTranslation() {
        // previous frame saw the world shifted +0.2 in NDC x.
        var t = AAMat4.identity; t.m[12] = 0.2
        let r = TAAReprojection.previousUV(uv: SIMD2(0.5, 0.5), depth: 0.5, inverseCurrent: .identity, previous: t)
        #expect(abs(r.uv.x - 0.6) < 1e-6)
        var far = AAMat4.identity; far.m[12] = 2
        #expect(!TAAReprojection.previousUV(uv: SIMD2(0.5, 0.5), depth: 0.5, inverseCurrent: .identity, previous: far).onScreen)
    }

    @Test func splitsAreMonotonicAndEndAtFar() {
        let s = CascadeMath.splits(count: 4, near: 0.5, far: 24_000)
        #expect(s.count == 4)
        #expect(zip(s, s.dropFirst()).allSatisfy { $0 < $1 })
        #expect(abs(s[3] - 24_000) < 1)
        let lin = CascadeMath.splits(count: 4, near: 1, far: 100, lambda: 0)
        #expect(abs(lin[0] - 25.75) < 1e-3)
    }

    @Test func sliceRadiusGrowsAndIsQuantised() {
        let a = CascadeMath.sliceRadius(near: 0.5, far: 100, verticalFOV: 1, aspect: 16.0 / 9)
        let b = CascadeMath.sliceRadius(near: 100, far: 1_000, verticalFOV: 1, aspect: 16.0 / 9)
        #expect(b > a && a > 0)
        #expect((a * 16).rounded() == a * 16)
        #expect(a == CascadeMath.sliceRadius(near: 0.5, far: 100, verticalFOV: 1, aspect: 16.0 / 9))
    }

    @Test func snappingIsStableUnderSubTexelMotion() {
        let texel = 0.5
        let base = 1_234_567.3
        let s0 = CascadeMath.snap(base, texel: texel)
        #expect(s0.truncatingRemainder(dividingBy: texel) == 0)
        for d in stride(from: 0.0, to: 0.19, by: 0.05) { #expect(CascadeMath.snap(base + d, texel: texel) == s0) }
        #expect(CascadeMath.snap(base + texel, texel: texel) == s0 + texel)
        #expect(CascadeMath.snap(-0.1, texel: texel) == -0.5)
    }

    @Test func cascadeSelectionAndBlend() {
        let sp: [Float] = [100, 400, 1_600, 6_400]
        #expect(CascadeMath.cascade(forViewDepth: 50, splits: sp) == 0)
        #expect(CascadeMath.cascade(forViewDepth: 400, splits: sp) == 2)
        #expect(CascadeMath.cascade(forViewDepth: 7_000, splits: sp) == nil)
        // Tier-bounded count: a 2-cascade tier never selects index 2 or 3.
        #expect(CascadeMath.cascade(forViewDepth: 150, splits: sp, count: 2) == 1)
        #expect(CascadeMath.cascade(forViewDepth: 500, splits: sp, count: 2) == nil)
        #expect(CascadeMath.blendToNext(distance: 50, index: 1, splits: sp, near: 1, blendFraction: 0.1) == 0)
        #expect(CascadeMath.blendToNext(distance: 399.9, index: 1, splits: sp, near: 1, blendFraction: 0.1) > 0.99)
        let mid = CascadeMath.blendToNext(distance: 385, index: 1, splits: sp, near: 1, blendFraction: 0.1)
        #expect(mid > 0.1 && mid < 0.9)
        #expect(CascadeMath.blendToNext(distance: 6_000, index: 3, splits: sp, near: 1, blendFraction: 0.1) == 0)
        #expect(CascadeMath.blendToNext(distance: 99, index: 0, splits: sp, near: 1, blendFraction: 0) == 0)
    }

    @Test func penumbraGrowsWithSeparation() {
        #expect(CascadeMath.penumbraWidth(blockerDepth: 10, receiverDepth: 10) == 0)
        let p = CascadeMath.penumbraWidth(blockerDepth: 0, receiverDepth: 100)
        #expect(abs(p - 0.93) < 0.01)
    }

    @Test func tiersScale() {
        #expect(!AAShadowTier.low.usesTAA && AAShadowTier.medium.usesTAA)
        #expect(AAShadowTier.ultra.cascadeCount == 4 && AAShadowTier.low.cascadeCount == 2)
        #expect(!AAShadowTier.medium.usesPCSS && AAShadowTier.high.usesPCSS)
        #expect(AAShadowTier.allCases.map(\.shadowMapSize) == [1024, 2048, 2048, 4096])
    }

    @Test func viewDepthIgnoresLateralOffset() {
        // A point 90 m ahead and 80 m to the side is radially 120 m away but only 90 m deep: cascade 0, not 1.
        let rel = SIMD3<Float>(80, 90, 0), fwd = SIMD3<Float>(0, 1, 0)
        let d = CascadeMath.viewDepth(rel: rel, forward: fwd)
        #expect(d == 90)
        #expect(CascadeMath.cascade(forViewDepth: d, splits: [100, 400]) == 0)
        #expect(CascadeMath.cascade(forViewDepth: (rel * rel).sum().squareRoot(), splits: [100, 400]) == 1)
    }

    @Test func shadowMemoryWithinBudgetAndTapsPositive() {
        for t in AAShadowTier.allCases {
            #expect(t.shadowMemoryBytes <= AAShadowTier.shadowMemoryBudget)
            #expect(t.pcfTaps >= 1 && t.cascadeCount <= AAShadowTier.maxCascades && t.cascadeCount >= 1)
        }
        #expect(AAShadowTier.ultra.shadowMemoryBytes == 128 * 1024 * 1024)
    }

    @Test func taaHistoryResetConditions() {
        var h = TAAHistoryState()
        let e = SIMD3<Double>(0, 0, 100)
        #expect(h.beginFrame(width: 1920, height: 1080, eye: e) == .firstFrame)
        #expect(h.beginFrame(width: 1920, height: 1080, eye: e + SIMD3(1, 0, 0)) == nil)
        #expect(h.beginFrame(width: 2560, height: 1440, eye: e + SIMD3(1, 0, 0)) == .resize)
        #expect(h.beginFrame(width: 2560, height: 1440, eye: e + SIMD3(1, 0, 0), cameraCut: true) == .cameraCut)
        #expect(h.beginFrame(width: 2560, height: 1440, eye: e + SIMD3(50_000, 0, 0)) == .teleport)
        #expect(h.beginFrame(width: 2560, height: 1440, eye: e + SIMD3(50_001, 0, 0)) == nil)
        h.invalidate()
        #expect(h.beginFrame(width: 2560, height: 1440, eye: e + SIMD3(50_001, 0, 0)) == .firstFrame)
    }
}
