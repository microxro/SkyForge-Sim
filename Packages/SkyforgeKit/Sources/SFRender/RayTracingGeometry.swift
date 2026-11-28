// SKYFORGE — Apache-2.0
// Scene geometry for the ray tracing passes. Terrain is sampled from the height field at a coarse grid, because
// CDLOD keeps only GPU buffers. Buildings and roads come from the same triangle soup the mesh pass draws.
// Positions are (x, y, height), the frame CDLODNodeMesher and RealWorldRegion already use.
#if canImport(Metal)
import Foundation
import simd
import SFPreview
import SFQuickFlight

public enum RayTracingGeometry {
    /// Coarse terrain grid over the near height square, `spacing` metres between samples (at least 2 per side).
    public static func terrainMesh(field: TerrainHeightField, spacing: Double = 64) -> RTTriangleMesh {
        let m = field.near
        let extent = 2 * m.halfExtent
        let n = max(2, Int((extent / max(1, spacing)).rounded(.up)) + 1)
        let step = extent / Double(n - 1)
        let x0 = m.centre.x - m.halfExtent, y0 = m.centre.y - m.halfExtent

        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                let x = x0 + Double(i) * step
                let y = y0 + Double(j) * step
                verts.append(SIMD3(Float(x), Float(y), Float(field.height(x, y))))
            }
        }

        var idx: [UInt32] = []
        idx.reserveCapacity((n - 1) * (n - 1) * 6)
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = UInt32(j * n + i), b = a + 1, c = a + UInt32(n), d = c + 1
                idx += [a, c, b, b, c, d]
            }
        }
        return RTTriangleMesh(vertices: verts, indices: idx)
    }

    /// Buildings and roads: the soup's triangles, three positions each, as an indexed mesh.
    public static func soupMesh(_ soup: TriangleSoup) -> RTTriangleMesh {
        let verts = soup.positions
        return RTTriangleMesh(vertices: verts, indices: Array(0..<UInt32(verts.count)))
    }

    /// Terrain plus buildings in one mesh. Returns nil when neither is present, so the caller builds no scene.
    public static func sceneMesh(terrain: TerrainHeightField?, buildings: TriangleSoup?,
                                 terrainSpacing: Double = 64) -> RTTriangleMesh? {
        var verts: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        if let terrain {
            let t = terrainMesh(field: terrain, spacing: terrainSpacing)
            verts = t.vertices
            idx = t.indices
        }
        if let buildings, !buildings.positions.isEmpty {
            let base = UInt32(verts.count)
            verts += buildings.positions
            idx += (0..<UInt32(buildings.positions.count)).map { $0 + base }
        }
        guard !idx.isEmpty else { return nil }
        return RTTriangleMesh(vertices: verts, indices: idx)
    }
}

#endif
