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
        let k = min(0.85 * veil, 60) * strength                     // never strip more than ~24 % of range
        var lut = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
            var x = max(0, (Double(v) - k) / (255 - k))
            let s = x * x * (3 - 2 * x)
            x += (s - x) * 0.18 * strength
            lut[v] = UInt8(max(0, min(255, (x * 255).rounded())))
        }
        for i in 0..<m.rgb.count { m.rgb[i] = lut[Int(m.rgb[i])] }
    }

    /// Matches `near`'s per-channel mean and (block-averaged) contrast to `far` over their overlap.
    /// Near detail finer than the far mosaic's pixels is kept: gain is measured on near averaged to
    /// the far resolution, then applied to all deviations from the mean. Returns (gain, offset) per channel.
    @discardableResult
    public static func match(_ near: inout ImageryMosaic, to far: ImageryMosaic) -> [(gain: Double, offset: Double)] {
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
        guard n > 16 else { return [(1, 0), (1, 0), (1, 0)] }
        var params: [(gain: Double, offset: Double)] = []
        for k in 0..<3 {
            let mn = sn[k] / n, mf = sf[k] / n
            let vn = max(1, qn[k] / n - mn * mn), vf = max(1, qf[k] / n - mf * mf)
            let gain = min(1.6, max(0.6, (vf / vn).squareRoot()))
            params.append((gain, mf - gain * mn))
        }
        var luts = [[UInt8]](repeating: [UInt8](repeating: 0, count: 256), count: 3)
        for k in 0..<3 { for v in 0..<256 { luts[k][v] = UInt8(max(0, min(255, (Double(v) * params[k].gain + params[k].offset).rounded()))) } }
        for p in 0..<(near.size * near.size) {
            for k in 0..<3 { near.rgb[3 * p + k] = luts[k][Int(near.rgb[3 * p + k])] }
        }
        return params
    }
}
