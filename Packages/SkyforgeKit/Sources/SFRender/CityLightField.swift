// SKYFORGE — Apache-2.0
// City light carpets: maps land-use zones (region metres) to a density per 400 m cell and emits street and
// window lights for the cells nearest the camera, within a per-frame light budget. Pure Swift (Linux-testable).
import Foundation
import SFMath

/// One land-use zone for the city lights: a density (see `CityLights.density`) over a closed ring in region metres.
public struct CityLightZone: Sendable {
    public var density: Float
    public var ring: [SIMD2<Float>]
    public init(density: Float, ring: [SIMD2<Float>]) { self.density = density; self.ring = ring }
}

public final class CityLightField {
    private struct Key: Hashable { let x: Int; let y: Int }
    private let zones: [CityLightZone]
    private var densityCache: [Key: Float] = [:]
    /// Cells cached before the cache is cleared (keeps memory bounded as the camera flies far).
    private static let cacheLimit = 4_096

    public init(zones: [CityLightZone]) {
        self.zones = zones.filter { $0.density > 0.03 && $0.ring.count >= 3 }
    }

    public var isEmpty: Bool { zones.isEmpty }

    /// Density at a cell's centre: the densest zone containing it (0 when no zone does).
    public func density(of cell: CityLights.Cell, size: Float = 400) -> Float {
        let key = Key(x: cell.x, y: cell.y)
        if let d = densityCache[key] { return d }
        let p = SIMD2<Float>((Float(cell.x) + 0.5) * size, (Float(cell.y) + 0.5) * size)
        var best: Float = 0
        for z in zones where z.density > best && CityLightField.contains(p, ring: z.ring) { best = z.density }
        if densityCache.count >= Self.cacheLimit { densityCache.removeAll(keepingCapacity: true) }
        densityCache[key] = best
        return best
    }

    /// Lights for the cells nearest `camera` (region metres), nearest first, stopping at `maxLights`.
    public func lights(camera: SIMD2<Float>, tier: NightTier, maxLights: Int, size: Float = 400) -> [NightLight] {
        guard maxLights > 0, !zones.isEmpty else { return [] }
        var out: [NightLight] = []
        for cell in CityLights.visibleCells(camera: camera, size: size, tier: tier) {
            let room = maxLights - out.count
            if room <= 0 { break }
            let d = density(of: cell, size: size)
            guard d > 0 else { continue }
            out.append(contentsOf: CityLights.lights(cell: cell, size: size, density: d, budget: min(room, 120)))
        }
        return out
    }

    /// Even-odd point-in-polygon test.
    static func contains(_ p: SIMD2<Float>, ring: [SIMD2<Float>]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
