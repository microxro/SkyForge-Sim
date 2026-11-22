// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFTerrainCore

@Suite struct CDLODNodeMeshTests {
    /// A smooth, non-planar surface with relief on several scales.
    static func surface(_ x: Double, _ y: Double) -> Double {
        40 * sin(x / 310) * cos(y / 270) + 18 * sin((x + y) / 97) + 0.02 * x
    }

    @Test func topologyOnlyIndexesItsVertices() {
        let quads = 8
        let idx = CDLODNodeMesher.topology(quads: quads)
        let vertexCount = (quads + 1) * (quads + 1) + 4 * quads
        #expect(idx.count == quads * quads * 6 + 4 * quads * 6)
        #expect(idx.count % 3 == 0)
        #expect(idx.allSatisfy { Int($0) < vertexCount })
    }

    @Test func perimeterIsCounterClockwiseAndCoversTheEdge() {
        let quads = 4, n = quads + 1
        let p = CDLODNodeMesher.perimeterIndices(quads: quads)
        #expect(p.count == 4 * quads)
        #expect(Set(p).count == p.count, "each boundary vertex once")
        // Shoelace area of the boundary polygon in lattice units: positive means counter-clockwise.
        var area = 0
        for k in p.indices {
            let a = p[k], b = p[(k + 1) % p.count]
            area += (a % n) * (b / n) - (b % n) * (a / n)
        }
        #expect(area > 0)
    }

    @Test func gridAndSkirtCountsMatchTheTopology() {
        let mesh = CDLODNodeMesher.build(minX: 0, minY: 0, size: 1_024, lod: 1, quads: 8, skirtDepth: 20, height: Self.surface)
        #expect(mesh.positions.count == 81 + 32)
        #expect(mesh.normals.count == mesh.positions.count)
        #expect(mesh.morphHeights.count == mesh.positions.count)
    }

    @Test func evenVerticesSitOnTheCoarseLatticeAndMorphToThemselves() {
        let quads = 8
        let mesh = CDLODNodeMesher.build(minX: 0, minY: 0, size: 1_024, lod: 1, quads: quads, skirtDepth: 20, height: Self.surface)
        let n = quads + 1
        for j in stride(from: 0, through: quads, by: 2) {
            for i in stride(from: 0, through: quads, by: 2) {
                let k = j * n + i
                #expect(abs(mesh.morphHeights[k] - mesh.positions[k].z) < 1e-4, "vertex (\(i), \(j))")
            }
        }
    }

    @Test func finestLevelMorphsToItself() {
        let quads = 8
        let mesh = CDLODNodeMesher.build(minX: 0, minY: 0, size: 512, lod: 0, quads: quads, skirtDepth: 20, height: Self.surface)
        for k in 0..<((quads + 1) * (quads + 1)) {
            #expect(mesh.morphHeights[k] == mesh.positions[k].z)
        }
    }

    /// Every vertex's morph target lies on the parent surface: the parent triangles of the coarse cell that contains it,
    /// which have their diagonal from the cell's lower-left to its upper-right corner.
    @Test func oddVerticesMorphOntoTheParentSurface() {
        let quads = 8, size = 1_024.0
        let s = size / Double(quads)
        let mesh = CDLODNodeMesher.build(minX: 0, minY: 0, size: size, lod: 1, quads: quads, skirtDepth: 20, height: Self.surface)
        let n = quads + 1
        for j in 0..<n {
            for i in 0..<n where i % 2 == 1 || j % 2 == 1 {
                // Coarse cell [ci, ci+2] × [cj, cj+2] in fine steps; at the far edge the cell is pulled back one step.
                let ci = min(i - i % 2, quads - 2), cj = min(j - j % 2, quads - 2)
                let u = Double(i - ci), v = Double(j - cj)
                func corner(_ a: Int, _ b: Int) -> Double { Self.surface(Double(ci + a) * s, Double(cj + b) * s) }
                let expected: Double
                if v <= u {
                    let c = v / 2, b = (u - v) / 2, a = 1 - b - c
                    expected = a * corner(0, 0) + b * corner(2, 0) + c * corner(2, 2)
                } else {
                    let b = u / 2, c = (v - u) / 2, a = 1 - b - c
                    expected = a * corner(0, 0) + b * corner(2, 2) + c * corner(0, 2)
                }
                let k = j * n + i
                #expect(abs(Double(mesh.morphHeights[k]) - expected) < 1e-3, "vertex (\(i), \(j))")
            }
        }
    }

    @Test func skirtsHangStraightBelowTheirBoundaryVertices() {
        let quads = 8, depth = 20.0
        let mesh = CDLODNodeMesher.build(minX: 0, minY: 0, size: 1_024, lod: 0, quads: quads, skirtDepth: depth, height: Self.surface)
        let n = quads + 1
        for (k, p) in CDLODNodeMesher.perimeterIndices(quads: quads).enumerated() {
            let top = mesh.positions[p], skirt = mesh.positions[n * n + k]
            #expect(abs(skirt.x - top.x) < 1e-3 && abs(skirt.y - top.y) < 1e-3)
            #expect(abs((top.z - skirt.z) - Float(depth)) < 1e-3)
        }
        let zs = mesh.positions.map(\.z)
        #expect(mesh.boundsMin.z <= zs.min() ?? 0)
        #expect(mesh.boundsMax.z >= zs.max() ?? 0)
    }

    @Test func normalsPointUpwards() {
        let quads = 8
        let mesh = CDLODNodeMesher.build(minX: 0, minY: 0, size: 1_024, lod: 0, quads: quads, skirtDepth: 20, height: Self.surface)
        for k in 0..<((quads + 1) * (quads + 1)) {
            #expect(mesh.normals[k].z > 0)
        }
    }
}
