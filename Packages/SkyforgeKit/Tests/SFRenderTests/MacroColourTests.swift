// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFRender

/// Round 3 maths (CPU reference of `MacroColourShaders`): the cloud clamp, the 128 m median, the macro hue and
/// the decoupled lawn. Pure maths, no Metal device needed.
@Suite struct MacroColourTests {
    typealias R = MacroColourReference
    let lawn = SIMD3<Float>(0.080, 0.125, 0.045)

    @Test func softClampIsIdentityInsideAndBoundedOutside() {
        #expect(R.softClamp(1.0, lo: 0.94, hi: 1.12, kLo: 0.06, kHi: 0.18) == 1.0)
        let dark = R.softClamp(0.3, lo: 0.94, hi: 1.12, kLo: 0.06, kHi: 0.18)
        #expect(dark >= 0.879 && dark < 0.94)
        let bright = R.softClamp(5.0, lo: 0.94, hi: 1.12, kLo: 0.06, kHi: 0.18)
        #expect(bright <= 1.3001 && bright > 1.12)
        // Monotonic.
        var prev: Float = -1
        for i in 0..<200 { let v = R.softClamp(Float(i) * 0.02, lo: 0.88, hi: 1.18, kLo: 0.12, kHi: 0.25); #expect(v >= prev); prev = v }
    }

    @Test func cloudClampKeepsChromaAndStripsDarkBlotches() {
        let shadowed = lawn * 0.45                        // a baked cloud shadow, same chroma
        let out = R.cloudClamp(shadowed, median: R.luma(lawn))
        let ratio = R.luma(out) / R.luma(lawn)
        #expect(ratio > 0.75 && ratio < 0.90)            // from 0.45 to within the −24 … −10 % band
        let c0 = shadowed / R.luma(shadowed), c1 = out / R.luma(out)
        #expect(abs(c0.x - c1.x) < 1e-4 && abs(c0.y - c1.y) < 1e-4 && abs(c0.z - c1.z) < 1e-4)
        // Lit ground in range is untouched.
        let lit = R.cloudClamp(lawn * 1.05, median: R.luma(lawn))
        #expect(abs(R.luma(lit) / R.luma(lawn) - 1.05) < 1e-4)
    }

    @Test func medianOfFourIgnoresOneOutlier() {
        #expect(abs(R.medianOfFour(1, 1.1, 1.2, 0.1) - 1.05) < 1e-5)   // sorted 0.1, 1, 1.1, 1.2 → (1 + 1.1) / 2
        #expect(R.medianOfFour(0.2, 0.2, 0.2, 0.2) == 0.2)
        #expect(R.medianOfFour(5, 1, 3, 2) == 2.5)
    }

    @Test func macroGridMedianRejectsACloudInOneQuadrant() {
        // 256 m square at 4 m/px; a dark cloud covers one 64 m cell's quadrant.
        let size = 64
        var photo = [SIMD3<Float>](repeating: lawn, count: size * size)
        for j in 0..<16 { for i in 0..<16 { photo[j * size + i] = lawn * 0.3 } }
        let g = R.build(photo: photo, size: size, extent: 256, cell: 64)
        #expect(g.size == 4)
        let cloudy = g.rgb[0], medianL = g.median[1 * g.size + 1]
        #expect(R.luma(cloudy) < R.luma(lawn) * 0.8)                         // the mean still shows the cloud
        #expect(abs(medianL - R.luma(lawn)) < 0.05 * R.luma(lawn) + 1e-4)    // an interior cell's median ignores it
    }

    @Test func macroHueRemovesBlueCastAndCapsSaturation() {
        let blueGrey = SIMD3<Float>(0.060, 0.070, 0.105)
        let h = R.macroHue(blueGrey)
        #expect(h.z < h.x * 1.05)                          // no longer blue-dominant
        #expect(abs(R.luma(h) - 1) < 0.02)                 // still unit luminance
        let neon = R.macroHue(SIMD3<Float>(0.01, 0.30, 0.01))
        #expect(neon.max() - neon.min() <= 0.701)
    }

    @Test func decoupledLawnSpreadCollapsesUnderBlotches() {
        // 400 photo pixels of one lawn: ±40 % luminance blotches and a hue wobble; macro = the true lawn mean.
        var raw: [Float] = [], out: [Float] = []
        var seed: UInt32 = 12345
        func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) }
        let ml = R.luma(lawn)
        for i in 0..<400 {
            let blotch = 0.6 + 0.8 * rnd()
            let wob = SIMD3<Float>(1 + 0.2 * (rnd() - 0.5), 1, 1 + 0.2 * (rnd() - 0.5))
            let pix = lawn * blotch * wob
            raw.append(R.luma(pix))
            let w = SIMD2<Float>(Float(i % 20) * 3.0 + 100, Float(i / 20) * 3.0 + 100)
            out.append(R.luma(R.decouple(albedo: pix, macroAlb: lawn, median: ml, w: w, fp: 0.5)))
        }
        func cv(_ a: [Float]) -> Float {
            let m = a.reduce(0, +) / Float(a.count)
            return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(a.count)).squareRoot() / m
        }
        #expect(cv(out) < 0.5 * cv(raw))
        #expect(!out.contains { $0.isNaN || $0 < 0 })
    }

    @Test func detailFadesOutWithFootprintAndIsBounded() {
        let k = R.classify(macroAlb: lawn, forest: 0, steep: 0, roadNear: 0, burb: 0)
        #expect(k.grass > 0.8)
        let far = R.detail(k, w: SIMD2(310.3, 77.7), fp: 40, roadNear: 0, burb: 0)
        #expect(abs(far - 1) < 1e-3)                       // every octave gone at a 40 m footprint
        for i in 0..<200 {
            let f = R.detail(k, w: SIMD2(Float(i) * 0.37, Float(i) * 0.61), fp: 0.05, roadNear: 0, burb: 0)
            #expect(f > 0.6 && f < 1.4)
        }
    }

    @Test func darkCarParkKeepsItsToneInsideALawn() {
        // A dark car park (0.4 × asphalt) at a lawn's edge: the 128 m median and the 400 m mean are lawn-bright, but
        // the pavement clamp is against the 30 m mean (the car park's own), so its tone must survive. The old test
        // only asked for > 0.5 and passed with the patch nearly erased.
        let asphalt = SIMD3<Float>(0.07, 0.07, 0.075)
        let car = asphalt * 0.4
        let out = R.decouple(albedo: car, macroAlb: asphalt, median: R.luma(lawn), localMedian: R.luma(car), wideAlb: lawn,
                             roadNear: 1, w: SIMD2(5, 5), fp: 0.5)
        let ratio = R.luma(out) / R.luma(car)
        #expect(ratio > 0.97 && ratio < 1.03)
        // Without a local median it would be clamped against the 128 m median and lifted: that is the bug the
        // localMedian parameter exists to prevent, so check the fallback really differs.
        let lifted = R.decouple(albedo: car, macroAlb: asphalt, median: R.luma(lawn), wideAlb: lawn,
                                roadNear: 1, w: SIMD2(5, 5), fp: 0.5)
        #expect(R.luma(lifted) > R.luma(out) * 1.5)
    }

    @Test func pavementStillStripsASmallDarkBlotchOnItself() {
        // A tree shadow on an apron (0.3 × the 30 m mean) is lifted to the 0.76 floor, not left black.
        let asphalt = SIMD3<Float>(0.07, 0.07, 0.075)
        let out = R.decouple(albedo: asphalt * 0.3, macroAlb: asphalt, median: R.luma(asphalt), localMedian: R.luma(asphalt),
                             roadNear: 1, w: SIMD2(5, 5), fp: 0.5)
        let ratio = R.luma(out) / R.luma(asphalt)
        #expect(ratio > 0.75 && ratio < 0.90)
    }

    @Test func darkPatchUnder128mIsPulledTowardTheLawnNotErased() {
        // A 40 m cloud shadow at 0.4 × the lawn inside a 128 m cell whose mean it dilutes to 0.85: the median ignores it.
        // fp 40 turns every detail octave off so the number is the clamp's alone.
        let ml = R.luma(lawn)
        let out = R.decouple(albedo: lawn * 0.4, macroAlb: lawn * 0.85, median: ml, w: SIMD2(200, 200), fp: 40)
        let ratio = R.luma(out) / ml
        #expect(ratio > 0.80 && ratio < 1.0)
    }

    @Test func forestAndSteepGroundAreNotFlattenedByTheWidePull() {
        let dark = SIMD3<Float>(0.020, 0.030, 0.015)           // shaded forest floor
        // Forest: untouched, the caller's old path owns it.
        let f = R.decouple(albedo: dark, macroAlb: dark, median: R.luma(dark), wideAlb: lawn, forest: 1, w: SIMD2(9, 9), fp: 0.5)
        #expect(f == dark)
        // Steep slope: the wide (400 m, lawn-bright) mean must not lift a shaded slope.
        let slope = SIMD3<Float>(0.050, 0.052, 0.058)
        let withWide = R.decouple(albedo: slope, macroAlb: slope, median: R.luma(slope), wideAlb: lawn, steep: 1, w: SIMD2(9, 9), fp: 40)
        let noWide = R.decouple(albedo: slope, macroAlb: slope, median: R.luma(slope), wideAlb: .zero, steep: 1, w: SIMD2(9, 9), fp: 40)
        #expect(withWide == noWide)
        // Flat ground does take the wide pull.
        let flatWide = R.decouple(albedo: lawn * 0.7, macroAlb: lawn * 0.7, median: R.luma(lawn) * 0.7, wideAlb: lawn, w: SIMD2(9, 9), fp: 40)
        let flatNoWide = R.decouple(albedo: lawn * 0.7, macroAlb: lawn * 0.7, median: R.luma(lawn) * 0.7, w: SIMD2(9, 9), fp: 40)
        #expect(R.luma(flatWide) > R.luma(flatNoWide))
    }

    @Test func missingMedianLeavesTheAlbedoAlone() {
        // The shader skips a macro texel whose alpha is 0 (the 1×1 fallback); the reference mirrors that.
        let px = SIMD3<Float>(0.05, 0.07, 0.03)
        #expect(R.decouple(albedo: px, macroAlb: .zero, median: 0, w: SIMD2(1, 1), fp: 1) == px)
    }
}
