// SKYFORGE — Apache-2.0
// The region's ground height as a value: the near, mid and far elevation mosaics blended, with the runway held flat.
// Sendable, so the renderer's terrain LOD samples the same surface the trees and buildings stand on.
import Foundation
import SFImagery

public struct TerrainHeightField: Sendable {
    public let near: HeightMosaic
    public let far: HeightMosaic
    public let mid: HeightMosaic?
    public let runwayThreshold: SIMD2<Double>
    public let runwayDirection: SIMD2<Double>
    public let runwayLengthMetres: Double
    public let runwayWidthMetres: Double
    public let runwayElevation: Double

    public init(near: HeightMosaic, far: HeightMosaic, mid: HeightMosaic?, runwayThreshold: SIMD2<Double>,
                runwayDirection: SIMD2<Double>, runwayLengthMetres: Double, runwayWidthMetres: Double, runwayElevation: Double) {
        self.near = near; self.far = far; self.mid = mid
        self.runwayThreshold = runwayThreshold; self.runwayDirection = runwayDirection
        self.runwayLengthMetres = runwayLengthMetres; self.runwayWidthMetres = runwayWidthMetres
        self.runwayElevation = runwayElevation
    }

    /// Height outside the near square: the mid mosaic, blended into the far one over its outer 15 %.
    func outerHeight(_ x: Double, _ y: Double) -> Double {
        guard let mid else { return far.height(x, y) }
        let ex = mid.halfExtent - max(abs(x - mid.centre.x), abs(y - mid.centre.y))
        if ex <= 0 { return far.height(x, y) }
        let band = 0.15 * mid.halfExtent
        if ex >= band { return mid.height(x, y) }
        let t = ex / band, w = t * t * (3 - 2 * t)
        let f = far.height(x, y)
        return f + (mid.height(x, y) - f) * w
    }

    public func height(_ x: Double, _ y: Double) -> Double {
        // Runways are flat: hold the published elevation over the paved area and blend 60 m out.
        let d = SIMD2(x, y) - runwayThreshold
        let along = (d * runwayDirection).sum()
        let across = abs(d.x * runwayDirection.y - d.y * runwayDirection.x)
        let over = max(max(-along, along - runwayLengthMetres), across - runwayWidthMetres)
        // Near (z14) heights blend into the far (z10) mosaic over the outer 15 % of the near square, so
        // there is no cliff where the two elevation models disagree (mountains: tens of metres).
        let ex = near.halfExtent - max(abs(x - near.centre.x), abs(y - near.centre.y))
        let blendWidth = 0.15 * near.halfExtent
        let natural: Double
        if ex <= 0 {
            natural = max(0, outerHeight(x, y))
        } else if ex >= blendWidth {
            natural = max(0, near.height(x, y))
        } else {
            let t = ex / blendWidth, w = t * t * (3 - 2 * t)
            let o = outerHeight(x, y)
            natural = max(0, o + (near.height(x, y) - o) * w)
        }
        if over <= 0 { return runwayElevation }
        let t = min(1, over / 60)
        return runwayElevation + (natural - runwayElevation) * (t * t * (3 - 2 * t))
    }

    /// Lowest and highest mosaic sample (m), widened by 5 m for the runway and the blends.
    public var elevationRange: (low: Double, high: Double) {
        var mosaics = [near, far]
        if let mid { mosaics.append(mid) }
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for m in mosaics {
            for h in m.heights where h.isFinite {
                lo = min(lo, Double(h)); hi = max(hi, Double(h))
            }
        }
        guard lo <= hi else { return (low: runwayElevation - 5, high: runwayElevation + 5) }
        return (low: min(lo, runwayElevation) - 5, high: max(hi, runwayElevation) + 5)
    }
}
