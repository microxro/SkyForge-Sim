// SKYFORGE — Apache-2.0
// Addressing for the ESA WorldCover 10 m grid (3°×3° tiles, named by their south-west corner, e.g. N36W123).
// Pure Swift so the streaming planner and its tests run on Linux. Data: docs/WORLD_SCENERY.md.
import Foundation

public struct WorldCoverTileKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let span = 3
    /// WorldCover publishes tiles from 60°S to 84°N; keys outside that range are not valid.
    public static let southLatRange = -60...81
    public static let westLonRange = -180...177

    /// South edge in whole degrees, a multiple of `span`.
    public let southLat: Int
    /// West edge in whole degrees, a multiple of `span`.
    public let westLon: Int

    public init?(southLat: Int, westLon: Int) {
        guard southLat % Self.span == 0, westLon % Self.span == 0,
              Self.southLatRange.contains(southLat), Self.westLonRange.contains(westLon) else { return nil }
        self.southLat = southLat
        self.westLon = westLon
    }

    /// The tile that contains a coordinate. Longitude wraps into [-180, 180). Nil outside the published range.
    public static func containing(latitude: Double, longitude: Double) -> WorldCoverTileKey? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        var lon = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        lon -= 180
        return WorldCoverTileKey(southLat: floorToSpan(latitude), westLon: floorToSpan(lon))
    }

    /// Tiles whose box overlaps a square of `radiusMeters` around a point (a conservative bounding box).
    /// Sorted, without duplicates, and wrapped across the antimeridian.
    public static func covering(latitude: Double, longitude: Double, radiusMeters: Double) -> [WorldCoverTileKey] {
        guard latitude.isFinite, longitude.isFinite, radiusMeters.isFinite, radiusMeters >= 0 else { return [] }
        let metersPerDegree = 111_320.0
        let dLat = radiusMeters / metersPerDegree
        let cosLat = cos(latitude * .pi / 180)
        let dLon = cosLat > 1e-6 ? min(180, radiusMeters / (metersPerDegree * cosLat)) : 180

        var keys = Set<WorldCoverTileKey>()
        let southMin = floorToSpan(max(-90, latitude - dLat))
        let northMax = floorToSpan(min(89.999, latitude + dLat))
        let westMin = floorToSpan(longitude - dLon)
        let eastMax = floorToSpan(longitude + dLon)
        var s = southMin
        while s <= northMax {
            var w = westMin
            while w <= eastMax {
                if let key = WorldCoverTileKey(southLat: s, westLon: wrapLon(w)) { keys.insert(key) }
                w += span
            }
            s += span
        }
        return keys.sorted()
    }

    /// File-name stem used by the bucket, e.g. `N36W123`.
    public var name: String {
        let ns = southLat < 0 ? "S" : "N"
        let ew = westLon < 0 ? "W" : "E"
        let lat = String(abs(southLat))
        let lon = String(abs(westLon))
        return ns + String(repeating: "0", count: max(0, 2 - lat.count)) + lat
            + ew + String(repeating: "0", count: max(0, 3 - lon.count)) + lon
    }

    /// Object key in the public `esa-worldcover` bucket (v200, 2021 map).
    public var objectKey: String {
        "v200/2021/map/ESA_WorldCover_10m_2021_v200_\(name)_Map.tif"
    }

    public static func < (a: WorldCoverTileKey, b: WorldCoverTileKey) -> Bool {
        (a.southLat, a.westLon) < (b.southLat, b.westLon)
    }

    public var description: String { name }

    private static func floorToSpan(_ degrees: Double) -> Int {
        Int((degrees / Double(span)).rounded(.down)) * span
    }

    /// Wraps a whole-degree west edge into [-180, 177]; the wrap is exact because 360 is a multiple of `span`.
    private static func wrapLon(_ w: Int) -> Int {
        var v = (w + 180) % 360
        if v < 0 { v += 360 }
        return v - 180
    }
}
