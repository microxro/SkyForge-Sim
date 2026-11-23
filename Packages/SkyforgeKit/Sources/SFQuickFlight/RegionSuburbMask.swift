// SKYFORGE — Apache-2.0
// Region glue for the Round 2 suburban parcel mask: the bundled land-use polygons, rasterised with the region's
// frontage roads over the near imagery extent (the grid the shader samples with `nuv`).
import Foundation

public struct SuburbMaskRaster: Sendable, Equatable {
    public var size: Int
    public var centre: SIMD2<Double>
    public var halfExtent: Double
    /// RGBA8, row 0 north (layout in `SuburbMask`).
    public var texels: [UInt8]
}

extension RealWorldRegion {
    /// The suburb mask over the near imagery extent; nil without bundled land use or roads.
    /// Data © OpenStreetMap contributors, ODbL 1.0 (`LandUsePack.attribution`).
    public func suburbMask(size: Int = 2_048) -> SuburbMaskRaster? {
        guard !landUse.isEmpty, let roads = osm?.roads, !roads.isEmpty else { return nil }
        let m = ground.near
        guard size > 1, m.halfExtent > 0, m.halfExtent.isFinite else { return nil }
        let texels = SuburbMask.build(size: size, centre: m.centre, halfExtent: m.halfExtent, landUse: landUse, roads: roads)
        // Nothing residential in range: skip the upload.
        var any = false
        var i = 0
        while i < texels.count { if texels[i] != 0 { any = true; break }; i += 4 }
        return any ? SuburbMaskRaster(size: size, centre: m.centre, halfExtent: m.halfExtent, texels: texels) : nil
    }
}
