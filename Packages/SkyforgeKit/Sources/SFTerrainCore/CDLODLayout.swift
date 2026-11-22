// SKYFORGE — Apache-2.0
// Quadtree layout for a CDLOD terrain square. The root is exactly the square, so nodes tile it with no overhang
// beyond the elevation data.
import Foundation

public struct CDLODLayout: Sendable, Equatable {
    /// Quadtree levels: level 0 is the finest leaf, level `levels - 1` is the root.
    public let levels: Int
    /// Side of one finest leaf node (m).
    public let leafSize: Double
    /// Side of the root square (m), the whole terrain square.
    public let rootSize: Double
    /// Grid cells along one node side. Every node has the same grid.
    public let quads: Int

    /// Spacing of the finest grid (m).
    public var finestStep: Double { leafSize / Double(quads) }

    /// The layout for a square of `halfExtent` metres centred on the origin, whose finest grid spacing is as near
    /// `nearStep` as a power-of-two split allows (on a log scale). Nil unless every input is positive and finite.
    public static func covering(halfExtent: Double, nearStep: Double, quads: Int = 64) -> CDLODLayout? {
        guard halfExtent.isFinite, halfExtent > 0, nearStep.isFinite, nearStep > 0, quads >= 2, quads % 2 == 0 else { return nil }
        let root = 2 * halfExtent
        // leaf = root / 2^(levels - 1) and leaf / quads ≈ nearStep. At least two levels, so the root is never a leaf.
        let k = max(1, Int(log2(root / (Double(quads) * nearStep)).rounded()))
        let levels = k + 1
        return CDLODLayout(levels: levels, leafSize: root / pow(2, Double(levels - 1)), rootSize: root, quads: quads)
    }
}
