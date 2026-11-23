// SKYFORGE — Apache-2.0
// Surveyed-footprint index for the procedural building fill: is a spot clear of every OSM building?
import Foundation

/// Footprints bucketed on a square grid, so the fill can ask whether a point lies within `clearance` metres of any
/// surveyed building without scanning them all. Footprints too wide to bucket are checked directly.
public struct BuildingGapIndex: Sendable {
    /// Bucket size (m). A clearance query looks at the buckets its radius reaches into.
    static let cell: Double = 40
    /// Footprints wider or taller than this (m) are not bucketed; they would fill too many buckets.
    static let widthLimit: Double = 600
    /// Coordinates beyond this magnitude (m) are not bucketed (the bucket index would overflow an Int).
    static let coordinateLimit: Double = 1e7

    private let footprints: [[SIMD2<Double>]]
    private var buckets: [SIMD2<Int>: [Int]] = [:]
    private var wide: [Int] = []

    public init(footprints: [[SIMD2<Double>]]) {
        self.footprints = footprints.filter { $0.count >= 3 }
        for k in self.footprints.indices {
            let ring = self.footprints[k]
            let xs = ring.map(\.x), ys = ring.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { continue }
            let finite = [x0, x1, y0, y1].allSatisfy { $0.isFinite && abs($0) < Self.coordinateLimit }
            guard finite, x1 - x0 <= Self.widthLimit, y1 - y0 <= Self.widthLimit else { wide.append(k); continue }
            let bx0 = Int((x0 / Self.cell).rounded(.down)), bx1 = Int((x1 / Self.cell).rounded(.down))
            let by0 = Int((y0 / Self.cell).rounded(.down)), by1 = Int((y1 / Self.cell).rounded(.down))
            for by in by0...by1 {
                for bx in bx0...bx1 {
                    buckets[SIMD2(bx, by), default: []].append(k)
                }
            }
        }
    }

    /// True when no surveyed footprint lies within `clearance` metres of `p`. A point inside a footprint is not clear.
    public func isClear(_ p: SIMD2<Double>, clearance: Double) -> Bool {
        guard p.x.isFinite, p.y.isFinite, abs(p.x) < Self.coordinateLimit, abs(p.y) < Self.coordinateLimit,
              clearance.isFinite, clearance >= 0 else { return false }
        let reach = Int((clearance / Self.cell).rounded(.up))
        let cx = Int((p.x / Self.cell).rounded(.down)), cy = Int((p.y / Self.cell).rounded(.down))
        for by in (cy - reach)...(cy + reach) {
            for bx in (cx - reach)...(cx + reach) {
                for k in buckets[SIMD2(bx, by)] ?? [] where Self.reaches(footprints[k], p, clearance) { return false }
            }
        }
        for k in wide where Self.reaches(footprints[k], p, clearance) { return false }
        return true
    }

    /// Whether `p` is inside `ring` or within `d` metres of its outline.
    static func reaches(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>, _ d: Double) -> Bool {
        if OSMGeometry.contains(ring, p) { return true }
        let limit = d * d
        for k in ring.indices {
            let a = ring[k], b = ring[(k + 1) % ring.count]
            if segmentDistanceSquared(p, a, b) <= limit { return true }
        }
        return false
    }

    /// Squared distance from `p` to the segment `a`–`b`.
    static func segmentDistanceSquared(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let len2 = (ab * ab).sum()
        let t = len2 > 0 ? max(0, min(1, ((p - a) * ab).sum() / len2)) : 0
        let q = a + ab * t - p
        return (q * q).sum()
    }
}
