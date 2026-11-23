// SKYFORGE — Apache-2.0
import Foundation

/// Turns the live surface wind into the vegetation sway uniform (`VegUniforms.wind` in VegetationShaders).
/// Pure maths so it can be tested on Linux; the renderer and the flight view call it each frame.
public enum VegetationWind {
    /// Sway uniform used when no wind is known: a gentle breeze from the east, so trees still move.
    public static let fallback = SIMD4<Float>(1, 0, 3, 0.3)

    /// - Parameters:
    ///   - windNED: air motion toward, NED metres per second (x north, y east, z down).
    ///   - gustMps: gust excess over the mean, metres per second (0 when unknown).
    /// - Returns: `(east, north)` unit direction the air moves toward in ENU, speed m/s, gustiness 0…1.
    public static func uniform(windNED: SIMD3<Double>, gustMps: Double = 0) -> SIMD4<Float> {
        let speed = (windNED.x * windNED.x + windNED.y * windNED.y).squareRoot()
        guard speed > 1e-6, speed.isFinite else { return SIMD4<Float>(1, 0, 0, 0) }
        let east = Float(windNED.y / speed)
        let north = Float(windNED.x / speed)
        let gust = Float(min(1, max(0, gustMps) / max(speed, 1)))
        return SIMD4<Float>(east, north, Float(speed), gust)
    }
}
