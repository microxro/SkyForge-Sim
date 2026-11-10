// SKYFORGE — Apache-2.0
// Converts a loaded real-world Quick Flight region into GPU-ready render data.
// Pure data mapping (no Metal), so it builds and is testable on every platform.
import SFQuickFlight
import SFImagery
import SFPreview
import SFWorldGen

/// GPU-agnostic description of a real-world region for `WorldRenderer.setRealWorld`.
public struct RealWorldRenderData: Sendable {
    public struct Chunk: Sendable { public var positions: [SIMD3<Float>]; public var normals: [SIMD3<Float>]; public var indices: [UInt32]
        public var boundsMin: SIMD3<Float>; public var boundsMax: SIMD3<Float>
        public init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32], boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) {
            self.positions = positions; self.normals = normals; self.indices = indices; self.boundsMin = boundsMin; self.boundsMax = boundsMax
        }
    }
    public struct Tree: Sendable { public var position: SIMD3<Float>; public var height: Float; public var conifer: Bool; public var colour: SIMD3<Float>
        public init(position: SIMD3<Float>, height: Float, conifer: Bool, colour: SIMD3<Float>) {
            self.position = position; self.height = height; self.conifer = conifer; self.colour = colour
        }
    }
    public struct Imagery: Sendable { public var centre: SIMD2<Double>; public var halfExtent: Double; public var size: Int; public var rgb: [UInt8]
        public init(centre: SIMD2<Double>, halfExtent: Double, size: Int, rgb: [UInt8]) { self.centre = centre; self.halfExtent = halfExtent; self.size = size; self.rgb = rgb }
    }
    public var chunks: [Chunk]
    public var trees: [Tree]
    public var near: Imagery?
    public var far: Imagery?
    /// Sharp inner imagery square (US aerial photo along the approach), feathered into `near`.
    public var detail: Imagery?
    public var waterMask: (size: Int, values: [Float])?
    /// Where the 3D trees stand, for removing the photo's own trees and shadows from imagery streamed later
    /// (the in-flight detail layer), as `init(region:)` does for the near and detail layers.
    public var photoCrowns: [ImageryDelighting.Crown] = []
    /// OpenStreetMap buildings and roads (local metres), drawn with the world mesh pass.
    public var buildings: TriangleSoup?
    public init(chunks: [Chunk], trees: [Tree], near: Imagery?, far: Imagery?, waterMask: (size: Int, values: [Float])?) {
        self.chunks = chunks; self.trees = trees; self.near = near; self.far = far; self.waterMask = waterMask
    }
}

extension RealWorldRenderData {
    /// Procedural (SkyWorld) trees for the instanced tree pass.
    public static func trees(_ list: [SFWorldGen.Tree]) -> [Tree] {
        list.map { Tree(position: SIMD3(Float($0.position.x), Float($0.position.y), Float($0.position.z)), height: Float($0.height),
                        conifer: $0.conifer, colour: $0.colour) }
    }

    /// Terrain chunks, trees, near/far orthoimagery and the smoothed water mask for `region`.
    public init(region: RealWorldRegion, chunkQuads: Int = 48) {
        let chunks = region.terrainChunks(quads: chunkQuads).map {
            Chunk(positions: $0.positions, normals: $0.normals, indices: $0.indices, boundsMin: $0.boundsMin, boundsMax: $0.boundsMax)
        }
        let placed = region.trees()
        let trees = placed.map { Tree(position: $0.position, height: $0.height, conifer: $0.conifer, colour: $0.colour) }
        func imagery(_ m: ImageryMosaic?) -> Imagery? {
            m.map { Imagery(centre: $0.centre, halfExtent: $0.halfExtent, size: $0.size, rgb: $0.rgb) }
        }
        let g = region.ground
        // The photo's trees and shadows under the 3D trees are filled from the ground around them (structural
        // change after art rounds 18–19). The far layer (10 m Sentinel-2, beyond the trees) is left as is.
        let crowns = RealWorldRegion.photoCrowns(placed)
        var near = g.near, det = g.detail
        ImageryDelighting.removePhotoTrees(&near, crowns: crowns) { x, y in g.water(x, y) ?? 0 }
        if det != nil { ImageryDelighting.removePhotoTrees(&det!, crowns: crowns) { x, y in g.water(x, y) ?? 0 } }
        self.init(chunks: chunks, trees: trees, near: imagery(near), far: imagery(g.far),
                  waterMask: (g.maskSize, g.waterMask))
        detail = imagery(det)
        photoCrowns = crowns
        buildings = region.osmMesh()
    }
}
