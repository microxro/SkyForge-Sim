// SKYFORGE — Apache-2.0
// CDLOD node meshes (Strugar 2009): each quadtree node is a fixed grid with a geomorph target per vertex and skirts
// that hang below its edges, so neighbours of different LOD meet without cracks. Pure Swift and Metal-free.
// Every node shares one triangle list (`topology`), so the renderer keeps one index buffer for all of them.
import Foundation

/// One node's vertices. The first (quads+1)² entries are the grid, row-major with x fastest, `j * (quads+1) + i`.
/// The last `4 * quads` entries are skirt vertices, one below each boundary vertex in `perimeterIndices` order.
public struct CDLODNodeMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    /// The height each vertex takes at full morph: the parent (next-coarser) surface at the same x and y.
    /// Equal to its own height on the coarse lattice and on the finest level.
    public var morphHeights: [Float]
    public var boundsMin: SIMD3<Float>
    public var boundsMax: SIMD3<Float>
}

public enum CDLODNodeMesher {
    /// Shared triangle list for every node. The layout does not depend on the heights.
    public static func topology(quads: Int) -> [UInt32] {
        precondition(quads >= 2 && quads % 2 == 0, "CDLOD nodes need an even number of quads, at least 2")
        let n = quads + 1
        var idx: [UInt32] = []
        idx.reserveCapacity(quads * quads * 6 + 4 * quads * 6)
        // Top surface: the diagonal runs lower-left to upper-right in every cell, so a coarse cell's diagonal is
        // the one its odd-lattice vertices morph onto.
        for j in 0..<quads {
            for i in 0..<quads {
                let a = UInt32(j * n + i), b = a + 1, c = a + UInt32(n), e = c + 1
                idx += [a, b, e, a, e, c]
            }
        }
        // Skirts: a quad from each boundary segment down to its skirt vertices, facing outwards.
        let perimeter = perimeterIndices(quads: quads)
        let base = n * n
        for k in perimeter.indices {
            let k1 = (k + 1) % perimeter.count
            let a = UInt32(perimeter[k]), b = UInt32(perimeter[k1])
            let sa = UInt32(base + k), sb = UInt32(base + k1)
            idx += [a, sb, b, a, sa, sb]
        }
        return idx
    }

    /// Grid indices of the boundary in counter-clockwise order (bottom, right, top, left), each corner once.
    static func perimeterIndices(quads: Int) -> [Int] {
        let n = quads + 1
        var p: [Int] = []
        p.reserveCapacity(4 * quads)
        for i in 0..<quads { p.append(i) }                                        // bottom: j = 0, x rising
        for j in 0..<quads { p.append(j * n + quads) }                            // right: i = quads, y rising
        for i in stride(from: quads, to: 0, by: -1) { p.append(quads * n + i) }   // top: j = quads, x falling
        for j in stride(from: quads, to: 0, by: -1) { p.append(j * n) }           // left: i = 0, y falling
        return p
    }

    /// A reasonable skirt depth for a node of `size` metres: deep enough to cover a neighbour's crack on a steep edge,
    /// shallow enough that a far node's skirt stays under the terrain it hangs from.
    public static func defaultSkirtDepth(size: Double) -> Double { max(8, 0.05 * size) }

    /// Builds one node over [minX, minX + size] × [minY, minY + size] at level `lod` (0 = finest).
    /// `height` is sampled on the node's own lattice plus one ring outside it (for normals and morph targets).
    /// Morph targets interpolate the parent level's lattice, which has step 2·size/quads: an odd-column vertex takes the
    /// midpoint of its two even neighbours, an odd-row vertex likewise, and an odd-odd vertex the midpoint of the
    /// diagonal, matching the parent's triangles. The finest level has no parent and morphs to itself.
    public static func build(minX: Double, minY: Double, size: Double, lod: Int, quads: Int, skirtDepth: Double,
                             height: (Double, Double) -> Double) -> CDLODNodeMesh {
        precondition(quads >= 2 && quads % 2 == 0, "CDLOD nodes need an even number of quads, at least 2")
        let n = quads + 1, m = n + 2
        let s = size / Double(quads)
        // h(i, j) for lattice indices -1 ... quads + 1, stored with a one-sample border.
        var grid = [Double](repeating: 0, count: m * m)
        for j in 0..<m {
            for i in 0..<m {
                grid[j * m + i] = height(minX + Double(i - 1) * s, minY + Double(j - 1) * s)
            }
        }
        let h = grid
        func H(_ i: Int, _ j: Int) -> Double { h[(j + 1) * m + (i + 1)] }

        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], morph: [Float] = []
        let perimeter = perimeterIndices(quads: quads)
        positions.reserveCapacity(n * n + perimeter.count)
        normals.reserveCapacity(n * n + perimeter.count)
        morph.reserveCapacity(n * n + perimeter.count)
        for j in 0..<n {
            for i in 0..<n {
                let z = H(i, j)
                let dzdx = (H(i + 1, j) - H(i - 1, j)) / (2 * s), dzdy = (H(i, j + 1) - H(i, j - 1)) / (2 * s)
                let up = SIMD3(-dzdx, -dzdy, 1.0)
                let unit = up * (1 / (up * up).sum().squareRoot())
                positions.append(SIMD3(Float(minX + Double(i) * s), Float(minY + Double(j) * s), Float(z)))
                normals.append(SIMD3(Float(unit.x), Float(unit.y), Float(unit.z)))
                let target: Double
                if lod == 0 {
                    target = z
                } else {
                    switch (i % 2 == 0, j % 2 == 0) {
                    case (true, true): target = z
                    case (false, true): target = (H(i - 1, j) + H(i + 1, j)) / 2
                    case (true, false): target = (H(i, j - 1) + H(i, j + 1)) / 2
                    case (false, false): target = (H(i - 1, j - 1) + H(i + 1, j + 1)) / 2
                    }
                }
                morph.append(Float(target))
            }
        }
        let depth = Float(skirtDepth)
        for p in perimeter {
            let top = positions[p]
            positions.append(SIMD3(top.x, top.y, top.z - depth))
            normals.append(normals[p])
            morph.append(morph[p] - depth)
        }
        var lo = positions[0], hi = positions[0]
        for p in positions {
            lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return CDLODNodeMesh(positions: positions, normals: normals, morphHeights: morph, boundsMin: lo, boundsMax: hi)
    }
}
