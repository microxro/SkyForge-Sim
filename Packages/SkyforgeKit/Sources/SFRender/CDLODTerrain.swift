// SKYFORGE — Apache-2.0
// Real-terrain CDLOD for the renderer. Each frame the quadtree picks the nodes for the camera. A node's mesh is built
// from the region's height field the first time it is needed and kept in GPU buffers. Vertices morph in the shader.
import Metal
import SFQuickFlight
import SFTerrainCore

final class CDLODTerrain {
    /// One node's GPU vertices, its morph heights, and the bounds used for culling (region-local metres).
    struct Node {
        let vertices: MTLBuffer
        let morph: MTLBuffer
        let boundsMin: SIMD3<Float>
        let boundsMax: SIMD3<Float>
    }

    /// A node chosen for this frame, with the camera distances (m) over which its vertices morph to the parent level.
    struct Draw {
        let node: Node
        let morphStart: Float
        let morphEnd: Float
    }

    /// The triangle list every node shares.
    let indices: MTLBuffer
    let indexCount: Int

    private struct Key: Hashable { let lod: Int; let x: Int; let y: Int }
    /// Node meshes kept on the GPU. The cache is dropped whole past this size; a node rebuilds in well under a millisecond.
    private static let cacheLimit = 1_500

    private let device: MTLDevice
    private let field: TerrainHeightField
    private let layout: CDLODLayout
    /// Quadtree for the current error scale. Rebuilt when the quality governor changes the scale.
    private var tree: CDLODQuadtree
    private var treeScale: Double = 1
    /// Finest-level distance (m) at full quality; the morph bands follow it.
    private let baseFinestRange: Double
    private let bounds: ConstantBounds
    private var cache: [Key: Node] = [:]

    init(device: MTLDevice, field: TerrainHeightField, layout: CDLODLayout, finestRange: Double) throws {
        self.device = device
        self.field = field
        self.layout = layout
        baseFinestRange = finestRange
        let range = field.elevationRange
        bounds = ConstantBounds(low: range.low, high: range.high)
        tree = Self.makeTree(layout: layout, finestRange: finestRange)
        let idx = CDLODNodeMesher.topology(quads: layout.quads)
        indices = try Self.makeBuffer(idx, device: device)
        indexCount = idx.count
    }

    /// The nodes that tile the terrain square for `camera` (camera-space metres, region-local origin), with their morph bands.
    /// `sseScale` is the quality governor's terrain error scale (1 = full quality, larger = coarser): the level distances
    /// and morph bands shrink by it, so the same nodes are used nearer the camera.
    func draws(camera: SIMD3<Double>, sseScale: Double) -> [Draw] {
        let scale = sseScale.isFinite && sseScale > 0 ? sseScale : 1
        if scale != treeScale {
            tree = Self.makeTree(layout: layout, finestRange: baseFinestRange / scale)
            treeScale = scale
        }
        let selected = tree.select(camera: camera, bounds: bounds)
        var out: [Draw] = []
        out.reserveCapacity(selected.count)
        for n in selected {
            // Node origins are whole multiples of the leaf size, so rounding gives an exact key.
            let key = Key(lod: n.lod, x: Int((n.minX / layout.leafSize).rounded()), y: Int((n.minY / layout.leafSize).rounded()))
            let node = cache[key] ?? build(n, key: key)
            guard let node else { continue }
            out.append(Draw(node: node, morphStart: Float(n.morphStart), morphEnd: Float(n.morphEnd)))
        }
        return out
    }

    private func build(_ n: CDLODNode, key: Key) -> Node? {
        let f = field
        let mesh = CDLODNodeMesher.build(minX: n.minX, minY: n.minY, size: n.size, lod: n.lod, quads: layout.quads,
                                         skirtDepth: CDLODNodeMesher.defaultSkirtDepth(size: n.size)) { f.height($0, $1) }
        var verts: [PackedTerrainVertex] = []
        verts.reserveCapacity(mesh.positions.count)
        for (p, nrm) in zip(mesh.positions, mesh.normals) {
            verts.append(PackedTerrainVertex(px: p.x, py: p.y, pz: p.z, nx: Self.snorm(nrm.x), ny: Self.snorm(nrm.y),
                                             nz: Self.snorm(nrm.z), nw: 127))
        }
        guard let vb = try? Self.makeBuffer(verts, device: device),
              let mb = try? Self.makeBuffer(mesh.morphHeights, device: device) else { return nil }
        let node = Node(vertices: vb, morph: mb, boundsMin: mesh.boundsMin, boundsMax: mesh.boundsMax)
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = node
        return node
    }

    private static func makeTree(layout: CDLODLayout, finestRange: Double) -> CDLODQuadtree {
        CDLODQuadtree(rootMinX: -layout.rootSize / 2, rootMinY: -layout.rootSize / 2, rootSize: layout.rootSize,
                      settings: CDLODSettings(levels: layout.levels, finestRange: finestRange))
    }

    private static func snorm(_ x: Float) -> Int8 { Int8(max(-127, min(127, (x * 127).rounded()))) }

    private static func makeBuffer<T>(_ a: [T], device: MTLDevice) throws -> MTLBuffer {
        guard let b = a.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw RendererError.commandQueue
        }
        return b
    }
}
