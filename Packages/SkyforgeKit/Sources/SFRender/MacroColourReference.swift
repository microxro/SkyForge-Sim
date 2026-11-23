// SKYFORGE — Apache-2.0
// CPU reference for `MacroColourShaders` (round 3): the same operations in the same order, so tests and the
// preview renderer can check the GPU path and the maths can be reasoned about without a Metal device.
// Foundation only; no Metal.
import Foundation

public enum MacroColourReference {
    public typealias V3 = SIMD3<Float>
    public typealias V2 = SIMD2<Float>

    public static let lumW = V3(0.2126, 0.7152, 0.0722)
    static let warm = V3(1.04, 1.0, 0.86)

    public static func luma(_ c: V3) -> Float { (c * lumW).sum() }
    static func saturate(_ x: Float) -> Float { min(1, max(0, x)) }
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = saturate((x - a) / (b - a)); return t * t * (3 - 2 * t)
    }
    static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    static func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }

    // MARK: noise (mc_hash / mc_vnoise / mc_n)

    static func fract(_ x: Float) -> Float { x - x.rounded(.down) }
    static func hash(_ i: V2, _ period: Float) -> Float {
        func m(_ x: Float) -> Float { (x.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) }
        let ii = V2(m(i.x), m(i.y))
        var p = V2(fract(ii.x * 0.1031), fract(ii.y * 0.1030))
        let d = p.x * (p.y + 33.33) + p.y * (p.x + 33.33)
        p += V2(repeating: d)
        return fract((p.x + p.y) * p.x)
    }
    static func vnoise(_ x: V2, _ period: Float) -> Float {
        let i = V2(x.x.rounded(.down), x.y.rounded(.down)), f = x - i
        let s = f * f * (V2(repeating: 3) - 2 * f)
        let a = hash(i, period), b = hash(i + V2(1, 0), period), c = hash(i + V2(0, 1), period), d = hash(i + V2(1, 1), period)
        return mix(mix(a, b, s.x), mix(c, d, s.x), s.y) * 2 - 1
    }
    /// Noise in [-1, 1], cells `cell` metres (a power of two, 0.125 … 8).
    public static func n(_ w: V2, _ cell: Float) -> Float { vnoise(w / cell, 4096 / cell) }
    public static func fade(_ fp: Float, _ cell: Float) -> Float { saturate(1 - fp / (0.6 * cell)) }

    // MARK: hue, clamp

    public static func macroHue(_ macroAlb: V3) -> V3 {
        let L = max(luma(macroAlb), 1e-3)
        var h = macroAlb / L
        let blue = smoothstep(0, 0.06, (h.z - max(h.x * 0.85, h.y)) / max(h.z, 1e-3))
        let neutral = warm / (warm * lumW).sum()
        h = mix(h, neutral, 0.85 * blue)
        let range = h.max() - h.min()
        let cap: Float = 0.70
        if range > cap { h = V3(repeating: 1) + (h - V3(repeating: 1)) * (cap / range) }
        return h
    }

    public static func softClamp(_ r: Float, lo: Float, hi: Float, kLo: Float, kHi: Float) -> Float {
        if r < lo { return lo - kLo * tanh(min((lo - r) / kLo, 8)) }
        if r > hi { return hi + kHi * tanh(min((r - hi) / kHi, 8)) }
        return r
    }

    /// Luminance-delta clamp against `median`, chroma (rgb / luminance) unchanged.
    public static func cloudClamp(_ albedo: V3, median: Float) -> V3 {
        let L = max(luma(albedo), 1e-4), M = max(median, 0.01)
        let rc = softClamp(L / M, lo: 0.88, hi: 1.18, kLo: 0.12, kHi: 0.25)
        return albedo * (M * rc / L)
    }

    // MARK: macro texture (macro_colour_build)

    /// Median of four values: the mean of the middle two.
    public static func medianOfFour(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
        let lo = max(min(a, b), min(c, d)), hi = min(max(a, b), max(c, d))
        return 0.5 * (lo + hi)
    }

    /// Builds the macro grid from a square photo (row 0 north, linear rgb, `size`² pixels covering `extent` m):
    /// each cell is `cell` m; rgb = the mean of four box taps (`cell` m wide) at ±cell/2 around the cell
    /// centre, a = the median of the taps' luminance.
    public static func build(photo: [V3], size: Int, extent: Float, cell: Float = 64) -> (size: Int, rgb: [V3], median: [Float]) {
        let px = extent / Float(size)
        let n = max(1, Int((extent / cell).rounded()))
        func box(_ cx: Float, _ cy: Float) -> V3 {      // cx, cy in metres from the square's NW corner (x east, y south)
            let half = cell / 2
            let i0 = max(0, Int(((cx - half) / px).rounded(.down))), i1 = min(size - 1, Int(((cx + half) / px).rounded(.up)) - 1)
            let j0 = max(0, Int(((cy - half) / px).rounded(.down))), j1 = min(size - 1, Int(((cy + half) / px).rounded(.up)) - 1)
            guard i0 <= i1, j0 <= j1 else { return photo[min(size - 1, max(0, Int(cy / px))) * size + min(size - 1, max(0, Int(cx / px)))] }
            var s = V3.zero
            for j in j0...j1 { for i in i0...i1 { s += photo[j * size + i] } }
            return s / Float((i1 - i0 + 1) * (j1 - j0 + 1))
        }
        var rgb = [V3](repeating: .zero, count: n * n), med = [Float](repeating: 0, count: n * n)
        for gy in 0..<n {
            for gx in 0..<n {
                let cx = (Float(gx) + 0.5) * cell, cy = (Float(gy) + 0.5) * cell
                let taps = [box(cx - cell / 2, cy - cell / 2), box(cx + cell / 2, cy - cell / 2),
                            box(cx - cell / 2, cy + cell / 2), box(cx + cell / 2, cy + cell / 2)]
                let l = taps.map(luma)
                rgb[gy * n + gx] = (taps[0] + taps[1] + taps[2] + taps[3]) * 0.25
                med[gy * n + gx] = medianOfFour(l[0], l[1], l[2], l[3])
            }
        }
        return (n, rgb, med)
    }

    // MARK: classes and decoupling

    public struct Classes: Equatable {
        public var grass: Float, dry: Float, soil: Float, rock: Float, pave: Float
    }

    public static func classify(macroAlb c: V3, forest: Float, steep: Float, roadNear: Float, burb: Float) -> Classes {
        let hi = c.max(), lo = c.min()
        let chroma = (hi - lo) / max(hi, 1e-3)
        let l = luma(c)
        var grass = smoothstep(0, 0.03, c.y - max(c.x, c.z) * 0.92) * (1 - forest)
        var dry = smoothstep(0.08, 0.25, (c.x - c.z) / max(hi, 1e-3)) * smoothstep(0.02, 0.10, l) * (1 - grass)
        var rock = smoothstep(0.45, 0.75, steep) * smoothstep(0.30, 0.12, chroma) * (1 - burb)
        var pave = max(smoothstep(0.22, 0.10, chroma) * (1 - grass) * (1 - smoothstep(0.30, 0.55, steep)), 0)
        pave = max(pave * (1 - rock), roadNear * 0.6)
        var soil = max(0, 1 - grass - dry - rock - pave) * (1 - forest)
        let scale = (1 - forest) / max(1e-3, grass + dry + soil + rock + pave)
        grass *= scale; dry *= scale; soil *= scale; rock *= scale; pave *= scale
        return Classes(grass: grass, dry: dry, soil: soil, rock: rock, pave: pave)
    }

    /// Luminance factor only (the part of `mc_detail` that tests and the numpy check rely on): grass, dry,
    /// soil and rock octaves, verge and mowing bands.
    public static func detail(_ k: Classes, w: V2, fp: Float, roadNear: Float, burb: Float) -> Float {
        var f: Float = 1
        if k.grass > 0.01 {
            let blades = n(w + 5.3, 0.125) * fade(fp, 0.125), clumps = n(w - 9.1, 1) * fade(fp, 1)
            let tufts = n(w + 41, 2) * fade(fp, 2), p4 = n(w - 63, 4) * fade(fp, 4), p8 = n(w + 23, 8) * fade(fp, 8)
            let p16 = n(w - 117, 16) * fade(fp, 16), p32 = n(w + 201, 32) * fade(fp, 32)
            let g = 1 + 0.08 * blades + 0.08 * clumps + 0.06 * saturate(tufts) - 0.10 * saturate(-tufts) + 0.06 * p4 + 0.05 * p8
                + 0.05 * p16 + 0.04 * p32
            f *= mix(1, g, k.grass)
        }
        if k.dry > 0.01 {
            let a = 0.6 + 1.2 * n(w + 61, 8)
            let d = V2(cos(a), sin(a))
            let sw = V2((w * d).sum() / 3, (w.x * -d.y + w.y * d.x) * 2)
            let streak = n(sw + 13, 1) * fade(fp, 1), tuft = n(w - 3.7, 0.25) * fade(fp, 0.25), bare = n(w + 44, 4) * fade(fp, 4)
            f *= mix(1, (1 + 0.12 * streak + 0.14 * tuft) * (1 - 0.10 * saturate(bare)), k.dry)
        }
        if k.soil > 0.01 {
            let pebbles = n(w + 2.9, 0.125) * fade(fp, 0.125), clods = n(w - 17, 0.5) * fade(fp, 0.5), blotch = n(w + 8, 4) * fade(fp, 4)
            f *= mix(1, (1 + 0.14 * pebbles) * (1 + 0.12 * clods) * (1 + 0.14 * blotch), k.soil)
        }
        if k.rock > 0.01 {
            let ridge = 1 - abs(n(V2(w.x * 0.25, w.y * 2) + 7, 1))
            let blocks = n(w - 31, 4) * fade(fp, 4), speck = n(w + 97, 0.125) * fade(fp, 0.125)
            f *= mix(1, (0.90 + 0.14 * ridge * fade(fp, 1)) * (1 + 0.10 * blocks) * (1 + 0.10 * speck), k.rock)
        }
        let verge = roadNear * (1 - k.pave)
        if verge > 0.01 { f *= 1 + verge * (0.10 * n(w + 71, 0.125) * fade(fp, 0.125) - 0.06) }
        if burb > 0.01 && k.grass > 0.01 {
            let blk = V2((w.x / 128).rounded(.down) * 128, (w.y / 128).rounded(.down) * 128)
            let ang = Float.pi * (0.5 + 0.5 * n(blk + 71, 8))
            let st = sin((w.x * cos(ang) + w.y * sin(ang)) * (6.28318 / 8))
            f *= 1 + 0.03 * st * burb * k.grass * saturate(1 - fp / 4)
        }
        return f
    }

    /// `mc_decoupleGround` without the tint and tilt: the albedo the shader writes when the old stack left `albedo` equal to the photo
    /// (the shader returns the unmixed result and the weight `amount × (1 − forest)`; this applies the mix). `localMedian` is the 30 m mean
    /// luminance (the pavement clamp's median); <= 0 falls back to `median`.
    public static func decouple(albedo: V3, macroAlb: V3, median: Float, localMedian: Float = 0, wideAlb: V3 = .zero,
                                forest: Float = 0, steep: Float = 0, roadNear: Float = 0, burb: Float = 0, w: V2, fp: Float,
                                amount: Float = 1, photoKeep: Float = 0.15) -> V3 {
        let amt = amount * (1 - saturate(forest))
        if amt <= 0 || median <= 0 { return albedo }
        let M = max(median, 0.01)
        let wideL = luma(wideAlb)
        let wideGate: Float = wideL > 0 ? (1 - saturate(forest)) * (1 - smoothstep(0.25, 0.55, steep)) : 0
        let Mw = mix(M, max(wideL, 0.01), 0.7 * wideGate)
        let Lm = max(luma(macroAlb), 1e-3), Lp = max(luma(albedo), 1e-4)
        let k = classify(macroAlb: macroAlb, forest: forest, steep: steep, roadNear: roadNear, burb: burb)
        var hue = macroHue(macroAlb)
        if wideGate > 0 { hue = mix(hue, macroHue(wideAlb), 0.7 * wideGate) }
        let rc = softClamp(Lm / Mw, lo: mix(0.94, 0.97, wideGate), hi: mix(1.12, 1.04, wideGate),
                           kLo: mix(0.06, 0.03, wideGate), kHi: mix(0.18, 0.08, wideGate))
        let resid = min(1.25, max(0.8, Lp / Lm))
        let Lnat = Mw * rc * mix(1, resid, photoKeep)
        let natural = hue * (Lnat * detail(k, w: w, fp: fp, roadNear: roadNear, burb: burb))
        let paved = cloudClamp(albedo, median: localMedian > 0 ? localMedian : M)
        let pw = saturate(k.pave)
        return mix(albedo, mix(natural, paved, pw), amt)
    }
}
