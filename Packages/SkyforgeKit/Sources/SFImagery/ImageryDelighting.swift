// SKYFORGE — Apache-2.0
// Removes the photo's own trees and their baked shadows where 3D trees stand. The instanced crowns cast
// their own shadow-map shadows, so the photo's tree blobs and black shadows beneath them read as doubled
// (art rounds 13–19: the main limit at KMRY, KBFI, KASE and NZQN). Runtime fixes either left rims
// (suppression, round 5) or flat grey ovals (a shadow decal, round 13), or did too little (a toe).
// Here, once per mosaic when the render data is built: a mask of photo canopy and of pixels darker than
// their surroundings, limited to discs around the placed 3D trees, is filled from the known ground around
// it by push-pull inpainting (a weighted pyramid, coarse to fine), so each hole takes the colour of the lit
// ground next to it rather than an average.
import Foundation

public enum ImageryDelighting {
    /// A placed 3D tree: centre (local metres) and the radius its photo crown and shadow can reach.
    public struct Crown: Sendable, Equatable {
        public var centre: SIMD2<Double>
        public var radius: Double
        public init(centre: SIMD2<Double>, radius: Double) { self.centre = centre; self.radius = radius }
    }

    /// Mask weight per pixel (0–1): canopy or shadow, inside a crown disc, not water.
    public static func mask(_ m: ImageryMosaic, crowns: [Crown], feather: Double = 2.5, localRadius: Double = 10,
                            water: ((Double, Double) -> Float)? = nil) -> [Float] {
        let n = m.size, mpp = m.metresPerPixel
        let x0 = m.centre.x - m.halfExtent, y1 = m.centre.y + m.halfExtent
        var cover = [Float](repeating: 0, count: n * n)
        for c in crowns {
            let fx = (c.centre.x - x0) / mpp - 0.5, fy = (y1 - c.centre.y) / mpp - 0.5
            let rOut = (c.radius + feather) / mpp
            let i0 = max(0, Int((fx - rOut).rounded(.down))), i1 = min(n - 1, Int((fx + rOut).rounded(.up)))
            let j0 = max(0, Int((fy - rOut).rounded(.down))), j1 = min(n - 1, Int((fy + rOut).rounded(.up)))
            if i0 > i1 || j0 > j1 { continue }
            for j in j0...j1 {
                for i in i0...i1 {
                    let dx = Double(i) - fx, dy = Double(j) - fy
                    let d = (dx * dx + dy * dy).squareRoot() * mpp
                    let w = Float(max(0, min(1, (c.radius + feather - d) / feather)))
                    if w > cover[j * n + i] { cover[j * n + i] = w }
                }
            }
        }
        // Luminance (sRGB, 0–1) and its local mean over ±localRadius (integral image).
        var lum = [Float](repeating: 0, count: n * n)
        for p in 0..<(n * n) {
            lum[p] = (0.2126 * Float(m.rgb[3 * p]) + 0.7152 * Float(m.rgb[3 * p + 1]) + 0.0722 * Float(m.rgb[3 * p + 2])) / 255
        }
        var integral = [Double](repeating: 0, count: (n + 1) * (n + 1))
        for j in 0..<n {
            var row = 0.0
            for i in 0..<n {
                row += Double(lum[j * n + i])
                integral[(j + 1) * (n + 1) + i + 1] = integral[j * (n + 1) + i + 1] + row
            }
        }
        let r = max(1, Int((localRadius / mpp).rounded()))
        func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t) }
        var mask = [Float](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n where cover[j * n + i] > 0 {
                let p = j * n + i
                let a0 = max(0, i - r), a1 = min(n, i + r + 1), b0 = max(0, j - r), b1 = min(n, j + r + 1)
                let sum = integral[b1 * (n + 1) + a1] - integral[b0 * (n + 1) + a1] - integral[b1 * (n + 1) + a0] + integral[b0 * (n + 1) + a0]
                let mean = Float(sum / Double((a1 - a0) * (b1 - b0)))
                let rr = Float(m.rgb[3 * p]) / 255, gg = Float(m.rgb[3 * p + 1]) / 255, bb = Float(m.rgb[3 * p + 2]) / 255
                // Photo crown: green above red and blue, not a bright lawn.
                let canopy = smooth(0.0, 0.03, gg - max(rr, bb)) * smooth(0.42, 0.30, lum[p])
                // Shadow: clearly darker than the ground around it.
                let shadow = smooth(0.85, 0.6, lum[p] / max(mean, 0.02))
                var w = max(canopy, shadow) * cover[p]
                if w > 0, let water {
                    let x = x0 + (Double(i) + 0.5) * mpp, y = y1 - (Double(j) + 0.5) * mpp
                    w *= 1 - smooth(0.2, 0.4, water(x, y))
                }
                mask[p] = w
            }
        }
        // Where most of the ground within ~25 m is masked (closed forest) there is nothing lit to fill
        // from, and the 3D canopy hides the ground anyway: fade the mask out there (keep the photo).
        var known = [Double](repeating: 0, count: (n + 1) * (n + 1))
        for j in 0..<n {
            var row = 0.0
            for i in 0..<n {
                row += Double(1 - mask[j * n + i])
                known[(j + 1) * (n + 1) + i + 1] = known[j * (n + 1) + i + 1] + row
            }
        }
        let rk = max(1, Int((25 / mpp).rounded()))
        for j in 0..<n {
            for i in 0..<n where mask[j * n + i] > 0 {
                let a0 = max(0, i - rk), a1 = min(n, i + rk + 1), b0 = max(0, j - rk), b1 = min(n, j + rk + 1)
                let sum = known[b1 * (n + 1) + a1] - known[b0 * (n + 1) + a1] - known[b1 * (n + 1) + a0] + known[b0 * (n + 1) + a0]
                let frac = Float(sum / Double((a1 - a0) * (b1 - b0)))
                mask[j * n + i] *= smooth(0.15, 0.35, frac)
            }
        }
        return mask
    }

    /// Push-pull fill of a `width` × `height` RGB image: pixels keep `1 − mask` of their own colour and take
    /// the rest from the known pixels around them, found through a pyramid of weighted 2 × 2 averages.
    public static func inpaint(rgb: inout [UInt8], width sw: Int, height sh: Int, mask: [Float]) {
        var levels: [(w: Int, h: Int, col: [SIMD3<Float>], wt: [Float])] = []
        var col = [SIMD3<Float>](repeating: .zero, count: sw * sh), wt = [Float](repeating: 0, count: sw * sh)
        for p in 0..<(sw * sh) {
            let k = 1 - mask[p]
            wt[p] = k
            col[p] = SIMD3(Float(rgb[3 * p]), Float(rgb[3 * p + 1]), Float(rgb[3 * p + 2])) * k
        }
        levels.append((sw, sh, col, wt))
        // Push: sum 2 × 2 blocks (weights capped at 1 with the mean colour kept) down to 1 × 1.
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let (w, h, c, k) = levels.last!
            let w2 = (w + 1) / 2, h2 = (h + 1) / 2
            var c2 = [SIMD3<Float>](repeating: .zero, count: w2 * h2), k2 = [Float](repeating: 0, count: w2 * h2)
            for j in 0..<h { for i in 0..<w { let q = (j / 2) * w2 + i / 2; c2[q] += c[j * w + i]; k2[q] += k[j * w + i] } }
            for q in 0..<(w2 * h2) where k2[q] > 1 { c2[q] /= k2[q]; k2[q] = 1 }
            levels.append((w2, h2, c2, k2))
        }
        // Pull: each level's holes take the bilinear-upsampled colour of the level above.
        let top = levels.last!
        var coarse = [top.wt[0] > 0 ? top.col[0] / top.wt[0] : SIMD3<Float>(128, 128, 128)]
        var cw = 1, ch = 1
        for li in stride(from: levels.count - 2, through: 0, by: -1) {
            let (w, h, c, k) = levels[li]
            var out = [SIMD3<Float>](repeating: .zero, count: w * h)
            for j in 0..<h {
                let fy = max(0, min(Float(ch - 1), (Float(j) + 0.5) / 2 - 0.5))
                let y0 = Int(fy), y1 = min(ch - 1, y0 + 1), ty = fy - Float(y0)
                for i in 0..<w {
                    let fx = max(0, min(Float(cw - 1), (Float(i) + 0.5) / 2 - 0.5))
                    let x0 = Int(fx), x1 = min(cw - 1, x0 + 1), tx = fx - Float(x0)
                    let top: SIMD3<Float> = coarse[y0 * cw + x0] * (1 - tx) + coarse[y0 * cw + x1] * tx
                    let bottom: SIMD3<Float> = coarse[y1 * cw + x0] * (1 - tx) + coarse[y1 * cw + x1] * tx
                    let up: SIMD3<Float> = top * (1 - ty) + bottom * ty
                    let p = j * w + i
                    out[p] = c[p] + up * (1 - min(1, k[p]))   // c is premultiplied by its weight (≤ 1)
                }
            }
            coarse = out; cw = w; ch = h
        }
        for p in 0..<(sw * sh) where mask[p] > 0 {
            let v = coarse[p]
            rgb[3 * p] = UInt8(max(0, min(255, v.x.rounded())))
            rgb[3 * p + 1] = UInt8(max(0, min(255, v.y.rounded())))
            rgb[3 * p + 2] = UInt8(max(0, min(255, v.z.rounded())))
        }
    }

    /// Masks and fills `m` in place; returns how many pixels were mostly replaced (mask > 0.5).
    @discardableResult
    public static func removePhotoTrees(_ m: inout ImageryMosaic, crowns: [Crown], water: ((Double, Double) -> Float)? = nil) -> Int {
        guard !crowns.isEmpty, m.size > 1 else { return 0 }
        let mk = mask(m, crowns: crowns, water: water)
        let changed = mk.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
        guard changed > 0 else { return 0 }
        // In 512 px tiles with a 64 px apron: holes are tens of metres at most, and a whole-mosaic pyramid
        // would need ~270 MB at 4096².
        let n = m.size, tile = 512, apron = 64
        for ty in stride(from: 0, to: n, by: tile) {
            for tx in stride(from: 0, to: n, by: tile) {
                let ax = max(0, tx - apron), ay = max(0, ty - apron)
                let bx = min(n, tx + tile + apron), by = min(n, ty + tile + apron)
                let w = bx - ax, h = by - ay
                var any = false
                for j in max(ty, ay)..<min(n, ty + tile) where !any {
                    for i in max(tx, ax)..<min(n, tx + tile) where mk[j * n + i] > 0 { any = true; break }
                }
                if !any { continue }
                var sub = [UInt8](repeating: 0, count: w * h * 3), sm = [Float](repeating: 0, count: w * h)
                for j in 0..<h {
                    for i in 0..<w {
                        let p = (ay + j) * n + ax + i, q = j * w + i
                        sub[3 * q] = m.rgb[3 * p]; sub[3 * q + 1] = m.rgb[3 * p + 1]; sub[3 * q + 2] = m.rgb[3 * p + 2]
                        sm[q] = mk[p]
                    }
                }
                inpaint(rgb: &sub, width: w, height: h, mask: sm)
                for j in ty..<min(n, ty + tile) {
                    for i in tx..<min(n, tx + tile) {
                        let p = j * n + i, q = (j - ay) * w + (i - ax)
                        m.rgb[3 * p] = sub[3 * q]; m.rgb[3 * p + 1] = sub[3 * q + 1]; m.rgb[3 * p + 2] = sub[3 * q + 2]
                    }
                }
            }
        }
        return changed
    }
}
