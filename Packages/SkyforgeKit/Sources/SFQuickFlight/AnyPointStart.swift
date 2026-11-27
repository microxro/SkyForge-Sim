// SKYFORGE — Apache-2.0
// Start geometry for a flight at any latitude and longitude, with no airport needed. This is the
// prerequisite for region follow (M1) and any-point start (M3) in docs/WORLD_STREAMING_PLAN.md.
// It is pure maths: it chooses the region's origin and a runway-free local frame. Terrain and
// imagery are loaded by the region loader, which uses these values.
import Foundation
import SFImagery

public struct AnyPointStart: Sendable, Equatable {
    public enum Error: Swift.Error, Equatable { case latitudeOutOfRange(Double), longitudeOutOfRange(Double) }

    /// Web Mercator tiles stop at this latitude, so every streamed layer is defined up to it.
    public static let maxAbsLatitude = 85.051_128_78

    public let latitude: Double
    public let longitude: Double
    /// The region's local frame is centred here (metres east and north of the origin).
    public let origin: GeoOrigin

    /// Validates a point and normalises its longitude to −180…180. Latitude must lie within the Web Mercator range.
    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, abs(latitude) <= Self.maxAbsLatitude else { throw Error.latitudeOutOfRange(latitude) }
        guard longitude.isFinite else { throw Error.longitudeOutOfRange(longitude) }
        var lon = longitude.truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        self.latitude = latitude
        self.longitude = lon
        self.origin = GeoOrigin(latitude: latitude, longitude: lon)
    }

    /// Local offset (metres east, north) of another point from this start's origin.
    public func localOffset(latitude lat: Double, longitude lon: Double) -> SIMD2<Double> {
        let p = origin.local(latitude: lat, longitude: lon)
        return SIMD2(p.east, p.north)
    }

    /// Straight-line ground distance in metres from this start to another point (flat-earth at these scales).
    public func distance(latitude lat: Double, longitude lon: Double) -> Double {
        let o = localOffset(latitude: lat, longitude: lon)
        return (o * o).sum().squareRoot()
    }
}
