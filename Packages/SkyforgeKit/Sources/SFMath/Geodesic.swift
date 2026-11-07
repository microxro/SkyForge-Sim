// SKYFORGE — Apache-2.0
// Vincenty inverse/direct geodesics on WGS84 (accurate to < 1 mm except near-antipodal points,
// where the inverse may not converge; it then falls back to a spherical estimate).
import Foundation

public enum Geodesic {
    /// Distance (m) and initial/final true bearings (rad) between two geodetic points.
    public static func inverse(_ p1: Geodetic, _ p2: Geodetic) -> (distance: Double, initialBearing: Double, finalBearing: Double) {
        let a = WGS84.a, f = WGS84.f, b = WGS84.b
        let L = p2.longitude - p1.longitude
        let U1 = atan((1 - f) * tan(p1.latitude)), U2 = atan((1 - f) * tan(p2.latitude))
        let sinU1 = sin(U1), cosU1 = cos(U1), sinU2 = sin(U2), cosU2 = cos(U2)
        var lambda = L, iter = 0
        var sinSigma = 0.0, cosSigma = 0.0, sigma = 0.0, cosSqAlpha = 0.0, cos2SigmaM = 0.0, sinLambda = 0.0, cosLambda = 0.0
        repeat {
            sinLambda = sin(lambda); cosLambda = cos(lambda)
            let t1 = cosU2 * sinLambda, t2 = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda
            sinSigma = (t1 * t1 + t2 * t2).squareRoot()
            if sinSigma == 0 { return (0, 0, 0) }
            cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
            sigma = atan2(sinSigma, cosSigma)
            let sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma
            cosSqAlpha = 1 - sinAlpha * sinAlpha
            cos2SigmaM = cosSqAlpha != 0 ? cosSigma - 2 * sinU1 * sinU2 / cosSqAlpha : 0
            let C = f / 16 * cosSqAlpha * (4 + f * (4 - 3 * cosSqAlpha))
            let prev = lambda
            lambda = L + (1 - C) * f * sinAlpha * (sigma + C * sinSigma * (cos2SigmaM + C * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
            iter += 1
            if abs(lambda - prev) < 1e-12 { break }
        } while iter < 200
        if iter >= 200 {
            // Spherical fallback for nearly antipodal points.
            let r = 6_371_008.8
            let d = acos(min(1, max(-1, sin(p1.latitude) * sin(p2.latitude) + cos(p1.latitude) * cos(p2.latitude) * cos(L)))) * r
            let brg = atan2(sin(L) * cos(p2.latitude), cos(p1.latitude) * sin(p2.latitude) - sin(p1.latitude) * cos(p2.latitude) * cos(L))
            return (d, normalizeAngle(brg), normalizeAngle(brg + .pi))
        }
        let uSq = cosSqAlpha * (a * a - b * b) / (b * b)
        let A = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let B = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))
        let deltaSigma = B * sinSigma * (cos2SigmaM + B / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)
            - B / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
        let s = b * A * (sigma - deltaSigma)
        let a1 = atan2(cosU2 * sinLambda, cosU1 * sinU2 - sinU1 * cosU2 * cosLambda)
        let a2 = atan2(cosU1 * sinLambda, -sinU1 * cosU2 + cosU1 * sinU2 * cosLambda)
        return (s, normalizeAngle(a1), normalizeAngle(a2))
    }

    /// Destination from a start point, true bearing (rad) and distance (m).
    public static func direct(_ p: Geodetic, bearing alpha1: Double, distance s: Double) -> Geodetic {
        let a = WGS84.a, f = WGS84.f, b = WGS84.b
        let sinA1 = sin(alpha1), cosA1 = cos(alpha1)
        let tanU1 = (1 - f) * tan(p.latitude)
        let cosU1 = 1 / (1 + tanU1 * tanU1).squareRoot(), sinU1 = tanU1 * cosU1
        let sigma1 = atan2(tanU1, cosA1)
        let sinAlpha = cosU1 * sinA1
        let cosSqAlpha = 1 - sinAlpha * sinAlpha
        let uSq = cosSqAlpha * (a * a - b * b) / (b * b)
        let A = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let B = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))
        var sigma = s / (b * A), cos2SigmaM = 0.0, sinSigma = 0.0, cosSigma = 0.0
        for _ in 0..<100 {
            cos2SigmaM = cos(2 * sigma1 + sigma)
            sinSigma = sin(sigma); cosSigma = cos(sigma)
            let deltaSigma = B * sinSigma * (cos2SigmaM + B / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)
                - B / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
            let prev = sigma
            sigma = s / (b * A) + deltaSigma
            if abs(sigma - prev) < 1e-12 { break }
        }
        sinSigma = sin(sigma); cosSigma = cos(sigma); cos2SigmaM = cos(2 * sigma1 + sigma)
        let x = sinU1 * sinSigma - cosU1 * cosSigma * cosA1
        let lat = atan2(sinU1 * cosSigma + cosU1 * sinSigma * cosA1, (1 - f) * (sinAlpha * sinAlpha + x * x).squareRoot())
        let lambda = atan2(sinSigma * sinA1, cosU1 * cosSigma - sinU1 * sinSigma * cosA1)
        let C = f / 16 * cosSqAlpha * (4 + f * (4 - 3 * cosSqAlpha))
        let L = lambda - (1 - C) * f * sinAlpha * (sigma + C * sinSigma * (cos2SigmaM + C * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
        var lon = p.longitude + L
        lon = atan2(sin(lon), cos(lon))
        return Geodetic(latitude: lat, longitude: lon, height: p.height)
    }

    public static func normalizeAngle(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x < 0 { x += 2 * .pi }
        return x
    }
}
