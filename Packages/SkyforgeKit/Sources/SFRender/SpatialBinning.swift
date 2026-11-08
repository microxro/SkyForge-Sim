// SKYFORGE — Apache-2.0
// Spatial cells for the static environment mesh so the renderer can frustum-cull the main pass and
// cull shadow casters per cascade. Platform independent (tested on Linux).

/// A contiguous vertex range of the reordered mesh with its bounds (mesh-local metres).
public struct MeshCell: Sendable, Equatable {
    public var start: Int
    public var count: Int
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>
}

public enum SpatialBinning {
    /// Groups triangles (3 consecutive positions each) into square cells of the XY plane by centroid.
    /// Returns the triangle order (indices into the input) and per-cell vertex ranges in that order;
    /// cells are row-major so neighbours along a row are adjacent in memory (draws coalesce).
    public static func bin(positions: [SIMD3<Float>], cellsAcross: Int = 48, minCell: Float = 500) -> (order: [Int], cells: [MeshCell]) {
        let n = positions.count / 3
        guard n > 0 else { return ([], []) }
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for p in positions { lo = simd_min2(lo, SIMD2(p.x, p.y)); hi = simd_max2(hi, SIMD2(p.x, p.y)) }
        let extent = Swift.max(hi.x - lo.x, hi.y - lo.y)
        let cell = Swift.max(minCell, extent / Float(cellsAcross))
        let nx = Swift.max(1, Int(((hi.x - lo.x) / cell).rounded(.up)) + 1)
        let ny = Swift.max(1, Int(((hi.y - lo.y) / cell).rounded(.up)) + 1)
        var key = [Int](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: nx * ny)
        for t in 0..<n {
            let c = (positions[3 * t] + positions[3 * t + 1] + positions[3 * t + 2]) / 3
            let ix = Swift.min(nx - 1, Swift.max(0, Int((c.x - lo.x) / cell)))
            let iy = Swift.min(ny - 1, Swift.max(0, Int((c.y - lo.y) / cell)))
            key[t] = iy * nx + ix
            counts[key[t]] += 1
        }
        var offsets = [Int](repeating: 0, count: nx * ny + 1)
        for k in 0..<(nx * ny) { offsets[k + 1] = offsets[k] + counts[k] }
        var cursor = offsets
        var order = [Int](repeating: 0, count: n)
        for t in 0..<n { order[cursor[key[t]]] = t; cursor[key[t]] += 1 }
        var cells: [MeshCell] = []
        for k in 0..<(nx * ny) where counts[k] > 0 {
            var mn = SIMD3<Float>(repeating: .infinity), mx = SIMD3<Float>(repeating: -.infinity)
            for i in offsets[k]..<offsets[k + 1] {
                let t = order[i]
                for v in 0..<3 { let p = positions[3 * t + v]; mn = simd_min3(mn, p); mx = simd_max3(mx, p) }
            }
            cells.append(MeshCell(start: offsets[k] * 3, count: counts[k] * 3, min: mn, max: mx))
        }
        return (order, cells)
    }

    /// Contiguous vertex ranges covering the cells for which `visible` is true (adjacent cells merged).
    public static func runs(_ cells: [MeshCell], visible: (MeshCell) -> Bool) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for c in cells where visible(c) {
            if let last = out.last, last.upperBound == c.start { out[out.count - 1] = last.lowerBound..<(c.start + c.count) }
            else { out.append(c.start..<(c.start + c.count)) }
        }
        return out
    }

    @inline(__always) static func simd_min2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { SIMD2(Swift.min(a.x, b.x), Swift.min(a.y, b.y)) }
    @inline(__always) static func simd_max2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { SIMD2(Swift.max(a.x, b.x), Swift.max(a.y, b.y)) }
    @inline(__always) static func simd_min3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z)) }
    @inline(__always) static func simd_max3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { SIMD3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z)) }
}
