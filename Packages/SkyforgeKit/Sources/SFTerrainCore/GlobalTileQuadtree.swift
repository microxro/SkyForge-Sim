// SKYFORGE — Apache-2.0
import Foundation

/// Web Mercator (XYZ) tile address, the scheme used by Terrarium elevation and slippy-map imagery.
public struct GlobalTileID: Hashable, Sendable, CustomStringConvertible {
    public static let maxZoom = 22
    /// Web Mercator latitude limit in degrees.
    public static let mercatorLatitudeLimit = 85.05112878

    public let zoom: Int
    public let x: Int
    public let y: Int

    /// Returns nil when the zoom or indices are outside the valid range for that zoom.
    public init?(zoom: Int, x: Int, y: Int) {
        guard zoom >= 0, zoom <= Self.maxZoom else { return nil }
        let n = 1 << zoom
        guard x >= 0, x < n, y >= 0, y < n else { return nil }
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    /// The tile containing a WGS84 coordinate. Latitude is clamped to the Mercator limit; longitude wraps.
    public static func containing(latitude: Double, longitude: Double, zoom: Int) -> GlobalTileID {
        let z = max(0, min(maxZoom, zoom))
        let n = 1 << z
        let lat = max(-mercatorLatitudeLimit, min(mercatorLatitudeLimit, latitude))
        let latRad = lat * .pi / 180
        let fx = (longitude + 180) / 360 * Double(n)
        let fy = (1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * Double(n)
        let x = ((Int(floor(fx)) % n) + n) % n
        let y = max(0, min(n - 1, Int(floor(fy))))
        return GlobalTileID(zoom: z, x: x, y: y)!
    }

    public var description: String { "\(zoom)/\(x)/\(y)" }

    public var westLongitude: Double { Double(x) / Double(1 << zoom) * 360 - 180 }
    public var eastLongitude: Double { Double(x + 1) / Double(1 << zoom) * 360 - 180 }
    public var northLatitude: Double { Self.latitude(mercatorFraction: Double(y) / Double(1 << zoom)) }
    public var southLatitude: Double { Self.latitude(mercatorFraction: Double(y + 1) / Double(1 << zoom)) }

    /// Approximate east-west side length in metres at the tile's centre latitude.
    public var widthMeters: Double {
        let centre = (northLatitude + southLatitude) / 2
        return 40_075_016.686 * cos(centre * .pi / 180) / Double(1 << zoom)
    }

    /// The four tiles one zoom level finer that together cover this tile. Empty at `maxZoom`.
    public var children: [GlobalTileID] {
        guard zoom < Self.maxZoom else { return [] }
        let z = zoom + 1
        return [(0, 0), (1, 0), (0, 1), (1, 1)].map { offset in
            GlobalTileID(zoom: z, x: x * 2 + offset.0, y: y * 2 + offset.1)!
        }
    }

    /// Relative cache path such as `s2c2016/10/284/435.jpg`. Returns nil when the source or extension
    /// contains anything other than letters, digits, `-` or `_`, so a source name can never escape the cache root.
    public func cachePath(source: String, fileExtension: String) -> String? {
        guard Self.isSafeComponent(source), Self.isSafeComponent(fileExtension) else { return nil }
        return "\(source)/\(zoom)/\(x)/\(y).\(fileExtension)"
    }

    static func latitude(mercatorFraction f: Double) -> Double {
        let n = Double.pi * (1 - 2 * f)
        return 180 / Double.pi * atan(sinh(n))
    }

    static func isSafeComponent(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "_"
        }
    }
}

/// Chooses which global tiles to stream around a camera. Tiles near the camera are finer; far tiles are coarser.
public enum GlobalTileQuadtree {
    /// Refines a tile while its width exceeds the camera's distance to it or its altitude, down to `maxZoom`.
    /// Stops refining once `maxTiles` would be exceeded, so the output is always bounded.
    /// - Parameters:
    ///   - radiusMeters: ground radius to cover around the camera's position.
    ///   - minZoom: coarsest level used, which also sets the root tiles.
    /// - Returns: unique tiles that together cover the disc, deduplicated, ordered coarse to fine.
    public static func select(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        radiusMeters: Double,
        minZoom: Int,
        maxZoom: Int,
        maxTiles: Int
    ) -> [GlobalTileID] {
        guard latitude.isFinite, longitude.isFinite, altitudeMeters.isFinite, radiusMeters.isFinite,
              radiusMeters > 0, maxTiles > 0 else { return [] }
        let lo = max(0, min(minZoom, GlobalTileID.maxZoom))
        let hi = max(lo, min(maxZoom, GlobalTileID.maxZoom))
        let lat = max(-GlobalTileID.mercatorLatitudeLimit, min(GlobalTileID.mercatorLatitudeLimit, latitude))
        let lon = wrapLongitude(longitude)
        let alt = max(0, altitudeMeters)

        let root = GlobalTileID.containing(latitude: lat, longitude: lon, zoom: lo)
        let n = 1 << lo
        // Clamped to the tile count at this level: beyond it every wrapped tile is already visited, and an
        // unbounded Double here would trap on Int conversion for a huge radius.
        let span = Int(min(ceil(radiusMeters / root.widthMeters) + 1, Double(n)))

        var stack: [GlobalTileID] = []
        var seenRoots = Set<GlobalTileID>()
        for dy in -span...span {
            let ty = root.y + dy
            guard ty >= 0, ty < n else { continue }
            for dx in -span...span {
                let tx = ((root.x + dx) % n + n) % n
                if let t = GlobalTileID(zoom: lo, x: tx, y: ty), seenRoots.insert(t).inserted {
                    stack.append(t)
                }
            }
        }
        // Keep only roots that actually touch the disc.
        stack = stack.filter { distanceMeters(from: lat, lon, to: $0) <= radiusMeters }

        var out: [GlobalTileID] = []
        var seen = Set<GlobalTileID>()
        while let tile = stack.popLast() {
            let d = distanceMeters(from: lat, lon, to: tile)
            let wantFiner = tile.zoom < hi && tile.widthMeters > max(d, alt)
            let room = out.count + stack.count + 4 <= maxTiles
            if wantFiner, room {
                for child in tile.children where distanceMeters(from: lat, lon, to: child) <= radiusMeters {
                    stack.append(child)
                }
            } else if seen.insert(tile).inserted {
                out.append(tile)
            }
        }
        return out
    }

    /// Approximate ground distance in metres from a point to the nearest edge or inside of a tile.
    static func distanceMeters(from lat: Double, _ lon: Double, to tile: GlobalTileID) -> Double {
        let nearLat = max(tile.southLatitude, min(tile.northLatitude, lat))
        var best = Double.infinity
        for shift in [-360.0, 0, 360.0] {
            let l = lon + shift
            let nearLon = max(tile.westLongitude, min(tile.eastLongitude, l))
            let dy = (nearLat - lat) * 110_574
            let dx = (nearLon - l) * 111_320 * cos(lat * .pi / 180)
            best = min(best, (dx * dx + dy * dy).squareRoot())
        }
        return best
    }

    static func wrapLongitude(_ lon: Double) -> Double {
        let w = (lon + 180).truncatingRemainder(dividingBy: 360)
        return (w < 0 ? w + 360 : w) - 180
    }
}
