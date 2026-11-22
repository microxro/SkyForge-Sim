// SKYFORGE — Apache-2.0
// Rasterises land use and roads into the 4-channel mask the terrain shader's suburban parcel generator reads
// (`SuburbShaders.source`, `suburbParcels`). Pure Swift, testable on Linux.
//
// Texture layout (RGBA8, row 0 north, same grid as `RealWorldRegion.roadMask`):
//   R  parcel weight: 255 inside residential land use that has a frontage road within `reach` metres
//   G  tangent of the nearest frontage road, angle in [0, π) × 255/π
//   B  distance to that road's centreline, metres × 255 / reach (255 = none within reach)
//   A  that road's half carriageway width in 0.25 m units
import Foundation

public enum SuburbMask {
    /// Frontage roads: streets that houses face. Motorways, links, service roads (aisles, driveways) and tracks are not.
    public static let frontage: Set<OSMHighway> = [.residential, .livingStreet, .unclassified, .tertiary, .secondary]
    public static let reach = 60.0

    /// `size`² RGBA bytes over the square `centre ± halfExtent` (region metres).
    public static func build(size: Int, centre: SIMD2<Double>, halfExtent: Double, landUse: [LandUsePolygon], roads: [OSMRoad]) -> [UInt8] {
        guard size > 1, halfExtent > 0, halfExtent.isFinite else { return [UInt8](repeating: 0, count: max(0, size) * max(0, size) * 4) }
        var out = [UInt8](repeating: 0, count: size * size * 4)
        let px = 2 * halfExtent / Double(size), x0 = centre.x - halfExtent, y1 = centre.y + halfExtent
        var bestD = [Float](repeating: .infinity, count: size * size)
        // Distances, tangent and half width of the nearest frontage road.
        for r in roads where frontage.contains(r.highway) && r.points.count >= 2 {
            let hw = r.widthMetres / 2
            for k in 0..<(r.points.count - 1) {
                let a = r.points[k], b = r.points[k + 1], ab = b - a
                let len2 = ab.x * ab.x + ab.y * ab.y
                guard len2 > 1e-6 else { continue }
                var ang = atan2(ab.y, ab.x); if ang < 0 { ang += .pi }; if ang >= .pi { ang -= .pi }
                let tangent = UInt8(max(0, min(255, (ang / .pi * 255).rounded())))
                let halfQ = UInt8(max(0, min(255, (hw * 4).rounded())))
                let lo = SIMD2(min(a.x, b.x), min(a.y, b.y)) - SIMD2(repeating: reach), hi = SIMD2(max(a.x, b.x), max(a.y, b.y)) + SIMD2(repeating: reach)
                let i0 = max(0, Int(((lo.x - x0) / px).rounded(.down))), i1 = min(size - 1, Int(((hi.x - x0) / px).rounded(.up)))
                let j0 = max(0, Int(((y1 - hi.y) / px).rounded(.down))), j1 = min(size - 1, Int(((y1 - lo.y) / px).rounded(.up)))
                if i0 > i1 || j0 > j1 { continue }
                for j in j0...j1 {
                    let y = y1 - (Double(j) + 0.5) * px
                    for i in i0...i1 {
                        let p = SIMD2(x0 + (Double(i) + 0.5) * px, y)
                        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2))
                        let d = p - (a + ab * t)
                        let dist = Float((d.x * d.x + d.y * d.y).squareRoot())
                        let idx = j * size + i
                        if dist < Float(reach) && dist < bestD[idx] {
                            bestD[idx] = dist
                            out[idx * 4 + 1] = tangent
                            out[idx * 4 + 2] = UInt8(max(0, min(254, (Double(dist) / reach * 255).rounded())))
                            out[idx * 4 + 3] = halfQ
                        }
                    }
                }
            }
        }
        for k in 0..<(size * size) where bestD[k] == .infinity { out[k * 4 + 2] = 255 }
        // Residential land use and the punch-out categories (parks, schools, commercial and the like) are painted together
        // in order of falling polygon area, so a larger polygon never erases a smaller one nested inside it: a residential
        // block inside a park stays residential, a park inside a residential area is carved out.
        let punch: Set<LandUseCategory> = [.park, .institutional, .commercial, .industrial, .golf, .cemetery, .airport, .transport]
        func area(_ r: [SIMD2<Double>]) -> Double {
            var a = 0.0, prev = r[r.count - 1]
            for p in r { a += prev.x * p.y - p.x * prev.y; prev = p }
            return abs(a) / 2
        }
        let ordered = landUse.filter { ($0.category == .residential || punch.contains($0.category)) && $0.ring.count >= 3 }
            .map { (poly: $0, area: area($0.ring)) }.sorted { $0.area > $1.area }
        var covered = [Bool](repeating: false, count: size * size)
        for item in ordered {
            let on = item.poly.category == .residential
            fill(item.poly.ring, size: size, x0: x0, y1: y1, px: px) { covered[$0] = on }
        }
        for k in 0..<(size * size) where covered[k] && bestD[k] < Float(reach) { out[k * 4] = 255 }
        return out
    }

    static func fill(_ ring: [SIMD2<Double>], size: Int, x0: Double, y1: Double, px: Double, _ set: (Int) -> Void) {
        guard let ymin = ring.map(\.y).min(), let ymax = ring.map(\.y).max() else { return }
        let j0 = max(0, Int(((y1 - ymax) / px).rounded(.down))), j1 = min(size - 1, Int(((y1 - ymin) / px).rounded(.up)))
        if j0 > j1 { return }
        var xs: [Double] = []
        for j in j0...j1 {
            let y = y1 - (Double(j) + 0.5) * px
            xs.removeAll(keepingCapacity: true)
            var prev = ring[ring.count - 1]
            for p in ring {
                if (p.y > y) != (prev.y > y) { xs.append((prev.x - p.x) * (y - p.y) / (prev.y - p.y) + p.x) }
                prev = p
            }
            xs.sort()
            var q = 0
            while q + 1 < xs.count {
                let i0 = max(0, Int(((xs[q] - x0) / px - 0.5).rounded(.up))), i1 = min(size - 1, Int(((xs[q + 1] - x0) / px - 0.5).rounded(.down)))
                if i0 <= i1 { for i in i0...i1 { set(j * size + i) } }
                q += 2
            }
        }
    }
}
