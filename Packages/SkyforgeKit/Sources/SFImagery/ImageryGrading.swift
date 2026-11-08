// SKYFORGE — Apache-2.0
// Photo grading for real-world ground imagery: a gentle de-haze (removes the grey atmospheric veil and
// lifts contrast; the renderer adds its own physically based aerial perspective on top) and a colour
// match of the near (USGS) mosaic to the far (Sentinel-2) mosaic, so the two layers meet without a seam.
import Foundation

public enum ImageryGrading {
    /// Per-channel value at `fraction` (0…1) of the covered pixels' distribution (byte histogram).
    static func percentile(_ m: ImageryMosaic, channel: Int, fraction: Double) -> Double {
        var hist = [Int](repeating: 0, count: 256), n = 0
        for p in stride(from: 0, to: m.size * m.size, by: 3) where m.coverage[p] != 0 {
            hist[Int(m.rgb[3 * p + channel])] += 1; n += 1
        }
        guard n > 0 else { return fraction < 0.5 ? 0 : 255 }
        let target = Int(Double(n) * fraction)
        var acc = 0
        for v in 0..<256 { acc += hist[v]; if acc > target { return Double(v) } }
        return 255
    }

    /// Removes a uniform grey veil (estimated from the darkest 0.5 % of each channel, the smallest of
    /// the three) and applies a mild S-curve. `strength` 0 leaves the image unchanged.
    public static func dehaze(_ m: inout ImageryMosaic, strength: Double = 1) {
        let veil = (0..<3).map { percentile(m, channel: $0, fraction: 0.005) }.min() ?? 0
        let k = min(0.6 * veil, 40) * strength                      // never strip more than ~16 % of range
        var lut = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
            var x = max(0, (Double(v) - k) / (255 - k))
            let s = x * x * (3 - 2 * x)
            x += (s - x) * 0.12 * strength
            lut[v] = UInt8(max(0, min(255, (x * 255).rounded())))
        }
        for i in 0..<m.rgb.count { m.rgb[i] = lut[Int(m.rgb[i])] }
    }

    /// Per-channel (mean, variance) of `near` block-averaged to `far`'s resolution, and of `far`, over
    /// their overlap; nil when they barely overlap.
    static func overlapStats(_ near: ImageryMosaic, _ far: ImageryMosaic) -> (near: [(Double, Double)], far: [(Double, Double)])? {
        let ratio = max(1, Int((far.metresPerPixel / near.metresPerPixel).rounded()))
        let step = max(ratio, near.size / 256)
        var sn = [Double](repeating: 0, count: 3), sf = sn, qn = sn, qf = sn
        var n = 0.0
        var j = 0
        while j + ratio <= near.size {
            var i = 0
            while i + ratio <= near.size {
                defer { i += step }
                // Near block mean at the far resolution.
                var acc = SIMD3<Double>.zero, c = 0.0, holes = false
                for y in j..<(j + ratio) { for x in i..<(i + ratio) {
                    if near.coverage[y * near.size + x] == 0 { holes = true; continue }
                    let o = 3 * (y * near.size + x)
                    acc += SIMD3(Double(near.rgb[o]), Double(near.rgb[o + 1]), Double(near.rgb[o + 2])); c += 1
                } }
                if holes || c == 0 { continue }
                let px = near.centre.x - near.halfExtent + (Double(i) + Double(ratio) / 2) * near.metresPerPixel
                let py = near.centre.y + near.halfExtent - (Double(j) + Double(ratio) / 2) * near.metresPerPixel
                guard let f = far.sample(px, py) else { continue }
                let a = acc / c, b = SIMD3(Double(f.x), Double(f.y), Double(f.z)) * 255
                for k in 0..<3 { sn[k] += a[k]; sf[k] += b[k]; qn[k] += a[k] * a[k]; qf[k] += b[k] * b[k] }
                n += 1
            }
            j += step
        }
        guard n > 16 else { return nil }
        let ns = (0..<3).map { k in (sn[k] / n, max(1, qn[k] / n - (sn[k] / n) * (sn[k] / n))) }
        let fs = (0..<3).map { k in (sf[k] / n, max(1, qf[k] / n - (sf[k] / n) * (sf[k] / n))) }
        return (ns, fs)
    }

    /// Remaps `m` so a channel with (mean, variance) `src` gets `dst`'s mean and contrast. Gain and the
    /// mean ratio are clamped to 0.75…1.33, and dark pixels are floored at 70 % of their mean-ratio-scaled
    /// value, so a contrast boost never crushes shadowed forest to black (it did: 5 % of the KMRY/KASE
    /// near pixels went to 0 with the old 0.6…1.6 linear map).
    static func remap(_ m: inout ImageryMosaic, from src: [(Double, Double)], to dst: [(Double, Double)]) -> [(gain: Double, offset: Double)] {
        var params: [(gain: Double, offset: Double)] = []
        var luts = [[UInt8]](repeating: [UInt8](repeating: 0, count: 256), count: 3)
        for k in 0..<3 {
            let (ms, vs) = src[k], (md, vd) = dst[k]
            let gain = min(1.33, max(0.75, (vd / vs).squareRoot()))
            let offset = md - gain * ms
            params.append((gain, offset))
            let ratio = min(1.33, max(0.75, md / max(1, ms)))
            for v in 0..<256 {
                let lin = Double(v) * gain + offset, floor = 0.7 * ratio * Double(v)
                luts[k][v] = UInt8(max(0, min(255, max(lin, floor).rounded())))
            }
        }
        for p in 0..<(m.size * m.size) {
            for k in 0..<3 { m.rgb[3 * p + k] = luts[k][Int(m.rgb[3 * p + k])] }
        }
        return params
    }

    /// Matches `near`'s per-channel mean and (block-averaged) contrast to `far` over their overlap.
    /// Near detail finer than the far mosaic's pixels is kept: gain is measured on near averaged to
    /// the far resolution, then applied to all deviations from the mean. Returns (gain, offset) per channel.
    @discardableResult
    public static func match(_ near: inout ImageryMosaic, to far: ImageryMosaic) -> [(gain: Double, offset: Double)] {
        guard let s = overlapStats(near, far) else { return [(1, 0), (1, 0), (1, 0)] }
        return remap(&near, from: s.near, to: s.far)
    }

    /// The reverse: matches the coarse `far` mosaic to the fine `near` one. The near aerial photo is the
    /// better albedo reference (Sentinel-2 composites at these zooms come out darker and flatter), and
    /// the far layer is only seen at distance, so this is what `ImageryGround` uses.
    @discardableResult
    public static func match(far: inout ImageryMosaic, to near: ImageryMosaic) -> [(gain: Double, offset: Double)] {
        guard let s = overlapStats(near, far) else { return [(1, 0), (1, 0), (1, 0)] }
        return remap(&far, from: s.far, to: s.near)
    }

    /// Brightens a dark mosaic (Sentinel-2 cloudless over conifer forest came out with a median sRGB
    /// luminance near 0.12, rendering near-black) with a gamma curve that moves the median toward
    /// `target`; black and white stay put and order is kept. Never darkens; gamma ≥ `minGamma`.
    /// Returns the gamma applied (1 = unchanged).
    @discardableResult
    public static func lift(_ m: inout ImageryMosaic, target: Double = 0.26, minGamma: Double = 0.7) -> Double {
        var hist = [Int](repeating: 0, count: 256), n = 0
        for p in stride(from: 0, to: m.size * m.size, by: 7) where m.coverage[p] != 0 {
            let l = 0.2126 * Double(m.rgb[3 * p]) + 0.7152 * Double(m.rgb[3 * p + 1]) + 0.0722 * Double(m.rgb[3 * p + 2])
            hist[min(255, Int(l.rounded()))] += 1; n += 1
        }
        guard n > 0 else { return 1 }
        var acc = 0, median = 0
        for v in 0..<256 { acc += hist[v]; if acc * 2 >= n { median = v; break } }
        let l = max(1, Double(median)) / 255
        guard l < target else { return 1 }
        let gamma = max(minGamma, log(target) / log(l))
        var lut = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 { lut[v] = UInt8(max(0, min(255, (pow(Double(v) / 255, gamma) * 255).rounded()))) }
        for k in 0..<m.rgb.count { m.rgb[k] = lut[Int(m.rgb[k])] }
        return gamma
    }
}
