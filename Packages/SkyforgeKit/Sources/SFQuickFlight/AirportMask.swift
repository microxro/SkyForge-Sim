// SKYFORGE — Apache-2.0
// Rasterises the bundled airport surface geometry into the rg8 `airportMask` texture the world shader reads
// (texture 9) over the airport's own rectangle at ~1 m per texel:
//   R = pavement coverage 0…1 (antialiased edge; sampled bilinearly)
//   G = class, sampled nearest: 0 none, 0.10 aerodrome infield, 0.33 apron, 0.66 taxiway/other, 1.0 runway.
// Pavement classes are dilated one texel in G so the bilinear R edge always has a pavement class underneath.
import Foundation

/// A rasterised airport mask: `texels` holds `size`² (R, G) byte pairs, row 0 north.
public struct AirportMaskRaster: Sendable, Equatable {
    public var size: Int
    public var centre: SIMD2<Double>
    public var halfExtent: Double
    public var texels: [UInt8]
}

extension AirportSurfaces {
    /// The primary runway's frame, used to give the runway line its true paved width.
    public struct PrimaryRunway: Sendable {
        public var threshold: SIMD2<Double>, direction: SIMD2<Double>, width: Double
        public init(threshold: SIMD2<Double>, direction: SIMD2<Double>, width: Double) {
            self.threshold = threshold; self.direction = direction; self.width = width
        }
    }

    static let infieldValue: UInt8 = 26

