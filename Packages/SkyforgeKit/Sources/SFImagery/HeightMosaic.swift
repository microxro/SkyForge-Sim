// SKYFORGE — Apache-2.0
// Real elevation (Terrarium tiles via TerrainStreamer) resampled to a square on the local grid.
import Foundation
import SFMath
import SFTerrainCore

public struct HeightMosaic: Sendable {
    public let centre: SIMD2<Double>
    public let halfExtent: Double
    public let size: Int
    public var heights: [Float]          // metres AMSL, row 0 = north edge
    public var metresPerSample: Double { 2 * halfExtent / Double(size - 1) }

    public static func build(origin: GeoOrigin, centre: SIMD2<Double>, halfExtent: Double, size: Int, zoom: Int,
                             streamer: TerrainStreamer) async -> HeightMosaic {
        let nw = origin.coordinate(east: centre.x - halfExtent, north: centre.y + halfExtent)
        let se = origin.coordinate(east: centre.x + halfExtent, north: centre.y - halfExtent)
        let t0 = TileCoord.containing(latitude: nw.latitude, longitude: nw.longitude, zoom: zoom)
        let t1 = TileCoord.containing(latitude: se.latitude, longitude: se.longitude, zoom: zoom)
        var tiles: [TileCoord: HeightGrid] = [:]
        await withTaskGroup(of: (TileCoord, HeightGrid).self) { g in
            for ty in t0.y...t1.y { for tx in t0.x...t1.x {
                let t = TileCoord(z: zoom, x: tx, y: ty)
                g.addTask { (t, await streamer.tile(t).0) }
            } }
            for await (t, h) in g { tiles[t] = h }
        }
        var out = [Float](repeating: 0, count: size * size)
        let step = 2 * halfExtent / Double(size - 1)
        for j in 0..<size {
            let y = centre.y + halfExtent - Double(j) * step
            for i in 0..<size {
                let x = centre.x - halfExtent + Double(i) * step
                let ll = origin.coordinate(east: x, north: y)
                let t = TileCoord.containing(latitude: ll.latitude, longitude: ll.longitude, zoom: zoom)
                guard let grid = tiles[t] else { continue }
                let f = t.fraction(latitude: ll.latitude, longitude: ll.longitude)
                out[j * size + i] = Float(grid.sample(u: f.u, v: f.v))
            }
        }
        return HeightMosaic(centre: centre, halfExtent: halfExtent, size: size, heights: out)
    }

    /// Bilinear height at a local point (clamped to the mosaic edge).
    public func height(_ x: Double, _ y: Double) -> Double {
        let fx = max(0, min(Double(size - 1) - 1e-9, (x - (centre.x - halfExtent)) / metresPerSample))
        let fy = max(0, min(Double(size - 1) - 1e-9, ((centre.y + halfExtent) - y) / metresPerSample))
        let i = Int(fx), j = Int(fy)
        let ax = fx - Double(i), ay = fy - Double(j)
        func h(_ ii: Int, _ jj: Int) -> Double { Double(heights[jj * size + ii]) }
        let a = h(i, j) + (h(i + 1, j) - h(i, j)) * ax
        let b = h(i, j + 1) + (h(i + 1, j + 1) - h(i, j + 1)) * ax
        return a + (b - a) * ay
    }
}
