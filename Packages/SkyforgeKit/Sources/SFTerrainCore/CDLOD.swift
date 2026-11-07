// SKYFORGE — Apache-2.0
// Continuous Distance-Dependent LOD quadtree selection (F. Strugar, 2009).
// Works on a square local domain in metres (x east, y north, z up).
import Foundation
import SFMath

/// Provides elevation bounds for quadtree nodes (min/max over an area).
public protocol HeightBoundsProvider: Sendable {
    func heightBounds(minX: Double, minY: Double, size: Double) -> (min: Double, max: Double)
}

public struct ConstantBounds: HeightBoundsProvider {
    public var low: Double, high: Double
    public init(low: Double, high: Double) { self.low = low; self.high = high }
    public func heightBounds(minX: Double, minY: Double, size: Double) -> (min: Double, max: Double) { (low, high) }
}

public struct CDLODNode: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var size: Double
    /// 0 = finest level.
    public var lod: Int
    /// Distance range over which vertices morph toward the next coarser grid.
    public var morphStart: Double
    public var morphEnd: Double
}

public struct CDLODSettings: Sendable {
    /// Number of LOD levels (leaf size = rootSize / 2^(levels-1)).
    public var levels: Int
    /// Visibility range of the finest level (metres); each level doubles it.
    public var finestRange: Double
    /// Fraction of each range used for morphing (Strugar uses ~0.3).
    public var morphFraction: Double
    public init(levels: Int = 10, finestRange: Double = 200, morphFraction: Double = 0.3) {
        self.levels = levels; self.finestRange = finestRange; self.morphFraction = morphFraction
    }
}

public struct CDLODQuadtree: Sendable {
    public let rootMinX: Double
    public let rootMinY: Double
    public let rootSize: Double
    public let settings: CDLODSettings
    public let ranges: [Double]

    public init(rootMinX: Double, rootMinY: Double, rootSize: Double, settings: CDLODSettings = CDLODSettings()) {
        self.rootMinX = rootMinX; self.rootMinY = rootMinY; self.rootSize = rootSize; self.settings = settings
        // Neighbouring nodes can only differ by one LOD if each level's range comfortably exceeds
        // its node size; enforce finest range >= 2.5 x leaf size (Strugar 2009, sec. 2.3).
        let leaf = rootSize / pow(2, Double(settings.levels - 1))
        let finest = max(settings.finestRange, 2.5 * leaf)
        ranges = (0..<settings.levels).map { finest * pow(2, Double($0)) }
    }

    /// Selects nodes for a camera position; result tiles the root square exactly (no gaps, no overlap)
    /// within the coarsest range.
    public func select(camera: SIMD3<Double>, bounds: any HeightBoundsProvider) -> [CDLODNode] {
        var out: [CDLODNode] = []
        _ = selectNode(minX: rootMinX, minY: rootMinY, size: rootSize, lod: settings.levels - 1,
                       camera: camera, bounds: bounds, out: &out)
        return out
    }

    func morphRange(_ lod: Int) -> (Double, Double) {
        let end = ranges[lod]
        let prev = lod > 0 ? ranges[lod - 1] : 0
        return (end - (end - prev) * settings.morphFraction, end)
    }

    func add(_ minX: Double, _ minY: Double, _ size: Double, _ lod: Int, _ out: inout [CDLODNode]) {
        let (ms, me) = morphRange(lod)
        out.append(CDLODNode(minX: minX, minY: minY, size: size, lod: lod, morphStart: ms, morphEnd: me))
    }

    static func distanceToBox(_ p: SIMD3<Double>, minX: Double, minY: Double, size: Double, zMin: Double, zMax: Double) -> Double {
        let dx = max(minX - p.x, 0, p.x - (minX + size))
        let dy = max(minY - p.y, 0, p.y - (minY + size))
        let dz = max(zMin - p.z, 0, p.z - zMax)
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    /// Returns false if the node is outside its LOD range (the caller then covers the area itself).
    func selectNode(minX: Double, minY: Double, size: Double, lod: Int, camera: SIMD3<Double>,
                    bounds: any HeightBoundsProvider, out: inout [CDLODNode]) -> Bool {
        let hb = bounds.heightBounds(minX: minX, minY: minY, size: size)
        let d = Self.distanceToBox(camera, minX: minX, minY: minY, size: size, zMin: hb.min, zMax: hb.max)
        if d > ranges[lod] && lod != settings.levels - 1 { return false }
        if lod == 0 {
            add(minX, minY, size, lod, &out)
            return true
        }
        if d > ranges[lod - 1] {
            add(minX, minY, size, lod, &out)
            return true
        }
        let h = size / 2
        for (cx, cy) in [(minX, minY), (minX + h, minY), (minX, minY + h), (minX + h, minY + h)] {
            if !selectNode(minX: cx, minY: cy, size: h, lod: lod - 1, camera: camera, bounds: bounds, out: &out) {
                add(cx, cy, h, lod, &out)
            }
        }
        return true
    }
}

/// Geomorph factor for a vertex at `distance` within a node's morph range (0 = full detail, 1 = coarse).
@inlinable public func cdlodMorph(distance: Double, node: CDLODNode) -> Double {
    clamp((distance - node.morphStart) / max(node.morphEnd - node.morphStart, 1e-9), 0, 1)
}