    /// Mask over the features' bounding square (plus `margin` m). The texel is `metresPerTexel` unless the
    /// airport is so large that `maxSize` texels per side would be exceeded. Nil without features.
    public func rasterise(primary: PrimaryRunway? = nil, metresPerTexel: Double = 1.0, maxSize: Int = 4096,
                          margin: Double = 60) -> AirportMaskRaster? {
        let all = features.flatMap(\.points)
        guard !all.isEmpty, let lx = all.map(\.x).min(), let hx = all.map(\.x).max(),
              let ly = all.map(\.y).min(), let hy = all.map(\.y).max() else { return nil }
        let centre = SIMD2((lx + hx) / 2, (ly + hy) / 2)
        let wantHalf = max(hx - lx, hy - ly) / 2 + margin
        let px = max(metresPerTexel, 2 * wantHalf / Double(maxSize))
        let size = max(2, Int((2 * wantHalf / px).rounded(.up)))
        // The texture spans exactly size·px; the shader maps uv over 2·halfExtent, so store that extent (no sub-texel shift).
        let half = Double(size) * px / 2
        let x0 = centre.x - half, y1 = centre.y + half
        var cov = [UInt8](repeating: 0, count: size * size), cls = [UInt8](repeating: 0, count: size * size)

        func cell(_ i: Int, _ j: Int) -> SIMD2<Double> { SIMD2(x0 + (Double(i) + 0.5) * px, y1 - (Double(j) + 0.5) * px) }
        func range(_ lo: SIMD2<Double>, _ hi: SIMD2<Double>) -> (Int, Int, Int, Int)? {
            let i0 = max(0, Int(((lo.x - x0) / px).rounded(.down))), i1 = min(size - 1, Int(((hi.x - x0) / px).rounded(.up)))
            let j0 = max(0, Int(((y1 - hi.y) / px).rounded(.down))), j1 = min(size - 1, Int(((y1 - lo.y) / px).rounded(.up)))
            return i0 > i1 || j0 > j1 ? nil : (i0, i1, j0, j1)
        }
        /// Even-odd scanline fill of `ring` over texel rows `j0...j1`: per row the edge crossings at the row's
        /// centre are sorted and the texel centres between each pair are visited (O(rows × edges), not texels × edges).
        func fill(_ ring: [SIMD2<Double>], rows j0: Int, _ j1: Int, _ body: (Int) -> Void) {
            var xs: [Double] = []
            for j in j0...j1 {
                let y = y1 - (Double(j) + 0.5) * px
                xs.removeAll(keepingCapacity: true)
                var k = ring.count - 1
                for i in 0..<ring.count {
                    let a = ring[i], b = ring[k]
                    if (a.y > y) != (b.y > y) { xs.append((b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) }
                    k = i
                }
                xs.sort()
                var m = 0
                while m + 1 < xs.count {
                    // Texel i has its centre at x0 + (i + 0.5)·px; take those with xs[m] <= centre < xs[m+1].
                    let i0 = max(0, Int(((xs[m] - x0) / px - 0.5).rounded(.up)))
                    let i1 = min(size - 1, Int(((xs[m + 1] - x0) / px - 0.5).rounded(.up)) - 1)
                    if i0 <= i1 { for i in i0...i1 { body(j * size + i) } }
                    m += 2
                }
            }
        }
        func lineWidth(_ f: AirportSurfaces.Feature) -> Double {
            if f.surface == .runway, let r = primary, f.points.count >= 2 {
                // A runway line parallel to, and within 25 m of, the primary axis takes the primary runway's width.
                let a = f.points[0], b = f.points[f.points.count - 1], d = b - a, len = (d * d).sum().squareRoot()
                let mid = (a + b) / 2 - r.threshold
                let across = abs(mid.x * r.direction.y - mid.y * r.direction.x)
                if len > 1, abs((d * r.direction).sum() / len) > 0.98, across < 25 { return r.width }
            }
            return f.widthMetres > 0 ? f.widthMetres : (f.surface == .runway ? 30 : 15)
        }

        for surface in [AirportSurfaces.Surface.boundary, .apron, .taxiway, .runway] {
            let g = AirportSurfaces.maskValue(surface)
            for f in features where f.surface == surface && f.points.count >= 2 && !f.unpaved {   // unpaved: infield, not pavement
                if f.isLine {
                    let half = max(lineWidth(f) / 2, px * 0.5)         // never thinner than a texel
                    for k in 0..<(f.points.count - 1) {
                        let a = f.points[k], b = f.points[k + 1], ab = b - a
                        let len2 = max((ab * ab).sum(), 1e-6)
                        let pad = half + px
                        guard let (_, _, j0, j1) = range(pointwiseMin(a, b) - SIMD2(repeating: pad),
                                                         pointwiseMax(a, b) + SIMD2(repeating: pad)) else { continue }
                        for j in j0...j1 {
                            // Per row: only the x span of the segment inside this row's band (± pad), not its whole bounding box.
                            let yc = y1 - (Double(j) + 0.5) * px, ylo = yc - px / 2 - pad, yhi = yc + px / 2 + pad
                            var t0 = 0.0, t1 = 1.0
                            if abs(ab.y) > 1e-9 {
                                let ta = (ylo - a.y) / ab.y, tb = (yhi - a.y) / ab.y
                                t0 = max(0, min(ta, tb)); t1 = min(1, max(ta, tb))
                            } else if a.y < ylo || a.y > yhi { continue }
                            if t0 > t1 { continue }
                            let xa = a.x + ab.x * t0, xb = a.x + ab.x * t1
                            let i0 = max(0, Int(((min(xa, xb) - pad - x0) / px).rounded(.down)))
                            let i1 = min(size - 1, Int(((max(xa, xb) + pad - x0) / px).rounded(.up)))
                            if i0 > i1 { continue }
                            for i in i0...i1 {
                                let t = max(0, min(1, ((cell(i, j) - a) * ab).sum() / len2))
                                let d = cell(i, j) - (a + ab * t)
                                let c = max(0, min(1, 0.5 + (half - (d * d).sum().squareRoot()) / px))   // antialiased edge
                                if c <= 0 { continue }
                                let n = j * size + i
                                cov[n] = max(cov[n], UInt8((c * 255).rounded()))
                                if c >= 0.5 { cls[n] = g }
                            }
                        }
                    }
                } else if f.points.count >= 3 {
                    let xs = f.points.map(\.x), ys = f.points.map(\.y)
                    guard let ax = xs.min(), let bx = xs.max(), let ay = ys.min(), let by = ys.max(),
                          let (_, _, j0, j1) = range(SIMD2(ax, ay), SIMD2(bx, by)) else { continue }
                    fill(f.points, rows: j0, j1) { n in
                        if surface != .boundary { cov[n] = 255 }
                        cls[n] = g
                    }
                }
            }
        }
        // Dilate pavement classes one texel into texels that pavement only partly covers.
        let snapshot = cls
        for j in 0..<size {
            for i in 0..<size {
                let n = j * size + i
                guard cov[n] > 0, snapshot[n] <= AirportSurfaces.infieldValue else { continue }
                var best = snapshot[n]
                for dj in -1...1 { for di in -1...1 {
                    let ii = i + di, jj = j + dj
                    if ii >= 0, jj >= 0, ii < size, jj < size { best = max(best, snapshot[jj * size + ii]) }
                } }
                cls[n] = best
            }
        }
        var texels = [UInt8](repeating: 0, count: 2 * size * size)
        var hasClass = false
        for n in 0..<(size * size) {
            texels[2 * n] = cov[n]; texels[2 * n + 1] = cls[n]
            if cls[n] != 0 { hasClass = true }
        }
        return hasClass ? AirportMaskRaster(size: size, centre: centre, halfExtent: half, texels: texels) : nil
    }
}

extension RealWorldRegion {
    /// The airport mask over the airport's own rectangle; nil without airport data.
    public func airportMask() -> AirportMaskRaster? {
        guard let a = airport else { return nil }
        let primary = AirportSurfaces.PrimaryRunway(threshold: runwayThreshold, direction: runwayDirection, width: runwayWidthMetres)
        return a.rasterise(primary: primary)
    }
}
