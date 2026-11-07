// SKYFORGE — Apache-2.0
import Foundation
// WGS84 geodesy: geodetic <-> ECEF and local ENU frames.

/// WGS84 ellipsoid constants.
public enum WGS84 {
    public static let a: Double = 6_378_137.0
    public static let f: Double = 1.0 / 298.257_223_563
    public static let b: Double = a * (1.0 - f)
    public static let e2: Double = f * (2.0 - f)
    public static let ep2: Double = e2 / (1.0 - e2)
}

/// A geodetic position (latitude/longitude in radians, height above the ellipsoid in metres).
public struct Geodetic: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var height: Double

    public init(latitude: Double, longitude: Double, height: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
    }

    public init(latitudeDegrees: Double, longitudeDegrees: Double, height: Double) {
        self.init(latitude: latitudeDegrees * .pi / 180, longitude: longitudeDegrees * .pi / 180, height: height)
    }

    public var latitudeDegrees: Double { latitude * 180 / .pi }
    public var longitudeDegrees: Double { longitude * 180 / .pi }

    /// Converts to Earth-centred, Earth-fixed coordinates (metres).
    public func toECEF() -> SIMD3<Double> {
        let sinLat = sin(latitude), cosLat = cos(latitude)
        let sinLon = sin(longitude), cosLon = cos(longitude)
        let n = WGS84.a / (1.0 - WGS84.e2 * sinLat * sinLat).squareRoot()
        return SIMD3(
            (n + height) * cosLat * cosLon,
            (n + height) * cosLat * sinLon,
            (n * (1.0 - WGS84.e2) + height) * sinLat
        )
    }

    /// Converts ECEF (metres) to geodetic using Bowring's initial guess refined by Newton iterations.
    public static func fromECEF(_ p: SIMD3<Double>) -> Geodetic {
        let x = p.x, y = p.y, z = p.z
        let lon = atan2(y, x)
        let r = (x * x + y * y).squareRoot()
        if r < 1e-9 {
            let lat: Double = z >= 0 ? .pi / 2 : -.pi / 2
            return Geodetic(latitude: lat, longitude: 0, height: abs(z) - WGS84.b)
        }
        // Bowring initial estimate
        let theta = atan2(z * WGS84.a, r * WGS84.b)
        let st = sin(theta), ct = cos(theta)
        var lat = atan2(z + WGS84.ep2 * WGS84.b * st * st * st, r - WGS84.e2 * WGS84.a * ct * ct * ct)
        var h = 0.0
        for _ in 0..<4 {
            let sl = sin(lat), cl = cos(lat)
            let n = WGS84.a / (1.0 - WGS84.e2 * sl * sl).squareRoot()
            h = abs(cl) > 1e-10 ? r / cl - n : abs(z) / abs(sl) - n * (1.0 - WGS84.e2)
            lat = atan2(z, r * (1.0 - WGS84.e2 * n / (n + h)))
        }
        return Geodetic(latitude: lat, longitude: lon, height: h)
    }
}

/// A local East-North-Up tangent frame anchored at a geodetic origin.
public struct ENUFrame: Sendable {
    public let origin: Geodetic
    public let originECEF: SIMD3<Double>
    public let east: SIMD3<Double>
    public let north: SIMD3<Double>
    public let up: SIMD3<Double>

    public init(origin: Geodetic) {
        self.origin = origin
        self.originECEF = origin.toECEF()
        let sl = sin(origin.latitude), cl = cos(origin.latitude)
        let so = sin(origin.longitude), co = cos(origin.longitude)
        east = SIMD3(-so, co, 0)
        north = SIMD3(-sl * co, -sl * so, cl)
        up = SIMD3(cl * co, cl * so, sl)
    }

    public func toLocal(ecef p: SIMD3<Double>) -> SIMD3<Double> {
        let d = p - originECEF
        return SIMD3(dot(d, east), dot(d, north), dot(d, up))
    }

    public func toECEF(local l: SIMD3<Double>) -> SIMD3<Double> {
        originECEF + east * l.x + north * l.y + up * l.z
    }
}

@inlinable public func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
@inlinable public func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
@inlinable public func length(_ a: SIMD3<Double>) -> Double { dot(a, a).squareRoot() }
@inlinable public func normalize(_ a: SIMD3<Double>) -> SIMD3<Double> {
    let l = length(a)
    return l > 0 ? a / l : a
}
